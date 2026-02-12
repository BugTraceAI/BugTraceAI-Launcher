<p align="center">
  <img src="logo.png" alt="BugTraceAI" width="120" />
</p>

<h1 align="center">BugTraceAI Launcher</h1>

<p align="center">
  One-command deployment for the BugTraceAI security platform via Docker.
</p>

<p align="center">
  <a href="https://bugtraceai.com"><img src="https://img.shields.io/badge/Website-bugtraceai.com-blue?logo=google-chrome&logoColor=white" /></a>
  <a href="https://deepwiki.com/BugTraceAI/BugTraceAI-Launcher"><img src="https://img.shields.io/badge/Wiki-DeepWiki-000?logo=wikipedia&logoColor=white" /></a>
  <img src="https://img.shields.io/badge/Version-2.0.0-blue" />
  <img src="https://img.shields.io/badge/License-MIT-green.svg" />
  <img src="https://img.shields.io/badge/Bash-3.2+-4EAA25?logo=gnu-bash&logoColor=white" />
  <img src="https://img.shields.io/badge/Docker-Required-2496ED?logo=docker&logoColor=white" />
</p>

---

Interactive wizard that clones the BugTraceAI repos, builds Docker images, generates configs, sets up databases, and orchestrates all services. Deploy WEB, CLI, or both with a single command.

> This repository is part of the [BugTraceAI](https://github.com/BugTraceAI/BugTraceAI) monorepo (as a git submodule) and also works as a standalone repo.

## Quick Start

**One-liner install** (recommended):

```bash
git clone https://github.com/BugTraceAI/BugTraceAI-Launcher.git ~/bugtraceai-launcher && ~/bugtraceai-launcher/launcher.sh
```

Or step by step:

```bash
git clone https://github.com/BugTraceAI/BugTraceAI-Launcher.git ~/bugtraceai-launcher
cd ~/bugtraceai-launcher
./launcher.sh
```

The wizard will guide you step by step: choose deployment mode, enter your OpenRouter API key, configure ports, and confirm. The launcher handles the rest.

## Requirements

| Requirement | Details |
|-------------|---------|
| **OS** | Linux (x86_64) or macOS (Intel / Apple Silicon) |
| **Docker** | 24.0+ with Docker Compose v2 — [Docker Desktop](https://www.docker.com/products/docker-desktop/) on macOS |
| **Git** | Any recent version |
| **curl** | For the one-liner installer |
| **RAM** | 4 GB minimum (8 GB recommended) |
| **Disk** | 10 GB free space |
| **OpenRouter API Key** | [openrouter.ai/keys](https://openrouter.ai/keys) (starts with `sk-or-`) |

### Auto-Installation (Linux)

**The installer will automatically detect and offer to install missing dependencies** (on Ubuntu/Debian systems):

- ✅ **Git & curl** → Installed via `apt-get` if missing
- ✅ **Docker Compose** → Installed automatically as plugin (`docker-compose-plugin`) or standalone binary if missing
- ℹ️ **Docker Engine** → If missing, the installer provides clear instructions and a quick-install command

You'll be prompted for confirmation before anything is installed. If you're on a non-Debian system, the installer will provide manual installation instructions.

### macOS

Install [Docker Desktop](https://docs.docker.com/desktop/install/mac-install/) before running the launcher. The script automatically detects Docker Desktop's install location (`~/.docker/bin`, `/usr/local/bin`, Homebrew) and adds it to the PATH if needed. Git and curl are included with Xcode Command Line Tools (`xcode-select --install`).

## Deployment Modes

The wizard presents three deployment options:

| Mode | What gets deployed | Use case |
|------|--------------------|----------|
| **Full Platform** (WEB + CLI) | Both stacks, auto-connected | Complete security workflow with UI |
| **Standalone WEB** | Browser-based dashboard only | Manual analysis, report management |
| **Standalone CLI** | Headless autonomous scanner only | CI/CD pipelines, automation, API-only |

In **Full** mode the launcher automatically configures CORS and points the WEB frontend to the CLI API — no manual wiring needed.

## Commands

```bash
./launcher.sh              # Interactive setup wizard
./launcher.sh status       # Service dashboard (container health + endpoints)
./launcher.sh start        # Start all services
./launcher.sh stop         # Stop all services
./launcher.sh restart      # Restart all services
./launcher.sh update       # Git pull + Docker rebuild
./launcher.sh uninstall    # Stop containers, remove volumes & install dir
./launcher.sh logs web     # Tail WEB stack logs
./launcher.sh logs cli     # Tail CLI stack logs
./launcher.sh help         # Show usage
```

> No `sudo` required. On Linux, your user needs Docker permissions (`sudo usermod -aG docker $USER`). On macOS, Docker Desktop handles permissions automatically.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      User Browser                        │
└─────────┬────────────────────────────────┬───────────────┘
          │                                │
          │ http://localhost:6869          │ http://localhost:8000
          │                                │
┌─────────▼────────────────┐     ┌────────▼──────────────────┐
│   WEB Stack (Docker)      │     │   CLI Stack (Docker)       │
│                           │     │                            │
│  ┌─────────────────────┐  │     │  ┌────────────────────┐   │
│  │ Nginx (Frontend)    │  │     │  │ FastAPI + AI Agents │   │
│  │ React SPA           │  │     │  │ Go Fuzzers          │   │
│  └────────┬────────────┘  │     │  │ Playwright Browser  │   │
│  ┌────────▼────────────┐  │     │  └────────┬───────────┘   │
│  │ Express + Prisma    │  │     │  ┌────────▼───────────┐   │
│  │ REST API + WebSocket│  │     │  │ SQLite + LanceDB   │   │
│  └────────┬────────────┘  │     │  └────────────────────┘   │
│  ┌────────▼────────────┐  │     │                            │
│  │ PostgreSQL          │  │     │                            │
│  └─────────────────────┘  │     │                            │
└───────────────────────────┘     └────────────────────────────┘
```

Each stack runs its own independent Docker Compose project. In **Full** mode, the WEB frontend sends scan requests to the CLI API endpoint.

### Default Ports

| Service | Port | Stack |
|---------|------|-------|
| WEB Frontend (Nginx) | **6869** | WEB |
| WEB Backend (Express) | 3001 (internal) | WEB |
| PostgreSQL | 5432 (internal) | WEB |
| CLI API (FastAPI) | **8000** | CLI |

Ports marked **(internal)** are only accessible between containers. The wizard auto-detects busy ports and proposes the next available one.

## What Gets Installed

The launcher installs the platform to:

```
~/bugtraceai/                     ← configurable via BUGTRACEAI_DIR env var
├── BugTraceAI-WEB/               ← cloned repo (if WEB selected)
│   └── .env.docker               ← generated config (ports, DB password, CLI URL)
├── BugTraceAI-CLI/               ← cloned repo (if CLI selected)
│   └── .env                      ← generated config (API key, CORS origins)
└── .launcher-state               ← JSON with deployment mode, ports, version
```

You can override the install directory:

```bash
BUGTRACEAI_DIR=/srv/bugtraceai ./launcher.sh
```

## Configuration

### WEB config: `~/bugtraceai/BugTraceAI-WEB/.env.docker`

| Variable | Description |
|----------|-------------|
| `POSTGRES_USER` | Database user (default: `bugtraceai`) |
| `POSTGRES_PASSWORD` | Database password (auto-generated, 24 chars) |
| `POSTGRES_DB` | Database name (default: `bugtraceai_web`) |
| `FRONTEND_PORT` | Public frontend port (default: `6869`) |
| `VITE_CLI_API_URL` | CLI API URL (auto-set in Full mode, empty in Standalone WEB) |

### CLI config: `~/bugtraceai/BugTraceAI-CLI/.env`

| Variable | Description |
|----------|-------------|
| `OPENROUTER_API_KEY` | Your OpenRouter API key |
| `BUGTRACE_CORS_ORIGINS` | Allowed origins (`*` in Standalone CLI, `http://localhost:<port>` in Full mode) |

After editing configs, restart for changes to take effect:

```bash
nano ~/bugtraceai/BugTraceAI-CLI/.env
./launcher.sh restart
```

## Updating

```bash
./launcher.sh update
```

Pulls the latest code from both repos and rebuilds Docker images. The CLI's `docker-compose.yml` is re-patched automatically after pulling.

## Uninstalling

```bash
./launcher.sh uninstall
```

Stops all containers, removes Docker volumes (including databases), and deletes the `~/bugtraceai/` directory. Asks for confirmation before proceeding.

## Troubleshooting

**Services not starting:**

```bash
./launcher.sh status               # Check container health
./launcher.sh logs web             # WEB stack logs
./launcher.sh logs cli             # CLI stack logs
docker ps -a | grep bugtraceai     # Raw container status
```

**Port conflicts:** The wizard auto-detects occupied ports. You can type a custom port number (1024-65535) when prompted, or press `n` to cycle to the next available one.

**API key issues:** Verify your key at [openrouter.ai/keys](https://openrouter.ai/keys). It should start with `sk-or-`. The wizard warns you if it doesn't match this pattern but lets you continue anyway.

**Permission issues (Linux):** Your user needs Docker permissions. Run `sudo usermod -aG docker $USER` and re-login.

**Docker not found (macOS):** Make sure Docker Desktop is installed and running. The launcher auto-detects common install paths, but if Docker still isn't found, open Docker Desktop first and try again.

**Existing installation detected:** If `~/bugtraceai/` already exists, the wizard offers to reinstall (wipe + fresh setup) or update (pull + rebuild).

## How the Install Script Works

The one-liner clones this repo to `~/bugtraceai-launcher/` and launches the interactive wizard, which:

1. **Checks dependencies**: Docker, Docker Compose, Git, curl, RAM, and disk space
2. **Selects deployment mode**: Full (WEB + CLI), Standalone WEB, or Standalone CLI
3. **Configures**: Asks for OpenRouter API key, proposes ports, generates `.env` files
4. **Deploys**: Clones repos, builds Docker images, starts services, runs health checks

## License

MIT License. See the [LICENSE](LICENSE) file for details.

## Links

- **Website**: [bugtraceai.com](https://bugtraceai.com)
- **GitHub**: [github.com/BugTraceAI](https://github.com/BugTraceAI)
- **Issues**: [GitHub Issues](https://github.com/BugTraceAI/BugTraceAI-Launcher/issues)

---

<p align="center">
  Made with care by Albert C. <a href="https://x.com/yz9yt">@yz9yt</a><br/>
  <a href="https://bugtraceai.com">bugtraceai.com</a>
</p>
