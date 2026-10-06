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
  <img src="https://img.shields.io/badge/Version-3.3.26-blue" />
  <img src="https://img.shields.io/badge/License-Apache--2.0-blue.svg" />
  <img src="https://img.shields.io/badge/Bash-3.2+-4EAA25?logo=gnu-bash&logoColor=white" />
  <img src="https://img.shields.io/badge/Runtime-Local%20or%20Docker-2496ED?logo=docker&logoColor=white" />
</p>

Launcher version source of truth: [VERSION](VERSION)

The Launcher installs BugTraceAI-WEB, BugTraceAI-CLI and BugTraceAI-API as
independent products or in any combination. Enter and verify a provider key,
choose the standard Wizard or the built-in AI installer, select modules and
ports, and review the plan before installing. Component `install.sh` entry
points open this same TUI. Direct component installation remains available for
scripts and coding agents.

[Install](#quick-start) · [Choose a profile](#universal-installation-profiles) ·
[Manage services](#commands) · [Updates](#compatible-updates) ·
[Install with your own agent](#installation-by-your-own-ai-agent) ·
[Releases](https://github.com/BugTraceAI/BugTraceAI-Launcher/releases)

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

The first screen asks you to choose a provider, enter its required API key and
select **Verify and continue**. A failed check stays on this screen with a retry
message. Changing the provider or key requires a new check. OpenRouter and
Anthropic checks verify access without generating text; Z.ai uses a short test
request, so provider usage may apply. A successful access check does not
guarantee sufficient balance or model access for a complete scan.

Next choose **Install with Wizard** or **Install with AI**. Both remain inside
the TUI and use the same product checkbox form. WEB, CLI and the API-target
engine are independent; only checked modules are installed. WEB-only can
connect to external engines later. Enable the optional CLI TUI separately.
Docker is the default; Advanced offers local Python for CLI-only selections.
The provider key stays masked and is passed to installation in a private
configuration file. Configure only the ports used by selected modules.
reconFTW and Kali require WEB and CLI to both be selected.

Review the selected products and confirm installation with your chosen method.
Both stay inside the TUI: output and conversation appear in an embedded session,
with a reply field for questions and native hidden credential/password prompts.
Stop ends the child session; Back returns after it ends. The built-in AI
installer uses provider model tokens and supports API-only or the full
platform selection: WEB, CLI, API and the CLI TUI, with OpenRouter or
Anthropic. Use the Wizard for every other combination and for Z.ai.
Installation always requires the verified provider key; only AI-assisted
setup makes model calls for its conversation. Update and AI repair are
separate actions for existing installations.

The TUI uses Python 3.10+ and installs pinned Textual into an isolated
per-user cache. If the TUI runtime cannot start, the compatible text wizard
remains available with `BUGTRACEAI_CLASSIC=1 ./launcher.sh`.

Component entry points suggest their own starting selection: `terminal` for
CLI, `web` for WEB, `api` for the API-target engine and `full` for all
modules. In the TUI these are starting checkboxes, not separate installation
questions. You can change the modules before review.
`BUGTRACEAI_LAUNCHER_INITIAL_PROFILE` changes only the initial selection; it
does not approve or start installation. The compatibility bootstrap has one
source in [component-bootstrap.sh](component-bootstrap.sh).

## Requirements

| Requirement            | Details                                                                                                   |
| ---------------------- | --------------------------------------------------------------------------------------------------------- |
| **OS** | Linux amd64; Launcher startup checked on a clean Lubuntu VM. macOS and ARM remain unvalidated |
| **Runtime** | Python 3.10+ for the Launcher TUI and local terminal/CLI-server installs; Docker + Compose for container profiles |
| **Git**                | Any recent version                                                                                        |
| **curl**               | For the one-liner installer                                                                               |
| **RAM**                | 4 GB minimum (8 GB recommended)                                                                           |
| **Disk**               | 10 GB free space                                                                                          |
| **Provider API key** | Required on the first setup screen and verified before installation; enter it locally |

### Release validation

The v3.3.26 automated Launcher suite passed with 399 tests and 25 subtests.
A clean Lubuntu VM confirmed the TUI starts and rejects an invalid provider
key. A complete module installation and a live scan were not performed in this
release check.

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
| `web` script preset | WEB dashboard/database plus CLI web-scanning API/MCP and BugTraceAI-API target engine | Docker |
| `full` | WEB and both scanning engines, plus the CLI terminal TUI | Docker |
| `server` | CLI web-scanning engine, exposed through API + MCP | Local Python or Docker |
| `terminal-server` | CLI TUI + web-scanning API/MCP, without the WEB app | Local Python or Docker |
| `api` | BugTraceAI-API engine for API-target testing, with REST + MCP | Docker |

The **CLI web-scanning API/MCP** serves the CLI scanning engine.
**BugTraceAI-API** is the separate engine for API-target scans. WEB can connect
to either or both when they are selected. The interactive TUI's `web`
suggestion checks WEB only; `full` checks WEB, CLI, API and the CLI TUI.
The command-line `web` script preset remains a bundled selection of WEB plus
both scanning engines for compatibility. Prefer the TUI to select independent
modules. Optional reconFTW/Kali tools require WEB and CLI. BugStore is a
separate practice target, not a required platform dependency.

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

### Independent checkbox selections

| Checked modules | Installed products | Runtime |
| --- | --- | --- |
| WEB only | Dashboard and database; connect external engines later | Docker |
| CLI only | Web-scanning engine, REST/MCP and optional terminal TUI | Docker or local Python |
| API only | API-target scanner, REST/MCP | Docker |
| Any combination including WEB or API | Exactly the checked modules | Docker |

You can edit the TUI's starting selection before review. The checkbox form
also supports combinations such as `web-only`, `web-cli`, `web-api` and
`engines`.

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

Run the Launcher as your normal user. Linux setup may request `sudo` locally
to install system dependencies or prepare Docker access. The first TUI screen
requires a provider API key and verifies access before offering installation
methods. Enter keys in the local terminal, never in a chat prompt.

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
├── BugTraceAI-API/               ← cloned repo (if API or WEB selected)
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
| Provider-specific key | The verified OpenRouter, Anthropic or Z.ai key selected in the Launcher |
| `BUGTRACE_CORS_ORIGINS` | Allowed origins (`*` in Standalone CLI, `http://localhost:<port>` in Full mode) |

After editing configs, restart for changes to take effect:

```bash
nano ~/bugtraceai/BugTraceAI-CLI/.env
./launcher.sh restart
```

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

**Provider key issues:** Check that the selected provider matches the key.
The first screen requires a valid key and offers a retry after a failed check.
OpenRouter and Anthropic checks do not generate text; Z.ai makes a short test
request that may incur provider usage.

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

## CLI 4.x terminal workspace

Use `./launcher.sh` to enter the provider key, choose Wizard or AI, and select
the CLI terminal TUI, WEB dashboard, CLI web-scanning API/MCP and API-target
engine independently. The `full` preset checks all products and the terminal
TUI; you can change its checkboxes before review.
`setup-cli` remains available for existing standalone installation scripts.
Local TUI installations do not require a
Docker runtime; some scanning tools still use Docker. TUI-only Docker opens an
interactive scanner without publishing server ports. Any selection containing
WEB or the API-target engine uses Docker.

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

Copy this prompt into Codex, Claude Code, Cursor or another coding agent with
access to your local terminal. The Launcher stays interactive so you can
choose the products, provider and installation method yourself.

```text
Help me install BugTraceAI using the official universal Launcher.

First read:
https://github.com/BugTraceAI/BugTraceAI-Launcher#readme

Follow those instructions using the official installer:
https://raw.githubusercontent.com/BugTraceAI/BugTraceAI-Launcher/main/install.sh

Ask which independent modules I want: BugTraceAI-WEB, BugTraceAI-CLI,
BugTraceAI-API, or a combination. Install only the modules I choose. Let me
choose Wizard or the built-in AI installer when my selection is supported;
use Wizard for other combinations.

Preserve any existing installation, configuration and data. Run the
Launcher in my local interactive terminal. I will enter and verify the
provider API key there, choose ports and review the plan before installation.
Keep credentials out of chat and logs. Do not start a scan.

Verify the selected services on their configured ports. If I enable the
global btai command, check it from a fresh shell. Report the installation
location, launch commands, checks completed and any checks still pending.
```

## AI-Assisted Installer

The built-in **Install with AI** choice is an installation assistant inside the
Launcher TUI. It is separate from the coding-agent prompt above and from
**Repair / diagnose** for an existing installation.

Enter and verify the required provider key first, then choose Install with AI
and check the modules you want. The assistant uses OpenRouter or Anthropic
model calls, which can incur usage charges. It currently supports an
API-only install or the full platform selection: WEB, CLI, API and the CLI TUI.
Use **Install with Wizard** for WEB-only, CLI-only, other combinations and
Z.ai. The Wizard
supports all available module combinations.

AI-assisted installation runs inside the TUI, uses the reviewed selection and
does not start a scan. The provider key is entered locally and stays masked;
the assistant does not ask you to put the secret into the conversation.

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
