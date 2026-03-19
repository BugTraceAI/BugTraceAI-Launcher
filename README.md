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
  <img src="https://img.shields.io/badge/Version-2.5.1-blue" />
  <img src="https://img.shields.io/badge/License-AGPL--3.0-blue.svg" />
  <img src="https://img.shields.io/badge/Bash-3.2+-4EAA25?logo=gnu-bash&logoColor=white" />
  <img src="https://img.shields.io/badge/Docker-Required-2496ED?logo=docker&logoColor=white" />
</p>

---

Interactive wizard that clones the BugTraceAI repos, builds Docker images, generates configs, sets up databases, and orchestrates all services. Deploy WEB, CLI, or both with a single command.

> This repository is part of the [BugTraceAI](https://github.com/BugTraceAI/BugTraceAI) monorepo (as a git submodule) and also works as a standalone repo.

## Quick Start

**One-liner install** (recommended):

```bash
curl -fsSL https://raw.githubusercontent.com/BugTraceAI/BugTraceAI-Launcher/main/install.sh | bash
```

Or step by step:

```bash
git clone https://github.com/BugTraceAI/BugTraceAI-Launcher.git ~/bugtraceai-launcher
cd ~/bugtraceai-launcher
./launcher.sh
```

The wizard will guide you step by step: choose deployment mode, enter your OpenRouter API key, configure ports, and confirm. The launcher handles the rest.

## Requirements

| Requirement            | Details                                                                                                   |
| ---------------------- | --------------------------------------------------------------------------------------------------------- |
| **OS**                 | Linux (x86_64) or macOS (Intel / Apple Silicon)                                                           |
| **Container Runtime** | Docker Engine 24.0+ + Compose (Linux), or on macOS: **Docker Desktop** OR **Colima** |
| **Git**                | Any recent version                                                                                        |
| **curl**               | For the one-liner installer                                                                               |
| **RAM**                | 4 GB minimum (8 GB recommended)                                                                           |
| **Disk**               | 10 GB free space                                                                                          |
| **OpenRouter API Key** | [openrouter.ai/keys](https://openrouter.ai/keys) (starts with `sk-or-`)                                   |

### Auto-Installation (Linux)

**The installer will automatically detect and offer to install missing dependencies** (on Ubuntu/Debian systems):

- ✅ **Git & curl** → Installed via `apt-get` if missing
- ✅ **Docker Compose** → Installed automatically as plugin (`docker-compose-plugin`) or standalone binary if missing
- ℹ️ **Docker Engine** → If missing, the installer provides clear instructions and a quick-install command

You'll be prompted for confirmation before anything is installed. If you're on a non-Debian system, the installer will provide manual installation instructions.

### Auto-Installation (macOS)

The launcher now supports **two runtime paths** on macOS:

- **Docker Desktop** (traditional)
- **Colima** (Docker Desktop-free)

If Docker is not ready, the wizard can:

- Prompt you to choose Docker Desktop or Colima
- Install missing dependencies with Homebrew (`docker`, `docker-compose`, `colima`, `qemu`, `lima-additional-guestagents`)
- Start the selected runtime automatically and continue installation

For best automation, install Xcode CLT first if missing:

```bash
xcode-select --install
```

## Deployment Modes

The wizard presents three deployment options:

| Mode                          | What gets deployed               | Use case                              |
| ----------------------------- | -------------------------------- | ------------------------------------- |
| **Full Platform** (WEB + CLI) | Both stacks, auto-connected      | Complete security workflow with UI    |
| **Standalone WEB**            | Browser-based dashboard only     | Manual analysis, report management    |
| **Standalone CLI**            | Headless autonomous scanner only | CI/CD pipelines, automation, API-only |

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

> No `sudo` required. On Linux, your user needs Docker permissions (`sudo usermod -aG docker $USER`). On macOS, the launcher can bootstrap either Docker Desktop or Colima.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      User Browser                        │
└─────────┬────────────────────────────────┬───────────────┘
          │                                │
          │ http://localhost:6869          │ http://localhost:8000
          │                                │
┌─────────▼─────────────────┐     ┌────────▼──────────────────┐
│   WEB Stack (Docker)      │     │   CLI Stack (Docker)      │
│                           │     │                           │
│  ┌─────────────────────┐  │     │  ┌─────────────────────┐  │
│  │ Nginx (Frontend)    │  │     │  │ FastAPI + AI Agents │  │
│  │ React SPA           │  │     │  │ Go Fuzzers          │  │
│  └────────┬────────────┘  │     │  │ Playwright Browser  │  │
│  ┌────────▼────────────┐  │     │  └────────┬────────────┘  │
│  │ Express + Prisma    │  │     │  ┌────────▼───────────┐   │
│  │ REST API + WebSocket│  │     │  │ SQLite + LanceDB   │   │
│  └────────┬────────────┘  │     │  └────────────────────┘   │
│  ┌────────▼────────────┐  │     │                           │
│  │ PostgreSQL          │  │     │                           │
│  └─────────────────────┘  │     │                           │
└───────────────────────────┘     └───────────────────────────┘
```

Each stack runs its own independent Docker Compose project. In **Full** mode, the WEB frontend sends scan requests to the CLI API endpoint.

### Default Ports

| Service               | Port            | Stack |
| --------------------- | --------------- | ----- |
| WEB Frontend (Nginx)  | **6869**        | WEB   |
| WEB Backend (Express) | 3001 (internal) | WEB   |
| PostgreSQL            | 5432 (internal) | WEB   |
| CLI API (FastAPI)     | **8000**        | CLI   |

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

| Variable            | Description                                                  |
| ------------------- | ------------------------------------------------------------ |
| `POSTGRES_USER`     | Database user (default: `bugtraceai`)                        |
| `POSTGRES_PASSWORD` | Database password (auto-generated, 24 chars)                 |
| `POSTGRES_DB`       | Database name (default: `bugtraceai_web`)                    |
| `FRONTEND_PORT`     | Public frontend port (default: `6869`)                       |
| `VITE_CLI_API_URL`  | CLI API URL (auto-set in Full mode, empty in Standalone WEB) |

### CLI config: `~/bugtraceai/BugTraceAI-CLI/.env`

| Variable                | Description                                                                     |
| ----------------------- | ------------------------------------------------------------------------------- |
| `OPENROUTER_API_KEY`    | Your OpenRouter API key                                                         |
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

**Docker not found (macOS):** Re-run `./launcher.sh` and choose a runtime when prompted. If you pick Colima, the launcher can install/start it automatically via Homebrew.

**Colima start fails with missing guest agent:** Install and retry:

```bash
brew install lima-additional-guestagents
colima start --runtime docker
```

### macOS MCP Compatibility Notes (reconFTW + Kali)

The launcher now applies macOS-focused compatibility patches during deployment when these MCPs are enabled.

**reconFTW MCP (Apple Silicon):**
- Forces `linux/amd64` for `six2dez/reconftw:main` on ARM hosts.
- Patches `reconftw-mcp` Dockerfile for Python venv fallback (`virtualenv`) when `ensurepip` fails.
- Forces SSE mode for WEB-managed MCP startup (`/sse` health path consistency).
- Extends reconFTW health timing on ARM emulation.
- Patches startup behavior to skip heavy `reconftw/install.sh` auto-bootstrap by default (`RECONFTW_AUTO_INSTALL=false`) to avoid health timeouts.

**Kali MCP:**
- Rewrites the Kali startup command into a robust single `bash -lc` command to avoid multiline parsing/continuation issues during package install.
- Verifies key binaries (`nmap`, `hydra`, `python3`) after install in container startup.

If you still see MCP issues after pulling latest launcher changes, rebuild only the affected service:

```bash
cd ~/bugtraceai/BugTraceAI-WEB
docker compose --env-file .env.docker build --no-cache reconftw-mcp kali-mcp
docker compose --env-file .env.docker up -d reconftw-mcp kali-mcp
```

Then inspect logs:

```bash
docker logs --tail 200 reconftw-mcp
docker logs --tail 200 kali-mcp-server
```

**Existing installation detected:** If `~/bugtraceai/` already exists, the wizard offers to reinstall (wipe + fresh setup) or update (pull + rebuild).

## How the Install Script Works

The one-liner clones this repo to `~/bugtraceai-launcher/` and launches the interactive wizard, which:

1. **Bootstraps dependencies**: Git/curl first, then Docker runtime + Compose checks
2. **Selects macOS runtime when needed**: Docker Desktop or Colima
3. **Selects deployment mode**: Full (WEB + CLI), Standalone WEB, or Standalone CLI
4. **Configures**: Asks for OpenRouter API key, proposes ports, generates `.env` files
5. **Deploys**: Clones repos, builds Docker images, starts services, runs health checks

## License

AGPL-3.0 License. See the [LICENSE](LICENSE) file for details.

## Links

- **Website**: [bugtraceai.com](https://bugtraceai.com)
- **GitHub**: [github.com/BugTraceAI](https://github.com/BugTraceAI)
- **Issues**: [GitHub Issues](https://github.com/BugTraceAI/BugTraceAI-Launcher/issues)

---

<p align="center">
  Made with care by Albert C. <a href="https://x.com/yz9yt">@yz9yt</a><br/>
  <a href="https://bugtraceai.com">bugtraceai.com</a>
</p>
