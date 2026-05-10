#!/bin/bash
# setup-debian.sh - Configures the Debian WSL distro.
set -e

USERNAME=$1
PROJECTS_PATH=$2
VSCODE_SETTINGS_PATH=$3
WIN_USERNAME=$4

[ -z "$USERNAME" ] && { echo "Error: USERNAME is required"; exit 1; }

# 1. Ensure user exists
if ! id -u "$USERNAME" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$USERNAME"
    usermod -aG sudo "$USERNAME"
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$USERNAME"
    chmod 0440 /etc/sudoers.d/"$USERNAME"
fi

USER_ID=$(id -u "$USERNAME")

# 2. Configure wsl.conf
RESTART_REQUIRED=false
touch /etc/wsl.conf

# Patches a single key=value in the correct [section] without clobbering the rest of the file.
wsl_conf_set() {
    local section="$1" key="$2" value="$3"
    if grep -qxF "$key=$value" /etc/wsl.conf 2>/dev/null; then return; fi
    if ! grep -qxF "[$section]" /etc/wsl.conf 2>/dev/null; then
        printf '\n[%s]\n%s=%s\n' "$section" "$key" "$value" >> /etc/wsl.conf
    elif grep -q "^$key=" /etc/wsl.conf; then
        sed -i "s|^$key=.*|$key=$value|" /etc/wsl.conf
    else
        sed -i "/^\[$section\]/a $key=$value" /etc/wsl.conf
    fi
    RESTART_REQUIRED=true
}

wsl_conf_set user default "$USERNAME"
wsl_conf_set boot systemd true

# 3. Projects directory
mkdir -p "/home/$USERNAME/$PROJECTS_PATH"
chown "$USERNAME:$USERNAME" "/home/$USERNAME/$PROJECTS_PATH"

# 4. Install required packages
if ! command -v podman >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 \
        || ! command -v git >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1 \
        || ! command -v inotifywait >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y podman slirp4netns fuse-overlayfs inotify-tools jq curl ca-certificates git openssh-client
fi

# 4a. Ownership watcher — chown files to $USERNAME the moment Windows drops them in projects
WATCHER_SCRIPT="/usr/local/bin/projects-owner-fix.sh"
cat > "$WATCHER_SCRIPT" << 'SCRIPT'
#!/bin/bash
# Runs as root. Fixes ownership of any file/dir created by the WSL 9P server (root)
# so the container's devuser (same UID as the WSL user) can read and write them.
PROJECTS_DIR="$1"
OWNER="$2"

find "$PROJECTS_DIR" -user root -exec chown "$OWNER:$OWNER" {} + 2>/dev/null || true

inotifywait -m -r -e create,moved_to --format '%w%f' "$PROJECTS_DIR" | \
while read -r path; do
    chown -R "$OWNER:$OWNER" "$path" 2>/dev/null || true
done
SCRIPT
chmod +x "$WATCHER_SCRIPT"

cat > /etc/systemd/system/projects-owner-fix.service <<EOF
[Unit]
Description=Fix ownership of Windows-created files in $PROJECTS_PATH
After=local-fs.target

[Service]
Type=simple
ExecStart=$WATCHER_SCRIPT /home/$USERNAME/$PROJECTS_PATH $USERNAME
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Enable by symlinking directly — works even while systemd is still starting up
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/projects-owner-fix.service \
       /etc/systemd/system/multi-user.target.wants/projects-owner-fix.service

# Start it now if systemd is already responsive; silently skipped if still booting
systemctl daemon-reload 2>/dev/null || true
systemctl start projects-owner-fix.service 2>/dev/null || true

# 5. Podman registries
REGISTRIES_CONF="/etc/containers/registries.conf"
if ! grep -q '^unqualified-search-registries' "$REGISTRIES_CONF" 2>/dev/null; then
    mkdir -p "$(dirname "$REGISTRIES_CONF")"
    printf '\nunqualified-search-registries = ["docker.io"]\n' >> "$REGISTRIES_CONF"
fi

# 6. Podman containers.conf — force cgroupfs (systemd sd-bus unavailable in WSL2 non-login sessions)
CONTAINERS_CONF="/etc/containers/containers.conf"
if ! grep -q 'cgroup_manager' "$CONTAINERS_CONF" 2>/dev/null; then
    mkdir -p "$(dirname "$CONTAINERS_CONF")"
    printf '\n[engine]\ncgroup_manager = "cgroupfs"\n' >> "$CONTAINERS_CONF"
fi

# 7. Podman socket & Linger
if systemctl is-system-running --quiet 2>/dev/null || systemctl is-system-running 2>/dev/null | grep -qE "running|degraded"; then
    # Enable linger so the user bus/manager starts and stays running
    loginctl enable-linger "$USERNAME" >/dev/null 2>&1 || true
    
    # Try to enable the socket. We suppress the bus error because 'enable' 
    # primarily creates symlinks which works even if the bus is unreachable.
    sudo -u "$USERNAME" XDG_RUNTIME_DIR="/run/user/$USER_ID" systemctl --user enable podman.socket >/dev/null 2>&1 || true
fi

# 8. DOCKER_HOST in .bashrc
BASHRC="/home/$USERNAME/.bashrc"
if ! grep -q 'DOCKER_HOST.*podman' "$BASHRC" 2>/dev/null; then
    printf '\n# podman-devcontainer\nexport DOCKER_HOST=unix:///run/user/%s/podman/podman.sock\n' "$USER_ID" >> "$BASHRC"
fi

# 9. VSCode trust
if [ -n "$VSCODE_SETTINGS_PATH" ]; then
    # Create directory and file if missing, ensuring they aren't exclusively root-owned if possible
    # Note: On /mnt/c (DrvFs), permissions are usually mapped to the Windows user.
    mkdir -p "$(dirname "$VSCODE_SETTINGS_PATH")"
    [ -f "$VSCODE_SETTINGS_PATH" ] || echo '{}' > "$VSCODE_SETTINGS_PATH"
    
    # Use a temporary file to avoid permission issues during redirection
    TMP_JSON=$(mktemp)
    jq '.["security.allowedUNCHosts"] |= (. // [] | . + ["wsl.localhost"] | unique)
      | .["dev.containers.dockerPath"] //= "podman"' "$VSCODE_SETTINGS_PATH" > "$TMP_JSON" && \
    cat "$TMP_JSON" > "$VSCODE_SETTINGS_PATH" && rm "$TMP_JSON"
fi

# 10. Git defaults
sudo -u "$USERNAME" git config --global --get init.defaultBranch >/dev/null 2>&1 || \
    sudo -u "$USERNAME" git config --global init.defaultBranch main
sudo -u "$USERNAME" git config --global --get core.editor >/dev/null 2>&1 || \
    sudo -u "$USERNAME" git config --global core.editor vim

# Try to inherit user.name and user.email from the Windows host git config
if [ -n "$WIN_USERNAME" ]; then
    WIN_GITCONFIG="/mnt/c/Users/$WIN_USERNAME/.gitconfig"
    if [ -f "$WIN_GITCONFIG" ]; then
        WIN_GIT_NAME=$(git config -f "$WIN_GITCONFIG" user.name 2>/dev/null || true)
        WIN_GIT_EMAIL=$(git config -f "$WIN_GITCONFIG" user.email 2>/dev/null || true)
    fi
fi

# Fall back to interactive prompt if not found on Windows and not already set
if ! sudo -u "$USERNAME" git config --global --get user.name >/dev/null 2>&1 && [ -z "$WIN_GIT_NAME" ]; then
    read -rp "Git user.name: " WIN_GIT_NAME </dev/tty || true
fi
if ! sudo -u "$USERNAME" git config --global --get user.email >/dev/null 2>&1 && [ -z "$WIN_GIT_EMAIL" ]; then
    read -rp "Git user.email: " WIN_GIT_EMAIL </dev/tty || true
fi

[ -n "$WIN_GIT_NAME" ] && { sudo -u "$USERNAME" git config --global --get user.name >/dev/null 2>&1 || \
    sudo -u "$USERNAME" git config --global user.name "$WIN_GIT_NAME"; }
[ -n "$WIN_GIT_EMAIL" ] && { sudo -u "$USERNAME" git config --global --get user.email >/dev/null 2>&1 || \
    sudo -u "$USERNAME" git config --global user.email "$WIN_GIT_EMAIL"; }

# 11. SSH key — keep Windows and Debian in sync
SSH_DIR="/home/$USERNAME/.ssh"
WIN_SSH_DIR="/mnt/c/Users/$WIN_USERNAME/.ssh"
WIN_KEY="$WIN_SSH_DIR/id_ed25519"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$USERNAME:$USERNAME" "$SSH_DIR"

LINUX_KEY_EXISTS=false
WIN_KEY_EXISTS=false
[ -f "$SSH_DIR/id_ed25519" ] && LINUX_KEY_EXISTS=true
[ -n "$WIN_USERNAME" ] && [ -f "$WIN_KEY" ] && WIN_KEY_EXISTS=true

if $WIN_KEY_EXISTS && ! $LINUX_KEY_EXISTS; then
    # Copy Windows → Linux
    cp "$WIN_KEY" "$SSH_DIR/id_ed25519"
    cp "${WIN_KEY}.pub" "$SSH_DIR/id_ed25519.pub"
    chmod 600 "$SSH_DIR/id_ed25519"
    chmod 644 "$SSH_DIR/id_ed25519.pub"
    chown "$USERNAME:$USERNAME" "$SSH_DIR/id_ed25519" "$SSH_DIR/id_ed25519.pub"
elif $LINUX_KEY_EXISTS && ! $WIN_KEY_EXISTS && [ -n "$WIN_USERNAME" ]; then
    # Copy Linux → Windows
    mkdir -p "$WIN_SSH_DIR"
    cp "$SSH_DIR/id_ed25519" "$WIN_KEY"
    cp "$SSH_DIR/id_ed25519.pub" "${WIN_KEY}.pub"
elif ! $LINUX_KEY_EXISTS; then
    # Generate new key, then copy to Windows
    sudo -u "$USERNAME" ssh-keygen -t ed25519 -f "$SSH_DIR/id_ed25519" -N "" -q
    cp "$SSH_DIR/id_ed25519.pub" /tmp/new-ssh-key.pub
    if [ -n "$WIN_USERNAME" ]; then
        mkdir -p "$WIN_SSH_DIR"
        cp "$SSH_DIR/id_ed25519" "$WIN_KEY"
        cp "$SSH_DIR/id_ed25519.pub" "${WIN_KEY}.pub"
    fi
fi
# If both already exist: leave them untouched

[ "$RESTART_REQUIRED" = true ] && exit 2
exit 0