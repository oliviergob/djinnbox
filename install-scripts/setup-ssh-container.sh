#!/bin/bash
# setup-ssh-container.sh — Idempotent setup for the djinnbox Podman container.
# Runs as root inside WSL. Reads:
#   /tmp/dev-ssh-pubkey.tmp          — SSH public key to authorize
set -e

USERNAME=$1
PROJECTS_PATH=$2
SSH_PORT=${3:-22022}

[ -z "$USERNAME" ] && { echo "Error: USERNAME required"; exit 1; }

CONTAINER="djinnbox"
IMAGE="docker.io/oliviergob/djinnbox"
SERVICE_NAME="container-${CONTAINER}.service"
USER_ID=$(id -u "$USERNAME")

run_as_user() {
    sudo -u "$USERNAME" \
        XDG_RUNTIME_DIR="/run/user/$USER_ID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
        HOME="/home/$USERNAME" \
        "$@"
}

# ── 1. Update image from Docker Hub ───────────────────────────────────────
OLD_IMAGE_ID=$(run_as_user podman image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || true)
echo "[INFO] Pulling latest $IMAGE..."
run_as_user podman pull "$IMAGE"
NEW_IMAGE_ID=$(run_as_user podman image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || true)

IMAGE_UPDATED=false
if [ -n "$OLD_IMAGE_ID" ] && [ "$OLD_IMAGE_ID" != "$NEW_IMAGE_ID" ]; then
    IMAGE_UPDATED=true
    echo "[OK]   Image updated"
else
    echo "[OK]   Image already up to date"
fi

# ── 2. Create/recreate container ──────────────────────────────────────────
MOUNT_SRC="/home/$USERNAME/$PROJECTS_PATH"
mkdir -p "$MOUNT_SRC"
chown "$USERNAME:$USERNAME" "$MOUNT_SRC"

_create_container() {
    run_as_user podman create \
        --name "$CONTAINER" \
        --userns=keep-id \
        -p "127.0.0.1:${SSH_PORT}:22" \
        -p "127.0.0.1:8100:8100" \
        -p "127.0.0.1:8200:8200" \
        -p "127.0.0.1:8300:8300" \
        -v "${MOUNT_SRC}:/home/devuser/projects:z" \
        "$IMAGE"
}

if run_as_user podman container exists "$CONTAINER" 2>/dev/null; then
    if [ "$IMAGE_UPDATED" = "true" ]; then
        echo "[INFO] Image updated — recreating container..."
        run_as_user podman rm -f "$CONTAINER" 2>/dev/null || true
        sleep 2
        _create_container
        echo "[OK]   Container recreated: $CONTAINER"
    else
        echo "[OK]   Container already up to date: $CONTAINER"
    fi
else
    _create_container
    echo "[OK]   Container created: $CONTAINER"
fi

# ── 3. Install authorized_keys ─────────────────────────────────────────────
if [ -f "/tmp/dev-ssh-pubkey.tmp" ]; then
    echo "[INFO] Installing SSH keys via podman cp..."
    # podman cp works on stopped containers and preserves ownership when using keep-id
    run_as_user podman cp /tmp/dev-ssh-pubkey.tmp "$CONTAINER:/home/devuser/.ssh/authorized_keys"
    run_as_user podman exec "$CONTAINER" chown devuser:devuser /home/devuser/.ssh/authorized_keys 2>/dev/null || true
    run_as_user podman exec "$CONTAINER" chmod 600 /home/devuser/.ssh/authorized_keys 2>/dev/null || true
fi
echo "[OK]   authorized_keys installed"

# ── 4. Systemd user service ────────────────────────────────────────────────
SERVICE_DIR="/home/$USERNAME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/$SERVICE_NAME"
mkdir -p "$SERVICE_DIR"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"

loginctl enable-linger "$USERNAME" >/dev/null 2>&1 || true

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=djinnbox Podman container
After=network.target

[Service]
Type=simple
ExecStartPre=-/usr/bin/podman stop $CONTAINER
ExecStart=/usr/bin/podman start -a $CONTAINER
ExecStop=/usr/bin/podman stop $CONTAINER
Restart=always
RestartSec=2
StartLimitIntervalSec=0

[Install]
WantedBy=default.target
EOF
chown "$USERNAME:$USERNAME" "$SERVICE_FILE"

if run_as_user systemctl --user daemon-reload 2>/dev/null \
&& run_as_user systemctl --user enable "$SERVICE_NAME" 2>/dev/null; then
    echo "[OK]   Systemd user service enabled: $SERVICE_NAME"
else
    echo "[WARN] Could not enable systemd service (systemd may not be active yet)."
    echo "[WARN] Restart WSL and re-run setup-ssh-container.ps1."
fi

# ── 5. Start container ─────────────────────────────────────────────────────
RUNNING=$(run_as_user podman inspect "$CONTAINER" \
    --format '{{.State.Running}}' 2>/dev/null || echo false)

if [ "$RUNNING" != "true" ]; then
    run_as_user systemctl --user start "$SERVICE_NAME" 2>/dev/null \
        || run_as_user podman start "$CONTAINER" \
        || { echo "[ERROR] Failed to start container"; exit 1; }
    echo "[OK]   Container started"
else
    echo "[OK]   Container already running"
fi

# ── 6. Claude desktop — sshConfigs in settings.json ──────────────────────
command -v jq >/dev/null 2>&1 || apt-get install -y -q jq

_get_win_home() {
    local raw
    raw=$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r\n') || return 1
    wslpath "$raw" 2>/dev/null
}
WIN_HOME=$(_get_win_home) || WIN_HOME=""

if [ -n "$WIN_HOME" ]; then
    CLAUDE_SETTINGS="$WIN_HOME/.claude/settings.json"
    mkdir -p "$WIN_HOME/.claude"

    [ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"

    NEW_ENTRY=$(jq -n \
        --arg id      "wsl-$CONTAINER" \
        --arg name    "$CONTAINER" \
        --argjson port "$SSH_PORT" \
        '{id: $id, name: $name, sshHost: "devuser@127.0.0.1", sshPort: $port, startDirectory: "/home/devuser/projects"}')

    jq --argjson entry "$NEW_ENTRY" \
        '.sshConfigs = (if .sshConfigs == null then [] else .sshConfigs end) |
         if (.sshConfigs | map(.id) | contains([$entry.id])) then
           .sshConfigs |= map(if .id == $entry.id then $entry else . end)
         else
           .sshConfigs += [$entry]
         end' \
        "$CLAUDE_SETTINGS" > "${CLAUDE_SETTINGS}.tmp" \
        && mv "${CLAUDE_SETTINGS}.tmp" "$CLAUDE_SETTINGS"

    echo "[OK]   Claude desktop settings updated: $CLAUDE_SETTINGS"

    TMPKEY=$(run_as_user mktemp)
    if run_as_user podman cp "$CONTAINER:/etc/ssh/ssh_host_ed25519_key.pub" "$TMPKEY" 2>/dev/null \
       && HOST_PUBKEY=$(awk '{print $1, $2}' "$TMPKEY") && [ -n "$HOST_PUBKEY" ]; then
        KH_FILE="$WIN_HOME/.ssh/known_hosts"
        mkdir -p "$WIN_HOME/.ssh"
        touch "$KH_FILE"
        for ADDR in "127.0.0.1" "localhost"; do
            ssh-keygen -f "$KH_FILE" -R "[${ADDR}]:${SSH_PORT}" 2>/dev/null || true
        done
        printf '%s\n' \
            "[127.0.0.1]:${SSH_PORT} ${HOST_PUBKEY}" \
            "[localhost]:${SSH_PORT} ${HOST_PUBKEY}" >> "$KH_FILE"
        echo "[OK]   Host key written to known_hosts: [127.0.0.1]:${SSH_PORT} and [localhost]:${SSH_PORT}"
    else
        echo "[WARN] Could not read container host key; known_hosts not updated"
    fi
    rm -f "$TMPKEY"
else
    echo "[WARN] Could not resolve Windows home; skipping Claude desktop settings"
fi

# ── 7. Codex — remote_connections feature + SSH host entry ───────────────
if [ -n "$WIN_HOME" ]; then
    HOST_ALIAS="wsl-$CONTAINER"

    # 7a. ~/.codex/config.toml — ensure [features] remote_connections = true
    CODEX_DIR="$WIN_HOME/.codex"
    CODEX_CONFIG="$CODEX_DIR/config.toml"
    mkdir -p "$CODEX_DIR"
    if [ ! -f "$CODEX_CONFIG" ]; then
        printf '[features]\nremote_connections = true\n' > "$CODEX_CONFIG"
        echo "[OK]   Created $CODEX_CONFIG with remote_connections = true"
    elif ! grep -q '^\[features\]' "$CODEX_CONFIG"; then
        printf '\n[features]\nremote_connections = true\n' >> "$CODEX_CONFIG"
        echo "[OK]   Added [features] section to $CODEX_CONFIG"
    elif ! grep -qE '^remote_connections[[:space:]]*=' "$CODEX_CONFIG"; then
        sed -i '/^\[features\]/a\remote_connections = true' "$CODEX_CONFIG"
        echo "[OK]   Added remote_connections = true to $CODEX_CONFIG"
    else
        sed -i 's/^remote_connections[[:space:]]*=.*/remote_connections = true/' "$CODEX_CONFIG"
        echo "[OK]   remote_connections already set in $CODEX_CONFIG"
    fi

    # 7b. ~/.ssh/config — host entry for the container
    SSH_CONFIG="$WIN_HOME/.ssh/config"
    mkdir -p "$WIN_HOME/.ssh"
    touch "$SSH_CONFIG"
    if ! grep -qE "^Host[[:space:]]+${HOST_ALIAS}([[:space:]]|$)" "$SSH_CONFIG"; then
        cat >> "$SSH_CONFIG" <<SSHEOF

Host $HOST_ALIAS
    HostName 127.0.0.1
    Port $SSH_PORT
    User devuser
    ServerAliveInterval 20
    ServerAliveCountMax 3
SSHEOF
        echo "[OK]   SSH config entry added: Host $HOST_ALIAS in $SSH_CONFIG"
    else
        echo "[OK]   SSH config entry already exists: Host $HOST_ALIAS"
    fi
else
    echo "[WARN] Could not resolve Windows home; skipping Codex configuration"
fi

rm -f /tmp/dev-ssh-pubkey.tmp /tmp/setup-ssh-container.sh
