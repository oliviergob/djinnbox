# Djinnbox

A one-command setup that turns a Windows machine into a proper Linux development environment — a persistent, SSH-accessible Debian container living inside WSL, ready at every login, and pre-wired for AI coding agents.

## What you get

- **Debian WSL** configured with systemd, Podman, and your user account
- **Djinnbox container** — a persistent dev environment that starts automatically at login and is reachable over SSH from Windows
- **SSH key** generated and synced between Windows and WSL (or your existing key is reused); container host key written to `known_hosts`
- **VS Code** configured for WSL development with the Remote-WSL extension and a desktop shortcut
- **Projects folder** mounted into the container, pinned to Windows Quick Access, and accessible from both sides
- **Claude Code** pre-configured to connect to the container (entry added to `~/.claude/settings.json`)
- **Codex** pre-configured to connect to the container (`remote_connections = true`, SSH host entry `wsl-djinnbox` added)

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

Alternatively, download and run the pre-built installer: `djinnbox-setup.exe` (built from `djinnbox-setup.iss`).

## What the setup does

1. Enables mirrored networking and disables idle timeout in `.wslconfig` so `localhost` works transparently and WSL stays alive
2. Installs Debian via WSL if not already present
3. Creates your user account inside Debian with passwordless sudo
4. Installs Podman, Git, jq, and other tools
5. Installs a systemd service (`projects-owner-fix`) that watches the projects folder and fixes ownership of files dropped in by Windows
6. Enables persistent journald logging for debugging
7. Generates an `ed25519` SSH key and syncs it with `~\.ssh` on Windows (or copies your existing Windows key into WSL)
8. Reads your Windows `git config` and mirrors `user.name` / `user.email` into WSL
9. Configures VS Code trust for WSL paths and installs the Remote-WSL extension
10. Pins your projects folder to Windows Quick Access and creates a desktop shortcut
11. Pulls and starts the **djinnbox** container with SSH and web ports mapped
12. Installs the container's SSH host key into `~\.ssh\known_hosts` on Windows
13. Adds the container as an SSH remote in `~\.claude\settings.json` (Claude Code desktop)
14. Adds the container as a remote in `~\.codex\config.toml` and `~\.ssh\config` (Codex)
15. Registers a Task Scheduler task so WSL (and therefore the container) starts at every login

## Djinnbox container

The container is a persistent Podman container managed by a systemd user service. It survives reboots — the Task Scheduler task starts WSL at login, and systemd starts the container automatically.

| Resource | Value |
|----------|-------|
| SSH | `ssh -p 22022 devuser@localhost` |
| Web ports | `8100`, `8200`, `8300` → `localhost:8100/8200/8300` |
| Projects | `/home/devuser/projects` ↔ `~/projects` in WSL |

Web servers started inside the container should bind to one of the three forwarded ports (default to `8100`).

### Container contents

The image is built in two layers:

- **Base** (`dockerfile`) — Debian bookworm-slim, Node.js 22, Python 3, Git, vim, `sfw` (safe wrapper aliased over `npm` and `pip`)
- **SSH layer** (`dockerfile.ssh-persist`) — extends the base with `openssh-server`, `tini`, Codex CLI (`@openai/codex`)

The SSH layer also bakes in:
- `CLAUDE.md` at `/home/devuser/.claude/CLAUDE.md` — Claude Code picks this up automatically
- `AGENTS.md` at `/home/devuser/.codex/AGENTS.md` — Codex picks this up automatically

Both files tell the agent which ports are forwarded and to bind web servers to `8100` by default.

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
