# Djinnbox

A one-command setup that turns a Windows machine into a proper Linux development environment — a persistent, SSH-accessible Debian container living inside WSL, ready at every login.

## What you get

- **Debian WSL** configured with systemd, Podman, Git, and your user account
- **Djinnbox container** — a persistent dev environment that starts automatically at login and is reachable over SSH from Windows
- **SSH key** generated and synced between Windows and WSL (or your existing key is reused)
- **VS Code** configured for WSL development with the Remote-WSL extension
- **Projects folder** mounted into the container, pinned to Windows Quick Access, and accessible from both sides

## Prerequisites

- Windows 10/11 with WSL2 available (`wsl --install` if not yet set up)
- PowerShell (run as your normal user — not Administrator)
- An SSH key at `~\.ssh\id_ed25519` — or let the setup generate one

## Quick start

```powershell
git clone https://github.com/oliviergob/djinnbox
cd djinnbox\install-scripts
.\install-wsl-debian.ps1
```

At the end you'll see a summary with your SSH connection string, web ports, and the GitHub SSH key to add to your account.

## What the setup does

1. Enables mirrored networking in `.wslconfig` so `localhost` works transparently between Windows and WSL
2. Installs Debian via WSL if not already present
3. Creates your user account inside Debian with passwordless sudo
4. Installs Podman, Git, jq, and other tools
5. Generates an `ed25519` SSH key and syncs it with `~\.ssh` on Windows (or copies your existing Windows key into WSL)
6. Reads your Windows `git config` and mirrors `user.name` / `user.email` into WSL
7. Configures VS Code trust for WSL paths and installs the Remote-WSL extension
8. Pins your projects folder to Windows Quick Access and creates a desktop shortcut
9. Pulls and starts the **djinnbox** container with SSH and web ports mapped
10. Registers a Task Scheduler task so WSL (and therefore the container) starts at every login

## Djinnbox container

The container is a persistent Podman container managed by a systemd user service. It survives reboots — the Task Scheduler task starts WSL at login, and systemd starts the container automatically.

| Resource | Value |
|----------|-------|
| SSH | `ssh -p 22022 devuser@localhost` |
| Web ports | `8100`, `8200`, `8300` → `localhost:8100/8200/8300` |
| Projects | `/home/devuser/projects` ↔ `~/projects` in WSL |

Web servers started inside the container should bind to one of the three forwarded ports (default to `8100`).

A `CLAUDE.md` is baked into the container image so Claude Code automatically picks up these constraints.

## Parameters

All parameters are optional. The defaults work for a standard Windows setup.

```powershell
.\install-wsl-debian.ps1 `
    [-Username      <string>]   # defaults to your Windows username
    [-Distro        <string>]   # defaults to "Debian"
    [-ProjectsPath  <string>]   # defaults to "projects"
    [-SshPort       <int>]      # defaults to 22022
    [-SkipSshContainer]         # install WSL only, skip the container
```

To set up the container separately (e.g. after a reinstall):

```powershell
.\install-scripts\setup-ssh-container.ps1
```

## Idempotent

The setup can be re-run safely. Each step checks current state before making changes — re-running after a partial install or a WSL reset picks up from where things broke.
