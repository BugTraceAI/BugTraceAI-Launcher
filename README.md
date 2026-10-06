<p align="center">
  <img src="logo.png" alt="BugTraceAI" width="120" />
</p>

<h1 align="center">BugTraceAI Launcher</h1>

<p align="center">
  Universal installer for BugTraceAI: terminal, WEB and scanning servers.
</p>

<p align="center">
  <a href="https://bugtraceai.com"><img src="https://img.shields.io/badge/Website-bugtraceai.com-blue?logo=google-chrome&logoColor=white" /></a>
  <a href="https://deepwiki.com/BugTraceAI/BugTraceAI-Launcher"><img src="https://img.shields.io/badge/Wiki-DeepWiki-000?logo=wikipedia&logoColor=white" /></a>
  <a href="https://deepwiki.com/BugTraceAI/BugTraceAI-Launcher"><img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki" /></a>
  <img src="https://img.shields.io/badge/Version-3.3.20-blue" />
  <img src="https://img.shields.io/badge/License-Apache--2.0-blue.svg" />
  <img src="https://img.shields.io/badge/Bash-3.2+-4EAA25?logo=gnu-bash&logoColor=white" />
  <img src="https://img.shields.io/badge/Runtime-Local%20or%20Docker-2496ED?logo=docker&logoColor=white" />
</p>

Launcher version source of truth: [VERSION](VERSION)

**v3.3.20**: give local API/MCP update checks up to 120 seconds for cold startup,
and distinguish process exit from readiness timeout. The previous approximately
30-second window could stop an API while its first embedding model was loading.

**v3.3.19**: make Docker status checks use cached sudo access when the current
Linux login cannot access the Docker socket, and report permission errors
instead of claiming running containers are missing.

**v3.3.18**: show the terminal-workspace command after installation only when
the selected profile installed a CLI interface that includes the TUI.

**v3.3.17**: preserve the selected products, interface, runtime, global command
and optional toolboxes when Linux restarts the wizard to apply Docker group
membership. The installer resumes setup without repeating its selection menus.

**v3.3.16**: coordinate the candidate manifest with CLI 4.0.31-beta, WEB
2.0.32-beta and API 1.4.11-beta. These refs are backed up in the private
component repositories; the public release remains unavailable until the
curated component tags are published.

**v3.3.15**: make combined WEB + API installs share the API-owned Docker network,
and keep standalone WEB installs on their own network.

---

One installation entry point for the BugTraceAI platform. Choose what you want
to use; the launcher downloads the required repositories, selects interface
dependencies, connects backends, configures ports and verifies the installation.
Bare `install.sh` entry points in the ecosystem, CLI, WEB and API repositories
open this same visual menu, suggesting the relevant profile without deploying
it automatically. Direct component installation remains available through
explicit standalone paths and documented options for developers and agents.

**v3.3.12**: show runtime update failures as actionable messages without a
Python traceback. Also pin the API engine to amd64 for its packaged tools, while CLI and
WEB retain their native platform. Also report every unavailable component tag together before setup or
updates, so users can see why a coordinated release is not ready.

**v3.3.9**: respect the installer's choice to keep existing Docker containers;
deployments now report a name conflict instead of silently deleting them.

**v3.3.8**: keep version and health-response checks compatible with the Bash
3.2 parser shipped by macOS.

**v3.3.7**: install logs fall back to the user's state directory when the
Launcher checkout is read-only, without printing a shell error or blocking the
TUI. **v3.3.6**: component entry points verify the published Launcher's version
and stop before running an incompatible older installer. **v3.3.5**: piped
launches only reconnect to `/dev/tty` when stderr is attached to a terminal, and
only clear the screen for terminal output. This avoids misleading `/dev/tty`
errors and screen-control sequences over non-interactive SSH. **v3.3.4**:
conflict checks run after profile/runtime selection, only cover
selected Docker services, and preserve data volumes when removing containers.

**v3.3.3**: update previews confirm that every selected release tag exists on
the configured remotes before presenting a candidate as available. A missing
or unreachable component tag stops the preview without touching the installation.

**v3.3.2**: provider keys are optional during installation; generated API/CLI
configuration contains no empty key assignment, and the summary explains how
to configure credentials later. Press Enter at the provider-key prompt to
continue; add the key locally before starting AI-powered scans. WEB + CLI now
share the proxy network reliably, and health checks match the CLI and
Kiterunner response formats, including the valid no-key CLI state.

**v3.3.1**: detects missing Python `venv` support by creating a pip-ready test
environment, so clean Ubuntu installs enable the visual Launcher instead of
silently falling back to the legacy text wizard. Incomplete cached TUI
environments are preserved and rebuilt safely.

**v3.3.0**: fresh installs use one tagged release combination. The TUI previews
updates, and the updater prepares all source/dependencies/images before switching.
Local configuration and data volumes remain in place; failed activation has a
recovery journal and previous source/runtime backups.

**v3.2.2**: the universal Launcher is the only guided installer. Component
entries delegate here; explicit runtime backends support direct agents and
older automation without additional selection menus. API service management
remains separate and preserves local configuration.

**v3.2.0**: interactive purple/coral Textual TUI for selecting products,
runtime and optional toolboxes; one profile catalog drives the TUI, standard
installer and AI installer. The TUI dependency is pinned and isolated in the
user cache. Updating an existing Launcher preserves local changes.

**v3.1.0**: universal profiles shared by the standard and AI installers,
automatic WEB backend selection, an independent API-target server, readable
setup summaries, a preview command and repair of the saved selection.

**v3.0.9**: honors explicit local overrides and saved Docker profiles, reads local logs without Docker, and retains reconfigured CLI profiles and platform inventory. Legacy CLI 3.x is rejected for TUI use.

**v3.0.8**: preserves verified deployment state if global command registration fails and forwards TERM for installed Docker TUI profiles.

**v3.0.7**: adds optional user-global `btai` registration after choosing interface and runtime, including full-platform TUI installs and AI setup. Saved choices survive updates and repairs.

**v3.0.6**: standalone CLI installation now asks TUI / API + MCP / both, then local / Docker. The standard and AI entry points share the CLI installer; update and repair preserve saved choices. WEB deployments require API and may additionally include TUI.

**v3.0.5**: adds `./launcher.sh tui`, preferring the active refactor checkout in a development workspace and otherwise opening the installed CLI container. Standard and AI installers accept explicit CLI repository/branch overrides.

**v3.0.4**: fixes Compose build timeouts with options, preserves deployment inventory during partial repairs, tears down all selected Compose profiles before uninstalling, and validates service health and updater patches. CLI-only installs include their MCP service and port.

**New in v3.0.0**: the installer validates every selected service before reporting success, installs BugTraceAI-API REST + MCP, keeps CLI MCP ownership in the CLI Compose project, repairs reconFTW Compose YAML safely on ARM and x86, starts CLI before WEB, and supports WEB+API without a local CLI. The AI assistant now configures and verifies BugTraceAI-API too.

**v2.9.7**: the CLI startup no longer removes the standalone `bugtrace-api` container in Full/WEB deployments, and API REST/MCP ports cannot be selected twice. BugTraceAI-API's REST and MCP endpoints are shown separately during setup, after deployment, and in `status`; its Streamable HTTP MCP endpoint is also added to `mcp-config.json` as `bugtraceai-api`.

**v2.9.5**: a reinstall now re-enters its newly-created target directory before cloning components, so an installation started from a replaced directory can continue through WEB, CLI, BugTraceAI-API, and optional agents. Interrupted installs now state that remaining components were not installed.

**v2.9.4**: the standard installer labels the automatically included BugTraceAI-API in the Full and WEB deployment choices and in the selected-components summary. The **AI Setup & Repair Assistant** preserves the CLI/MCP ports and shared Docker network when it writes or repairs the CLI `.env`, so Launcher-managed deployments remain aligned with the WEB proxy and standalone CLI installations.

**v2.9.0**: DeepSeek V4.1 Flash via OpenRouter with sticky Qwen 3.8 Max (0902) failover; one visible native `sudo` ticket (never stored); host-held API key; dynamic ports; Docker Engine bootstrap on Linux; reconFTW built from local source; Kali in a separate Compose step; `install.log` next to `launcher.sh`.

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

The Launcher opens an interactive terminal UI. Choose a profile to see exactly
which products and services it installs, then select the runtime and optional
WEB toolboxes. `terminal`, `server`, and `terminal-server` support local Python
or Docker; `web`, `full`, and `api` require Docker. The selected profile is
passed to the installer once, so it does not ask you to choose the same
interfaces again. The remaining setup prompts configure provider credentials,
ports and deployment confirmation. The optional AI Setup & Repair Assistant is
available from the TUI; it is not an extra question before the installer opens.

The TUI uses Python 3.10+ and installs pinned Textual into an isolated
per-user cache. If the TUI runtime cannot start, the compatible text wizard
remains available with `BUGTRACEAI_CLASSIC=1 ./launcher.sh`.

Component entry points suggest `terminal` (CLI), `web` (WEB), `api`
(API-target engine) or `full` (ecosystem). All profiles remain available in the
menu. `BUGTRACEAI_LAUNCHER_INITIAL_PROFILE` changes only this initial highlight;
it does not approve or start installation. The compatibility bootstrap has one
source in [component-bootstrap.sh](component-bootstrap.sh).

## Requirements

| Requirement            | Details                                                                                                   |
| ---------------------- | --------------------------------------------------------------------------------------------------------- |
| **OS**                 | Linux (x86_64) or macOS (Intel / Apple Silicon)                                                           |
| **Runtime** | Python 3.10+ for the Launcher TUI and local terminal/CLI-server installs; Docker + Compose for container profiles |
| **Git**                | Any recent version                                                                                        |
| **curl**               | For the one-liner installer                                                                               |
| **RAM**                | 4 GB minimum (8 GB recommended)                                                                           |
| **Disk**               | 10 GB free space                                                                                          |
| **LLM provider key** | Configure through TUI/F7 or during platform setup                                   |

### Auto-Installation (Linux)

**The installer will automatically detect and offer to install missing dependencies** across major Linux distros:

- ✅ **Git, curl & Python** → Installed via your package manager (`apt-get`, `dnf`, `yum`, `pacman`, or `zypper`) if missing
- ✅ **Launcher TUI runtime** → Pinned Textual installed into an isolated user cache, not into the system Python
- ✅ **Docker Engine** → Installed automatically via Docker's official installer (`get.docker.com`), with a distro-package fallback, then the daemon is started and your user is added to the `docker` group
- ✅ **Docker Compose** → Installed automatically as plugin (`docker-compose-plugin`) or standalone binary if missing

You'll be prompted for confirmation before anything is installed. If no supported package manager is found, the installer provides manual installation instructions.

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

## Universal installation profiles

| Profile | What you get | Runtime |
| --- | --- | --- |
| `terminal` | CLI scanning engine with the visual terminal TUI | Local Python or Docker |
| `web` | WEB dashboard/database plus CLI web-scanning API/MCP and BugTraceAI-API target engine | Docker |
| `full` | WEB and both scanning engines, plus the CLI terminal TUI | Docker |
| `server` | CLI web-scanning engine, exposed through API + MCP | Local Python or Docker |
| `terminal-server` | CLI TUI + web-scanning API/MCP, without the WEB app | Local Python or Docker |
| `api` | BugTraceAI-API engine for API-target testing, with REST + MCP | Docker |

The **CLI web-scanning API/MCP** serves the CLI scanning engine.
**BugTraceAI-API** is the separate engine for API-target scans. A WEB selection includes both so the
browser workspace can use both scan types. Optional reconFTW/Kali tools are
offered only for WEB profiles. BugStore is a separate practice target, not a
required platform dependency.

Preview a selection without downloads, installation or starting services:

```bash
./launcher.sh plan --profile full
./launcher.sh plan --profile terminal --runtime local --global yes
```

Install using the same universal flow with choices supplied as flags:

```bash
./launcher.sh install --profile terminal --runtime local --global yes
./launcher.sh install --profile web
./launcher.sh install --profile full --global yes
./launcher.sh install --profile server --runtime docker --global no
./launcher.sh install --profile api
```

Provider, ports, optional tools and any system password prompts remain
interactive. These flags do not imply an unattended installation. Global
`btai` is available for profiles with a TUI. With Docker the workspace still
appears in your terminal; its process runs in the container. New terminal
sessions pick up the registered command; the installer also shows how to use
it in the current session and offers to open the workspace immediately.

Selections are saved in `.launcher-state`; the CLI also retains its own
installation profile. `update` applies the tagged compatible release to the saved selection after preparation and validation.
`repair` rebuilds/verifies that selection without pulling updates or replacing
provider/database credentials. If saved configuration is missing, repair stops
and reports it instead of inventing defaults. Old WEB-only/CLI profiles remain
supported for update, repair and service management.

## Compatible updates

The Launcher uses one tagged combination of CLI, WEB and API-target versions.
It checks that every selected release tag is available before presenting an
update as ready. Choose **Update installation** in the TUI to review the saved
installation, or run `./launcher.sh update --plan`. Builds finish before the
switch, configuration and data are retained, and service checks must pass before
success is reported. Interrupted activation can be recovered with
`./launcher.sh update --recover`.
See [Compatible updates](#compatible-updates) for update and recovery guidance.

## Commands

```bash
./launcher.sh              # Universal installation wizard
./launcher.sh plan --profile full  # Preview; no installation
./launcher.sh tui          # Real terminal workspace; --demo is optional
./launcher.sh status       # Service dashboard (container health + endpoints)
./launcher.sh start        # Start all services
./launcher.sh stop         # Stop all services
./launcher.sh restart      # Restart all services
./launcher.sh update --plan # Review installed and target versions (read-only)
./launcher.sh update       # Prepare, activate and verify compatible releases
./launcher.sh update --recover # Restore an interrupted update
./launcher.sh repair       # Keep saved selection/config; rebuild and verify
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
          │ http://localhost:<WEB_PORT>    │ http://localhost:<CLI_PORT>
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

Each stack runs its own independent Docker Compose project. In **Full** mode, the WEB frontend can send scans to both the CLI API and BugTraceAI-API; the API engine is also enabled for Standalone WEB deployments.

The Launcher writes the same `BTAI_SHARED_NETWORK` into the WEB and API
Compose environments. Both projects therefore join one named Docker bridge;
the WEB proxy reaches the API as `bugtrace-api:<selected API REST port>` while
the host-facing REST and MCP ports remain entirely selected by the wizard.

### Selected Ports

| Service               | Port            | Stack |
| --------------------- | --------------- | ----- |
| WEB Frontend (Nginx)  | selected by wizard | WEB   |
| WEB Backend (Express) | 3001 (internal) | WEB   |
| PostgreSQL            | 5432 (internal) | WEB   |
| CLI API (FastAPI)     | selected by wizard | CLI   |
| BugTraceAI-API REST   | selected by wizard | API   |
| BugTraceAI-API MCP    | selected by wizard | API   |

Ports marked **(internal)** are only accessible between containers. The wizard
selects every host-facing port, auto-detects conflicts and proposes the next
available one; the API and WEB proxy receive those selected values at runtime.
The numeric values shown during setup are proposals only, never service
contracts or hardcoded host bindings.

## What Gets Installed

The launcher installs the platform to:

```
~/bugtraceai/                     ← configurable via BUGTRACEAI_DIR env var
├── BugTraceAI-WEB/               ← cloned repo (if WEB selected)
│   └── .env.docker               ← generated config (ports, DB password, CLI URL)
├── BugTraceAI-CLI/               ← cloned repo (if CLI selected)
│   └── .env                      ← generated config (API key, CORS origins)
├── BugTraceAI-API/               ← cloned repo (if WEB selected)
│   └── .env                      ← generated provider configuration
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

**Installer log:** the wizard and the AI installer append events to `install.log` in the same directory as `launcher.sh` (override with `BUGTRACEAI_INSTALL_LOG`). API keys and env-style secrets are redacted. Docker image builds still go to `~/bugtraceai/.build.log`.

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

### MCP and Kali Toolbox Compatibility Notes

The launcher starts optional Compose profiles explicitly after the base WEB and CLI services are up. This keeps a full selection from attempting reconFTW or Kali during the initial WEB build.

If Docker reports that `../reconftw-mcp` cannot be found, run `./launcher.sh repair`. The launcher restores a completely missing sibling source checkout before building the recon profile. It intentionally refuses to overwrite an existing incomplete `reconftw-mcp` folder, so move that folder aside or restore its `Dockerfile` first if prompted.

**reconFTW MCP (Apple Silicon):**
- Forces `linux/amd64` for `six2dez/reconftw:main` on ARM hosts.
- Patches `reconftw-mcp` Dockerfile for Python venv fallback (`virtualenv`) when `ensurepip` fails.
- Forces SSE mode for WEB-managed MCP startup (`/sse` health path consistency).
- Extends reconFTW health timing on ARM emulation.
- Patches startup behavior to skip heavy `reconftw/install.sh` auto-bootstrap by default (`RECONFTW_AUTO_INSTALL=false`) to avoid health timeouts.

**Kali toolbox:**
- Replaces either upstream command format with a retrying startup command and verifies `nmap`, `hydra`, and `python3` before it stays running.
- `nuclei` is installed separately so a transient package issue does not take down the whole toolbox.
- The upstream Kali image is an interactive toolbox, not an HTTP/SSE MCP server, so it is not emitted as a fake MCP URL. Open a shell with `docker exec -it kali-mcp-server bash`.

If you still see MCP issues after pulling latest launcher changes, rebuild only the affected service:

```bash
cd ~/bugtraceai/BugTraceAI-WEB
docker compose --env-file .env.docker --profile recon --profile kali build --no-cache reconftw-mcp kali-mcp
docker compose --env-file .env.docker --profile recon --profile kali up -d reconftw-mcp kali-mcp
```

Then inspect logs:

```bash
docker logs --tail 200 reconftw-mcp
docker logs --tail 200 kali-mcp-server
```

**Existing installation detected:** If `~/bugtraceai/` already exists, the wizard offers to reinstall (wipe + fresh setup) or update (compatible release + verification).

## How the Install Script Works

The one-liner clones this repo to `~/bugtraceai-launcher/` and launches the interactive wizard, which:

1. **Bootstraps dependencies**: Git/curl first, then clones or updates the Launcher
2. **Opens the universal TUI**: select Terminal, WEB, both workspaces or a scanning server and review included products
3. **Selects runtime and optional tools**: local Python or Docker where supported; recon/Kali are explicit WEB add-ons
4. **Prepares the runtime**: Local Python or Docker as supported by the profile
5. **Configures**: Provider, ports and optional global command for the chosen interfaces
6. **Deploys**: Clones repos, builds Docker images, starts services, runs health checks

## AI-Assisted Installer

BugTraceAI Launcher includes an optional **AI Setup & Repair Assistant** (`ai_installer.py`) powered by **DeepSeek V4.1 Flash**, with an automatic sticky fallback to **Qwen 3.8 Max (0902)** (both via OpenRouter). A fresh target defaults to a Full install; an existing or partial target defaults to repair/diagnosis first. The assistant only asks when a real decision is needed, such as confirming a destructive reinstall. The API key is entered hidden only if no private local CLI configuration exists, destructive commands require confirmation, and the assistant can autonomously:

- Analyze your system configuration and error logs
- Diagnose Docker, network, port, or dependency issues
- Propose and apply fixes interactively
- Guide you through complex deployment scenarios (VM hosts, non-standard environments)

The AI mode starts only after you select it in the TUI. It then opens the operating system's normal `sudo` prompt once, keeping only sudo's temporary ticket for the running launcher; the password is never stored in Python, a shell variable, or the model context. If no locally saved key is available, it asks for and validates your OpenRouter API key before starting the agent. The key is never inserted into the system prompt: dedicated host tools write it directly to the private CLI configuration.

For AI-managed fresh installs, host ports are allocated dynamically and then verified from Docker's published mappings. The WEB proxy is wired to the resolved CLI endpoint by the host tool, not by asking the model to guess a port. Every successful command/tool result immediately triggers the next model turn; after verification passes, the same loop remains available for support and repairs.

### How to invoke

The TUI exposes AI setup and repair alongside the standard universal installer:

```bash
cd ~/bugtraceai-launcher
./launcher.sh
```

### Requirements

- **Python 3.8+** (usually already present)
- Your **OpenRouter API key** (the same one used for BugTraceAI)
- Internet access to reach the OpenRouter API

> The AI installer uses DeepSeek V4.1 Flash (falling back to Qwen 3.8 Max (0902)) through OpenRouter. You can override either model with `BTAI_INSTALLER_MODEL` and `BTAI_INSTALLER_FALLBACK_MODEL`; use `BTAI_INSTALLER_ACTION`, `BTAI_INSTALLER_MODE`, or `BTAI_INSTALLER_PROVIDER` only when you need to override the safe detected defaults. It is experimental and can run commands after you opt in, so review the terminal output and use the standard wizard if you prefer fully manual control.

## License

The BugTraceAI-owned portions of this distribution are licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) and [LICENSE-HISTORY.md](LICENSE-HISTORY.md).

## Links

- **Website**: [bugtraceai.com](https://bugtraceai.com)
- **GitHub**: [github.com/BugTraceAI](https://github.com/BugTraceAI)
- **Issues**: [GitHub Issues](https://github.com/BugTraceAI/BugTraceAI-Launcher/issues)

---

<p align="center">
  Made with care by Albert C. <a href="https://x.com/yz9yt">@yz9yt</a><br/>
  <a href="https://bugtraceai.com">bugtraceai.com</a>
</p>

## CLI 4.x terminal workspace

Use `./launcher.sh` and choose the **CLI terminal TUI**, **WEB dashboard +
engines**, **WEB + CLI TUI**, **CLI web-scan API/MCP**, **CLI TUI + web-scan API**, or
**API-target server** profile. The universal menu already selects the
interfaces and includes the required engines.
`setup-cli` remains available for existing standalone installation scripts.
Local TUI installations do not require a
Docker runtime; some scanning tools still use Docker. TUI-only Docker opens an
interactive scanner without publishing server ports. Full WEB deployments use
Docker and require the CLI API; their wizard offers API only or API + TUI.

For TUI/both, setup also offers the user-global **btai** command on macOS/Linux.
Open a new terminal and run `btai` from any folder. Registration uses
`~/.local/bin` without sudo and preserves unrelated existing commands.

Use `./launcher.sh tui` to open the installed terminal workspace or
`./launcher.sh api` to start the local API. The TUI runs **Recon → Discovery →
Strategy → Exploit → Validate → Report** with the tabs **Pipeline, Findings,
Agents, Timeline, Logs**. Enter the target, Depth and Max URLs at the top;
configure Provider with F7 and target authentication with Auth/F8. Auth accepts
a masked Bearer token or the WEB-compatible login YAML, including TOTP/2FA.
No scan starts until you press Start. F1 opens help.

The default source is the public BugTraceAI-CLI repository. CLI profiles require
its 4.x installer; older 3.x installations need to be updated first. Existing
installations update their current checkout and are not silently moved between
repositories or branches. `BUGTRACEAI_CLI_REPO` and `BUGTRACEAI_CLI_BRANCH`
select another source on a fresh clone.

### Saved profiles and source overrides

The CLI installer saves `.bugtrace-install.env`; `.launcher-state` stores the
profile and checkout path. Launcher updates and AI repair reuse this profile.
Switching interfaces does not automatically uninstall existing packages.

`./launcher.sh tui` honors the saved runtime, including Docker in full-platform
installations. `BUGTRACEAI_CLI_PATH` explicitly selects a local checkout before
saved routing. In the development workspace, the sibling
`BugTraceAI-CLI-refactor` checkout is preferred; standalone public installations
also support a sibling `BugTraceAI-CLI` checkout. CLI 3.x checkouts cannot open
this workspace; compatibility is checked before starting
TUI services.

Standalone installations read profile changes made by the CLI installer.
Local `logs cli` / `logs api` reads checkout logs without Docker. `setup-cli`
keeps an existing standalone checkout and refuses to overwrite a full WEB/API
inventory; use a separate `BUGTRACEAI_DIR` for a standalone installation.

Standalone setup and global registration require the CLI 4.0.14+ installer.

### Installation by your own AI agent

Copy this prompt into your coding agent with terminal access. It uses the
universal Launcher and defaults to a local terminal workspace plus `btai`.
Change the first line to request a different profile. The current coordinated
release requires Launcher 3.3.16+; component entry points require 3.3.14+.

```text
Install BugTraceAI through the universal Launcher: terminal profile,
local Python, with the user-global btai command. Perform the installation.

Read the Launcher README and help at
https://github.com/BugTraceAI/BugTraceAI-Launcher.git. The current coordinated
release requires Launcher 3.3.16 or newer; component entry points require
3.3.14 or newer. Clone into a suitable user-owned directory.
If an installation exists, preserve its configuration, credentials and
uncommitted changes. Use ./launcher.sh update or ./launcher.sh repair with
its saved selection unless I request a profile change. Do not replace an
existing checkout or switch its repository or branch silently.

For a fresh local TUI installation, review and then install:
./launcher.sh plan --profile terminal --runtime local --global yes
./launcher.sh install --profile terminal --runtime local --global yes

If I request WEB, use --profile web; WEB + TUI uses --profile full.
A headless web-scanning engine uses --profile server. TUI + CLI API/MCP
without WEB uses --profile terminal-server. API-target testing uses
--profile api. Local Python is supported for terminal, server and
terminal-server; WEB/full/api profiles use Docker. Install only the
requested components and let the launcher connect their dependencies.

Handle the required prompts and resolve setup errors using the repository
instructions. Keep system privilege/password prompts in my local terminal.
Do not change the runtime without asking. I will configure the LLM key
later through Provider/F7 for a terminal-only install. Never ask me to paste
credentials into chat or print existing secrets. Auth/F8 configures target
login separately. Platform setup can request its provider key locally.

Verify the version, saved profile and installed components. For TUI, verify
startup and quit in an interactive terminal when available; otherwise state
that visual verification is pending. Check btai registration and PATH in a
fresh shell. For servers, check health and MCP on the actual configured
ports. Do not start a scan as part of installation.

Finish with the installation directory, selected profile, checks performed
and exact commands to open the installed interfaces.
```
