#!/bin/bash
# setup-ssh-container.sh — Idempotent setup for the dev-ssh-persist Podman container.
# Runs as root inside WSL. Reads:
#   /tmp/dev-ssh-persist/Dockerfile  — container image definition
#   /tmp/dev-ssh-pubkey.tmp          — SSH public key to authorize
set -e

USERNAME=$1
PROJECTS_PATH=$2
SSH_PORT=${3:-22022}

[ -z "$USERNAME" ] && { echo "Error: USERNAME required"; exit 1; }

CONTAINER="dev-ssh-persist"
IMAGE="oliviergob/dev-ssh-persist"
CONTAINER="djinnbox"
IMAGE="oliviergob/djinnbox"
SERVICE_NAME="container-${CONTAINER}.service"
USER_ID=$(id -u "$USERNAME")

run_as_user() {
    sudo -u "$USERNAME" \
        XDG_RUNTIME_DIR="/run/user/$USER_ID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
        HOME="/home/$USERNAME" \
        "$@"
}

# ── 1. Pull image ─────────────────────────────────────────────────────────
if ! run_as_user podman image exists "$IMAGE" 2>/dev/null; then
    echo "[INFO] Pulling $IMAGE..."
    run_as_user podman pull "$IMAGE"
    echo "[OK]   Image pulled"
else
    echo "[OK]   Image already present: $IMAGE"
fi

# ── 2. Create container ────────────────────────────────────────────────────
MOUNT_SRC="/home/$USERNAME/$PROJECTS_PATH"

if ! run_as_user podman container exists "$CONTAINER" 2>/dev/null; then
    mkdir -p "$MOUNT_SRC"
    chown "$USERNAME:$USERNAME" "$MOUNT_SRC"
    run_as_user podman create \
        --name "$CONTAINER" \
        --userns=keep-id \
        -p "127.0.0.1:${SSH_PORT}:22" \
        -p "127.0.0.1:8100:8100" \
        -p "127.0.0.1:8200:8200" \
        -p "127.0.0.1:8300:8300" \
        -v "${MOUNT_SRC}:/home/devuser/projects:z" \
        "$IMAGE"
    echo "[OK]   Container created: $CONTAINER"
else
    echo "[OK]   Container already exists: $CONTAINER"
fi

# ── 3. Install authorized_keys ─────────────────────────────────────────────
WAS_RUNNING=$(run_as_user podman inspect "$CONTAINER" \
    --format '{{.State.Running}}' 2>/dev/null || echo false)

if [ "$WAS_RUNNING" != "true" ]; then
    run_as_user podman start "$CONTAINER" >/dev/null
    sleep 1
fi

if [ -f "/tmp/dev-ssh-pubkey.tmp" ]; then
    run_as_user podman exec -i "$CONTAINER" bash -c \
        "cat > /home/devuser/.ssh/authorized_keys \
         && chmod 600 /home/devuser/.ssh/authorized_keys \
         && chown devuser:devuser /home/devuser/.ssh/authorized_keys" \
        < /tmp/dev-ssh-pubkey.tmp
fi
echo "[OK]   authorized_keys installed"

[ "$WAS_RUNNING" != "true" ] && run_as_user podman stop "$CONTAINER" >/dev/null

# ── 4. Systemd user service ────────────────────────────────────────────────
SERVICE_DIR="/home/$USERNAME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/$SERVICE_NAME"
mkdir -p "$SERVICE_DIR"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"

loginctl enable-linger "$USERNAME" >/dev/null 2>&1 || true

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=dev-ssh-persist Podman container
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/podman start $CONTAINER
ExecStop=/usr/bin/podman stop $CONTAINER

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
        || run_as_user podman start "$CONTAINER"
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

    if HOST_PUBKEY=$(run_as_user podman exec "$CONTAINER" cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $1, $2}'); then
        KH_FILE="$WIN_HOME/.ssh/known_hosts"
        mkdir -p "$WIN_HOME/.ssh"
        touch "$KH_FILE"
        for ADDR in "127.0.0.1" "localhost"; do
            ssh-keygen -f "$KH_FILE" -R "[${ADDR}]:${SSH_PORT}" 2>/dev/null
            echo "[${ADDR}]:${SSH_PORT} ${HOST_PUBKEY}" >> "$KH_FILE"
        done
        echo "[OK]   Host key written to known_hosts: [127.0.0.1]:${SSH_PORT}"
    else
        echo "[WARN] Could not read container host key; known_hosts not updated"
    fi
else
    echo "[WARN] Could not resolve Windows home; skipping Claude desktop settings"
fi

rm -f /tmp/dev-ssh-pubkey.tmp /tmp/setup-ssh-container.sh
