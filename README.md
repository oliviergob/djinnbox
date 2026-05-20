# Djinnbox

**Your AI coding agent, contained.**

AI agents like Claude Code and Codex are powerful, and they run on your machine, with access to your files, your credentials, your entire system. This presents risks:

- **Prompt injection** — a malicious instruction in a file or webpage hijacks the agent
- **Supply chain attacks** — a compromised package silently exfiltrates your credentials
- **Accidental deletion** — a misunderstood instruction wipes work that can't be recovered


Labs know this is a problem. Their built-in sandboxes are shallow: they limit what an agent can *say*, not what it can *do*.

Djinnbox fixes this with real OS-level isolation. The agent runs in its own Linux container (the box), its own filesystem, its own user, its own network boundary. It can't touch your Windows files, your SSH keys, or anything else on your machine.

**The `projects` folder is the only bridge.** What you put there is shared intentionally. Everything else stays yours.



---

## How to install

Download and run the installer:

**[djinnbox-setup.exe → github.com/oliviergob/djinnbox/releases/latest](https://github.com/oliviergob/djinnbox/releases/latest)**

**Prerequisite:** WSL2 must be enabled (`wsl --install` in PowerShell if not yet set up).

The installer handles everything else — SSH keys, container setup, VS Code integration, and wiring up Claude Code and Codex to connect to the container automatically.

At the end you'll see your SSH connection string and the GitHub SSH key to add to your account.

---

## What you get

- **Isolated Debian container** — persistent, SSH-accessible, starts automatically at login
- **Projects folder** — the intentional bridge between Windows and the agent workspace, accessible from both sides
- **Claude Code + Codex** pre-configured to connect to the container
- **VS Code** with Remote-WSL and a desktop shortcut

---

## Djinnbox container

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

Both layers bake in agent configuration files (`CLAUDE.md`, `AGENTS.md`) that tell Claude Code and Codex which ports are forwarded and to bind web servers to `8100` by default.

---

## Advanced / manual install

For scripted or custom installs:

```powershell
git clone https://github.com/oliviergob/djinnbox
cd djinnbox\install-scripts
.\install-wsl-debian.ps1
```

Optional parameters:

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

The setup is idempotent — re-running after a partial install or a WSL reset picks up from where things broke.
