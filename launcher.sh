#!/bin/bash
#
# BugTraceAI Launcher
# One-command deployment for the BugTraceAI security platform
#
# Usage: ./launcher.sh [command]
#
# Commands:
#   (none)        Interactive setup wizard
#   tui [--demo]  Open the real terminal workspace
#   status        Show service status
#   start         Start all services
#   stop          Stop all services
#   restart       Restart all services
#   logs [web|api|cli|mcp] View logs
#   update        Update to the tested release combination
#   uninstall     Remove everything
#

# ── Constants ────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/VERSION"
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || printf '3.3.2')"
# Fail loudly if HOME is unset/empty rather than silently deriving "/bugtraceai"
# (which would later flow into `rm -rf "$INSTALL_DIR"`).
: "${HOME:?HOME must be set}"
INSTALL_DIR="${BUGTRACEAI_DIR:-$HOME/bugtraceai}"
STATE_FILE="$INSTALL_DIR/.launcher-state"
WEB_DIR="$INSTALL_DIR/BugTraceAI-WEB"
CLI_DIR="$INSTALL_DIR/BugTraceAI-CLI"
BTAI_DIR="$INSTALL_DIR/BugTraceAI-API"
RECON_DIR="$INSTALL_DIR/reconftw-mcp"
WEB_REPO="https://github.com/BugTraceAI/BugTraceAI-WEB.git"
CLI_REPO="${BUGTRACEAI_CLI_REPO:-https://github.com/BugTraceAI/BugTraceAI-CLI.git}"
CLI_BRANCH="${BUGTRACEAI_CLI_BRANCH:-}"
BTAI_REPO="${BUGTRACEAI_API_REPO:-https://github.com/BugTraceAI/BugTraceAI-API.git}"
RECON_REPO="https://github.com/BugTraceAI/reconftw-mcp.git"

# GitHub repos for version checks
GITHUB_API_BASE="https://api.github.com/repos/BugTraceAI"
REPOS_CLI="BugTraceAI-CLI"
REPOS_WEB="BugTraceAI-WEB"
REPOS_BTAI="BugTraceAI-API"
REPOS_RECON="reconftw-mcp"
REPOS_LAUNCHER="BugTraceAI-Launcher"
CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
VERSION_CACHE="${BUGTRACEAI_VERSION_CACHE:-$CACHE_HOME/bugtraceai-launcher/version_cache}"
VERSION_CACHE_TTL=86400  # 24 hours in seconds

# Platform detection
IS_MACOS=false
[[ "$(uname)" == "Darwin" ]] && IS_MACOS=true

# Wizard state
DEPLOY_MODE=""
INSTALL_PROFILE="${BUGTRACEAI_PROFILE:-}"
REQUESTED_RUNTIME=""
REQUESTED_GLOBAL=""
WEB_PORT=""
CLI_PORT=""
BTAI_PORT=""
BTAI_MCP_PORT=""
BTAI_SHARED_NETWORK="bugtraceai-platform"
MCP_PORT=""
API_KEY=""
API_KEY_ENV_VAR=""
LLM_PROVIDER="openrouter"
CLI_INTERFACE="api"
CLI_RUNTIME="docker"
CLI_MANAGED=false
CLI_PROFILE_SAVED=false
CLI_SETUP_CHECKOUT=""
CLI_GLOBAL=no
RELEASE_PINNED=false
MENU_SELECTION=0

# MCP Selection state
INSTALL_WEB=false
INSTALL_CLI=false
INSTALL_BTAI=false
MCP_CLI_ENABLED=false
MCP_RECON_ENABLED=false
MCP_KALI_ENABLED=false
RECON_PORT=""
SELECTED_INDICES=()

# Compose profiles are deliberately passed as explicit CLI flags.  Exporting
# COMPOSE_PROFILES leaks into the base WEB startup and starts every optional
# agent before the launcher reaches its dedicated MCP step.
WEB_MCP_PROFILE_ARGS=()
WEB_MCP_PROFILE_NAMES=()

# ── Colors & Symbols ────────────────────────────────────────────────────────

# ANSI-C quoting ($'...') stores REAL ESC bytes, not the literal text "\033".
# This matters because `printf "%s" "$DIM"` does NOT expand backslash escapes in
# arguments — with the old '\033' form the spinner printed a literal "\033[2m".
RED=$'\033[0;31m'    GREEN=$'\033[0;32m'  YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'   CYAN=$'\033[0;36m'   BOLD=$'\033[1m'
DIM=$'\033[2m'       NC=$'\033[0m'
OK="${GREEN}✓${NC}" FAIL="${RED}✗${NC}" ARROW="${CYAN}➜${NC}"

# Reset terminal on exit/interrupt to prevent broken TTY from spinners or ANSI codes
_cleanup_terminal() {
    printf '\033[0m'    # reset all attributes
    printf '\033[?25h'  # show cursor
    stty sane 2>/dev/null || true
}

# On Ctrl+C / TERM: restore the TTY and actually exit. The build runs in the
# foreground (see _build_with_progress), so SIGINT already reaches docker
# directly — there is no background PID to kill here. We disarm the EXIT trap
# first so _cleanup_terminal runs exactly once.
_on_interrupt() {
    trap - EXIT
    printf '\n%s[WARN]%s BugTraceAI installation interrupted. No later components were installed.\n' "$YELLOW" "$NC" >&2
    _log_event WARN "Installation interrupted by signal"
    _cleanup_terminal
    exit 130
}
trap _cleanup_terminal EXIT
trap _on_interrupt INT TERM

# Guard against ever passing an empty / root / unexpected path to `rm -rf`.
# Marker mode is used for real uninstall/teardown paths; the "replace folder"
# path below intentionally stays marker-free because there is no launcher state.
_assert_safe_install_dir() {
    local d="$1" mode="${2:-}" low slash_count
    low="$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')"
    if [[ -z "$d" || "$d" == "/" || "$low" != *bugtraceai* ]]; then
        printf '%s\n' "FATAL: refusing to remove unsafe path: '${d:-<empty>}'" >&2
        exit 1
    fi
    slash_count="$(printf '%s' "$d" | tr -cd '/' | wc -c | tr -d ' ')"
    if [[ "$slash_count" -lt 2 ]]; then
        printf '%s\n' "FATAL: refusing to remove shallow path: '$d'" >&2
        exit 1
    fi
    if [[ "$mode" == "require_marker" && -d "$d" ]]; then
        if [[ ! -e "$d/.launcher-state" && ! -e "$d/launcher.sh" && ! -e "$d/mcp-config.json" ]]; then
            printf '%s\n' "FATAL: refusing to remove '$d': no BugTraceAI launcher marker found." >&2
            exit 1
        fi
    fi
}

# ── Logging ──────────────────────────────────────────────────────────────────

# Empty until _init_install_log (real runs only). Tests that source this file
# must not write a log unless BUGTRACEAI_INSTALL_LOG is set.
INSTALL_LOG_FILE=""

_log_event() {
    local level="$1"
    local msg="$2"
    local dest="${INSTALL_LOG_FILE:-${BUGTRACEAI_INSTALL_LOG:-}}"
    [[ -n "$dest" ]] || return 0
    [[ -n "${API_KEY:-}" ]] && msg="${msg//"$API_KEY"/[REDACTED]}"
    msg=$(printf '%s' "$msg" | tr '\n' ' ')
    printf '%s %s %s\n' "$(iso_date)" "$level" "$msg" >>"$dest" 2>/dev/null || true
}

_init_install_log() {
    local preferred_log="${BUGTRACEAI_INSTALL_LOG:-$SCRIPT_DIR/install.log}"
    local fallback_log="${XDG_STATE_HOME:-$HOME/.local/state}/bugtraceai-launcher/install.log"
    local dest

    for dest in "$preferred_log" "$fallback_log"; do
        [[ -n "$dest" ]] || continue
        mkdir -p -- "$(dirname -- "$dest")" >/dev/null 2>&1 || true
        if {
            printf '\n===== BugTraceAI Launcher v%s  %s  pid=%s =====\n' \
                "$VERSION" "$(iso_date)" "$$"
            printf 'host=%s user=%s\n' "$(hostname 2>/dev/null || echo unknown)" "${USER:-unknown}"
        } 2>/dev/null >>"$dest"; then
            INSTALL_LOG_FILE="$dest"
            return 0
        fi
    done

    # Logging must never prevent the visual installer from starting, including
    # when the launcher checkout and the user's state directory are read-only.
    INSTALL_LOG_FILE=""
}

info()    { echo -e "${BLUE}[INFO]${NC} $1"; _log_event INFO "$1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; _log_event OK "$1"; }
# WARN/ERROR go to stderr so they never pollute a function's stdout that a
# caller captures via $(...) — e.g. find_free_port feeding POSTGRES_PORT.
warn()    { echo -e "${YELLOW}[WARN]${NC} $1" >&2; _log_event WARN "$1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; _log_event ERROR "$1"; }
step()    { echo -e "  ${ARROW} $1"; _log_event STEP "$1"; }

read_web_version() {
    local version_file="$WEB_DIR/VERSION"
    local version=""

    if [[ -f "$version_file" ]]; then
        version=$(tr -d '[:space:]' < "$version_file" 2>/dev/null)
    elif [[ -f "$WEB_DIR/package.json" ]]; then
        version=$(awk -F'"' '/"version"/{print $4; exit}' "$WEB_DIR/package.json" 2>/dev/null)
    fi

    printf '%s' "${version%%-*}"
}

read_cli_version() {
    local version_file="$CLI_DIR/VERSION"
    local version=""

    if [[ -f "$version_file" ]]; then
        version=$(tr -d '[:space:]' < "$version_file" 2>/dev/null)
    elif [[ -f "$CLI_DIR/bugtrace/__init__.py" ]]; then
        version=$(awk -F'"' '/__version__/{print $2; exit}' "$CLI_DIR/bugtrace/__init__.py" 2>/dev/null)
    fi

    printf '%s' "${version%%-*}"
}

# ── Banner ───────────────────────────────────────────────────────────────────

show_banner() {
    [[ -t 1 ]] && clear
    echo -e "${CYAN}"
    cat << 'BANNER'

   ██████╗ ████████╗ █████╗ ██╗
   ██╔══██╗╚══██╔══╝██╔══██╗██║
   ██████╔╝   ██║   ███████║██║
   ██╔══██╗   ██║   ██╔══██║██║
   ██████╔╝   ██║   ██║  ██║██║
   ╚═════╝    ╚═╝   ╚═╝  ╚═╝╚═╝

BANNER
    echo -e "${NC}"
    echo -e "          ${BOLD}BugTraceAI Launcher v${VERSION}${NC}"
    echo -e "        Autonomous Web Security Scanner"
    echo ""
    if [[ -n "$INSTALL_LOG_FILE" ]]; then
        echo -e "        ${DIM}Install log: $INSTALL_LOG_FILE${NC}"
        echo ""
    fi
}

# ── Utility Functions ────────────────────────────────────────────────────────

port_available() {
    local port=$1
    # Check if port was already selected in THIS session
    [[ "$port" == "$WEB_PORT" ]] && return 1
    [[ "$port" == "$CLI_PORT" ]] && return 1
    [[ "$port" == "$BTAI_PORT" ]] && return 1
    [[ "$port" == "$BTAI_MCP_PORT" ]] && return 1
    [[ "$port" == "$MCP_PORT" ]] && return 1
    [[ "$port" == "$RECON_PORT" ]] && return 1

    if $IS_MACOS; then
        ! lsof -i ":$port" -sTCP:LISTEN &>/dev/null
    else
        # Fail CLOSED: if neither tool exists we cannot verify, so do not claim
        # the port is free (the old `! (a || b) | grep` returned "available" for
        # every port when both tools were missing, silently skipping the check).
        local listing
        if command -v ss >/dev/null 2>&1; then
            listing=$(ss -tuln 2>/dev/null)
        elif command -v netstat >/dev/null 2>&1; then
            listing=$(netstat -tuln 2>/dev/null)
        else
            warn "Cannot verify port $port (no ss/netstat); assuming busy."
            return 1
        fi
        ! grep -q ":$port " <<< "$listing"
    fi
}

# Resolve only the profiles served by the WEB compose file.  In Full mode the
# core BugTraceAI MCP belongs to the CLI compose project, so it must not also
# start the WEB-owned bugtrace-cli-mcp service.
resolve_web_mcp_profiles() {
    WEB_MCP_PROFILE_ARGS=()
    WEB_MCP_PROFILE_NAMES=()

    # The CLI Compose project owns the core BugTraceAI MCP whenever it is
    # selected, including WEB installs with optional MCPs. The public WEB
    # Compose has no guaranteed `cli` service, so do not start that profile.
    if $MCP_RECON_ENABLED; then
        WEB_MCP_PROFILE_ARGS+=(--profile recon)
        WEB_MCP_PROFILE_NAMES+=(recon)
    fi
    if $MCP_KALI_ENABLED; then
        WEB_MCP_PROFILE_ARGS+=(--profile kali)
        WEB_MCP_PROFILE_NAMES+=(kali)
    fi
}

find_free_port() {
    local port=$1
    local max=$((port + 100))
    while [[ $port -lt $max ]]; do
        if port_available "$port"; then
            echo "$port"
            return 0
        fi
        ((port++))
    done
    return 1
}

generate_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-24}"
}

# Portable lowercase (macOS ships Bash 3.2 which lacks ${var,,})
to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Portable ISO-8601 date (macOS date lacks -Iseconds)
iso_date() {
    if $IS_MACOS; then
        date -u '+%Y-%m-%dT%H:%M:%S+00:00'
    else
        date -Iseconds
    fi
}

# Portable sed -i (macOS sed requires '' after -i)
sed_inplace() {
    if $IS_MACOS; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

remove_empty_environment_headers() {
    local compose_file=$1
    local tmp_file
    tmp_file="$(mktemp)"

    awk '
    BEGIN { pending=0; env_line=""; buffered="" }
    pending {
        if ($0 ~ /^      /) {
            print env_line
            printf "%s", buffered
            pending=0
            env_line=""
            buffered=""
            print
            next
        }
        if ($0 ~ /^[[:space:]]*$/) {
            buffered=buffered $0 ORS
            next
        }
        pending=0
        env_line=""
        buffered=""
    }
    /^    environment:[[:space:]]*$/ {
        pending=1
        env_line=$0
        buffered=""
        next
    }
    { print }
    ' "$compose_file" > "$tmp_file" && mv "$tmp_file" "$compose_file"
}

ensure_recon_amd64_platform() {
    local compose_file=$1
    local tmp_file
    tmp_file="$(mktemp)"

    # six2dez/reconftw:main is amd64-only at the moment; force platform so ARM hosts
    # use emulation instead of failing manifest resolution.
    awk '
    BEGIN { in_recon=0; has_platform=0 }
    /^  reconftw-mcp:[[:space:]]*$/ { in_recon=1; print; next }
    # The WEB compose file ends the services mapping with a root-level key
    # (currently `volumes:`). Match that boundary too; otherwise injected
    # keys land inside the volumes mapping and invalidate YAML.
    in_recon && /^[^[:space:]]/ {
        if (!has_platform) print "    platform: linux/amd64"
        in_recon=0
    }
    in_recon && /^[[:space:]]+platform:[[:space:]]*linux\/amd64[[:space:]]*$/ { has_platform=1 }
    in_recon && /^  [^[:space:]]/ {
        if (!has_platform) print "    platform: linux/amd64"
        in_recon=0
    }
    { print }
    END {
        if (in_recon && !has_platform) print "    platform: linux/amd64"
    }' "$compose_file" > "$tmp_file"

    mv "$tmp_file" "$compose_file"
}

ensure_recon_health_timing() {
    local compose_file=$1
    local tmp_file
    tmp_file="$(mktemp)"

    awk '
    BEGIN { in_recon=0 }
    /^  reconftw-mcp:[[:space:]]*$/ { in_recon=1; print; next }
    in_recon && /^[^[:space:]]/ { in_recon=0 }
    in_recon && /^  [^[:space:]]/ { in_recon=0 }
    in_recon && /^[[:space:]]+retries:[[:space:]]*[0-9]+[[:space:]]*$/ { print "      retries: 10"; next }
    in_recon && /^[[:space:]]+start_period:[[:space:]]*[0-9]+s[[:space:]]*$/ { print "      start_period: 300s"; next }
    { print }
    ' "$compose_file" > "$tmp_file"

    mv "$tmp_file" "$compose_file"
}

ensure_recon_env_defaults() {
    local compose_file=$1
    local tmp_file
    tmp_file="$(mktemp)"

    awk '
    BEGIN { in_recon=0; count=0 }
    function emit_service(    i, has_auto, env_start, env_end, mapping) {
        has_auto=0; env_start=0; env_end=count+1; mapping=0
        for (i=1; i<=count; i++) {
            if (lines[i] !~ /^[[:space:]]*#/ && lines[i] ~ /RECONFTW_AUTO_INSTALL[=:]/) has_auto=1
            if (lines[i] ~ /^    environment:[[:space:]]*$/) env_start=i
        }
        if (env_start) {
            for (i=env_start+1; i<=count; i++) {
                if (lines[i] ~ /^    [^[:space:]]/) { env_end=i; break }
                if (lines[i] ~ /^      [^[:space:]#-]+:[[:space:]]/) mapping=1
            }
        }
        for (i=1; i<=count+1; i++) {
            if (!has_auto && i==env_end) {
                if (!env_start) print "    environment:"
                if (mapping) print "      RECONFTW_AUTO_INSTALL: \"false\""
                else print "      - RECONFTW_AUTO_INSTALL=false"
            }
            if (i<=count) print lines[i]
        }
        count=0
    }
    /^  reconftw-mcp:[[:space:]]*$/ { in_recon=1; lines[++count]=$0; next }
    in_recon && (/^  [^[:space:]]/ || /^[^[:space:]]/) {
        emit_service()
        in_recon=0
    }
    in_recon { lines[++count]=$0; next }
    { print }
    END { if (in_recon) emit_service() }
    ' "$compose_file" > "$tmp_file"

    mv "$tmp_file" "$compose_file"
}

# Public WEB compose ships recon as `image: reconftw-mcp:local` with no build.
# Compose then tries to pull that name from Docker Hub, fails, and aborts Kali
# in the same `up`. Point it at the sibling source the launcher already clones.
ensure_recon_local_build() {
    local compose_file=$1
    local tmp_file
    tmp_file="$(mktemp)"

    awk '
    BEGIN { in_recon=0; has_build=0; has_pull=0 }
    function emit_missing() {
        if (!has_build) {
            print "    build:"
            print "      context: ../reconftw-mcp"
            print "      dockerfile: Dockerfile"
        }
        if (!has_pull) print "    pull_policy: build"
    }
    /^  reconftw-mcp:[[:space:]]*$/ { in_recon=1; has_build=0; has_pull=0; print; next }
    in_recon && /^[[:space:]]+build:[[:space:]]*$/ { has_build=1 }
    in_recon && /^[[:space:]]+pull_policy:[[:space:]]*/ { has_pull=1 }
    in_recon && /^  [^[:space:]]/ {
        emit_missing()
        in_recon=0
    }
    in_recon && /^[^[:space:]]/ {
        emit_missing()
        in_recon=0
    }
    { print }
    END { if (in_recon) emit_missing() }
    ' "$compose_file" > "$tmp_file"

    mv "$tmp_file" "$compose_file"
}

ensure_kali_startup_command() {
    local compose_file=$1
    local tmp_file
    tmp_file="$(mktemp)"

    # Upstream has used both an inline command array and a folded YAML scalar.
    # Replace either form, then make retries explicit.  Kali is a toolbox
    # container, not an HTTP/SSE MCP endpoint, so it needs no host port.
    awk '
    function emit_command() {
        print "    command:"
        print "      - bash"
        print "      - -lc"
        print "      - |"
        print "        set -u"
        print "        export DEBIAN_FRONTEND=noninteractive"
        print "        echo '\''Preparing Kali toolbox...'\''"
        print "        for attempt in 1 2 3; do"
        print "          if apt-get update && apt-get install -y --no-install-recommends nmap ffuf sqlmap dirb gobuster nikto hydra john hashcat curl wget netcat-openbsd python3 python3-pip git vim; then"
        print "            break"
        print "          fi"
        # Emit an escaped Compose variable so the container, rather than
        # Compose, expands the retry counter at runtime.
        print "          if [ " sprintf("%c%c", 36, 36) "attempt -eq 3 ]; then"
        print "            echo '\''Failed to install required Kali tools.'\'' >&2"
        print "            exit 1"
        print "          fi"
        print "          echo '\''Package installation failed; retrying.'\'' >&2"
        print "          sleep 10"
        print "        done"
        print "        if ! command -v nuclei >/dev/null 2>&1; then"
        print "          apt-get install -y --no-install-recommends nuclei || echo '\''Warning: nuclei package unavailable; continuing without it.'\'' >&2"
        print "        fi"
        print "        if ! command -v nmap >/dev/null 2>&1 || ! command -v hydra >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then"
        print "          echo '\''Required Kali tools are unavailable.'\'' >&2"
        print "          exit 1"
        print "        fi"
        print "        echo '\''Kali toolbox ready!'\''"
        print "        exec tail -f /dev/null"
    }
    BEGIN { in_kali=0; skip_command=0; emitted=0 }
    /^  kali-mcp:[[:space:]]*$/ {
        in_kali=1
        skip_command=0
        emitted=0
        print
        next
    }
    in_kali && (/^  [^[:space:]]/ || /^[^[:space:]]/) {
        if (!emitted) emit_command()
        in_kali=0
        skip_command=0
        print
        next
    }
    in_kali && /^    command:[[:space:]]*/ {
        if (!emitted) emit_command()
        emitted=1
        # A command without an inline value (or a folded/literal scalar) owns
        # following indented lines.  Drop those old lines too.
        if ($0 ~ /^    command:[[:space:]]*$/ ||
            $0 ~ /^    command:[[:space:]]*[>|][+-]?[[:space:]]*$/) {
            skip_command=1
        }
        next
    }
    in_kali && skip_command {
        if (/^    [^[:space:]]/) {
            skip_command=0
            print
        }
        next
    }
    { print }
    END {
        if (in_kali && !emitted) emit_command()
    }
    ' "$compose_file" > "$tmp_file"

    mv "$tmp_file" "$compose_file"
}

patch_recon_entrypoint_startup() {
    local entrypoint="$RECON_DIR/entrypoint.sh"
    local tmp_file

    [[ -f "$entrypoint" ]] || return 0

    # Already patched.
    if grep -q "RECONFTW_AUTO_INSTALL" "$entrypoint"; then
        return 0
    fi

    tmp_file="$(mktemp)"
    awk '
    BEGIN { in_old_block=0 }
    /^# Check if reconftw\.sh exists$/ {
        in_old_block=1
        print "# Check if reconftw.sh exists"
        print "# Try to discover an existing install first to avoid expensive bootstrap on container start."
        print "if [ ! -f \"$RECONFTW_DIR/reconftw.sh\" ]; then"
        print "    FOUND_RECONFTW_SCRIPT=\"$(find /opt /root /usr /home -maxdepth 5 -type f -name reconftw.sh 2>/dev/null | head -n 1 || true)\""
        print "    if [ -n \"$FOUND_RECONFTW_SCRIPT\" ]; then"
        print "        RECONFTW_DIR=\"$(dirname \"$FOUND_RECONFTW_SCRIPT\")\""
        print "        log_info \"Detected existing reconftw at $RECONFTW_DIR\""
        print "    fi"
        print "fi"
        print ""
        print "if [ ! -f \"$RECONFTW_DIR/reconftw.sh\" ]; then"
        print "    log_warn \"reconftw.sh not found at $RECONFTW_DIR/reconftw.sh\""
        print "    log_info \"Attempting to clone reconftw repository...\""
        print ""
        print "    git clone --depth 1 https://github.com/six2dez/reconftw.git \"$RECONFTW_DIR\" 2>/dev/null || {"
        print "        log_error \"Failed to clone reconftw repository\""
        print "        exit 1"
        print "    }"
        print ""
        print "    cd \"$RECONFTW_DIR\""
        print "    chmod +x reconftw.sh"
        print ""
        print "    if [ \"${RECONFTW_AUTO_INSTALL:-false}\" = \"true\" ] && [ -f \"install.sh\" ]; then"
        print "        log_info \"Installing reconftw dependencies...\""
        print "        ./install.sh 2>/dev/null || log_warn \"Some dependencies may have failed to install\""
        print "    else"
        print "        log_warn \"Skipping reconftw install.sh bootstrap during startup (set RECONFTW_AUTO_INSTALL=true to enable).\""
        print "    fi"
        print "fi"
        next
    }
    in_old_block && /^# Make reconftw executable$/ {
        in_old_block=0
        print
        next
    }
    in_old_block { next }
    { print }
    ' "$entrypoint" > "$tmp_file"

    mv "$tmp_file" "$entrypoint"
    info "Applied reconftw-mcp startup bootstrap compatibility patch."
}

patch_recon_mcp_dependency() {
    local dockerfile="$RECON_DIR/Dockerfile"
    local requirements="$RECON_DIR/requirements.txt"
    local tmp_file
    local changed=false

    # reconFTW MCP currently imports the v1 FastMCP API.  The unbounded
    # dependency accepted mcp 2.x, which removed that import and left the
    # optional agent in a restart loop during the install health check.
    if [[ -f "$requirements" ]] && grep -Eq '^mcp\[cli\]>=1\.0\.0[[:space:]]*$' "$requirements"; then
        sed_inplace -E 's|^mcp\[cli\]>=1\.0\.0[[:space:]]*$|mcp[cli]>=1.0.0,<2|' "$requirements"
        changed=true
    fi

    if [[ -f "$dockerfile" ]] && grep -Eq '^[[:space:]]*mcp\[cli\]>=1\.0\.0[[:space:]]*\\[[:space:]]*$' "$dockerfile"; then
        tmp_file="$(mktemp)"
        awk '
        /^[[:space:]]*mcp\[cli\]>=1\.0\.0[[:space:]]*\\[[:space:]]*$/ {
            match($0, /^[[:space:]]*/)
            printf "%s\"mcp[cli]>=1.0.0,<2\" \\\n", substr($0, 1, RLENGTH)
            next
        }
        { print }
        ' "$dockerfile" > "$tmp_file" || {
            rm -f "$tmp_file"
            return 1
        }
        if grep -Fq '"mcp[cli]>=1.0.0,<2" \' "$tmp_file"; then
            mv "$tmp_file" "$dockerfile"
            changed=true
        else
            rm -f "$tmp_file"
        fi
    fi

    if $changed; then
        info "Pinned reconftw-mcp to the compatible MCP v1 dependency range."
    fi
}

patch_recon_dockerfile_venv() {
    local dockerfile="$RECON_DIR/Dockerfile"
    local host_arch
    local tmp_file

    [[ -f "$dockerfile" ]] || return 0

    host_arch="$(uname -m)"
    if [[ "$host_arch" == "arm64" || "$host_arch" == "aarch64" ]]; then
        if ! grep -q "^FROM --platform=linux/amd64 six2dez/reconftw:main" "$dockerfile"; then
            sed_inplace -E 's|^FROM[[:space:]]+six2dez/reconftw:main|FROM --platform=linux/amd64 six2dez/reconftw:main|' "$dockerfile"
            info "Applied reconftw-mcp amd64 base image pin for ARM hosts."
        fi
    fi

    patch_recon_mcp_dependency
    patch_recon_entrypoint_startup

    # Already patched or upstream fixed.
    if grep -q "python3 -m virtualenv /opt/mcp-venv" "$dockerfile"; then
        return 0
    fi

    if ! grep -q "RUN python3 -m venv /opt/mcp-venv" "$dockerfile"; then
        return 0
    fi

    tmp_file="$(mktemp)"
    awk '
    /RUN python3 -m venv \/opt\/mcp-venv/ {
        print "RUN python3 -m venv /opt/mcp-venv || \\"
        print "    ( (python3 -m pip install --no-cache-dir virtualenv || python3 -m pip install --no-cache-dir --break-system-packages virtualenv) && \\"
        print "      python3 -m virtualenv /opt/mcp-venv )"
        next
    }
    { print }
    ' "$dockerfile" > "$tmp_file"

    mv "$tmp_file" "$dockerfile"
    info "Applied reconftw-mcp Python venv compatibility patch."
}

# Restore only tracked recon files that exactly equal the output of our own
# compatibility patch pipeline. Other edits remain untouched and make pull
# fail safely if Git cannot merge them.
_restore_recon_patches_for_update() (
    local original_dir="$RECON_DIR" tmp rel changed=false
    [[ -d "$original_dir/.git" ]] || return 0
    tmp="$(mktemp -d)" || return 1
    for rel in Dockerfile requirements.txt entrypoint.sh; do
        if git -C "$original_dir" cat-file -e "HEAD:$rel" 2>/dev/null; then
            mkdir -p "$tmp/$(dirname "$rel")"
            git -C "$original_dir" show "HEAD:$rel" > "$tmp/$rel" || { rm -rf "$tmp"; return 1; }
        fi
    done
    RECON_DIR="$tmp"
    patch_recon_dockerfile_venv >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
    RECON_DIR="$original_dir"
    for rel in Dockerfile requirements.txt entrypoint.sh; do
        if ! git -C "$original_dir" diff HEAD --quiet -- "$rel"; then
            if [[ ! -f "$tmp/$rel" || ! -f "$original_dir/$rel" ]] || ! cmp -s "$tmp/$rel" "$original_dir/$rel"; then
                rm -rf "$tmp"
                error "Recon $rel has edits beyond the known launcher patch; preserving them and stopping update."
                return 1
            fi
            changed=true
        fi
    done
    if $changed; then
        for rel in Dockerfile requirements.txt entrypoint.sh; do
            if ! git -C "$original_dir" diff HEAD --quiet -- "$rel"; then
                git -C "$original_dir" show "HEAD:$rel" > "$original_dir/$rel" || { rm -rf "$tmp"; return 1; }
            fi
        done
    fi
    rm -rf "$tmp"
)

# The WEB compose project builds reconFTW from a sibling directory:
#   BugTraceAI-WEB/../reconftw-mcp
# A previous interrupted install could leave the launcher state behind while
# that directory was never cloned. Validate the actual build input before a
# compose command can turn that into Docker's opaque "path not found" error.
recon_source_ready() {
    [[ -f "$RECON_DIR/Dockerfile" ]] || return 1

    # Under the normal launcher layout these are the same directory. Checking
    # the relative path too makes a manually moved WEB directory fail with a
    # clear explanation instead of a later Compose build-context error.
    if [[ -d "$WEB_DIR" && ! -f "$WEB_DIR/../reconftw-mcp/Dockerfile" ]]; then
        return 1
    fi
}

# Restore only a completely missing reconFTW source tree. An existing but
# incomplete tree might contain a user's work, so it is deliberately never
# deleted or overwritten by start/update.
ensure_recon_source() {
    if recon_source_ready; then
        patch_recon_dockerfile_venv
        return 0
    fi

    if [[ -e "$RECON_DIR" || -L "$RECON_DIR" ]]; then
        error "reconFTW MCP build context is incomplete at: $RECON_DIR"
        error "Expected: $RECON_DIR/Dockerfile"
        error "Refusing to overwrite the existing directory. Restore or move it aside, then run: ./launcher.sh update"
        return 1
    fi

    step "Restoring missing reconftw-mcp source..."
    if ! git clone --depth 1 "$RECON_REPO" "$RECON_DIR"; then
        error "Failed to restore reconftw-mcp from $RECON_REPO"
        return 1
    fi

    if ! recon_source_ready; then
        error "reconftw-mcp was cloned, but its Dockerfile is missing. Cannot start the recon profile."
        return 1
    fi

    patch_recon_dockerfile_venv
    echo -e "    ${OK} reconftw-mcp restored"
}

ensure_macos_docker_path() {
    local found=false
    for p in "$HOME/.docker/bin" "/usr/local/bin" "/opt/homebrew/bin"; do
        if [[ -x "$p/docker" ]] && [[ ":$PATH:" != *":$p:"* ]]; then
            export PATH="$p:$PATH"
            found=true
        fi
    done
    $found && hash -r
}

detect_compose_cmd() {
    COMPOSE_CMD=""
    if docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null && docker-compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    fi
}

wait_for_docker_daemon() {
    local timeout=${1:-120}
    local elapsed=0
    local interval=3
    while [[ $elapsed -lt $timeout ]]; do
        if docker info &>/dev/null 2>&1; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 1
}

linux_docker_usable() {
    command -v docker &>/dev/null && docker info &>/dev/null 2>&1
}

linux_docker_daemon_up() {
    docker info &>/dev/null 2>&1 || sudo docker info &>/dev/null 2>&1
}

# How Linux Docker Engine would be installed. Prefer Docker's official script
# when curl exists; otherwise the distro package manager.
_linux_docker_install_method() {
    if command -v curl &>/dev/null; then
        printf '%s\n' "get.docker.com"
        return 0
    fi
    if command -v apt-get &>/dev/null; then
        printf '%s\n' "apt"
        return 0
    fi
    if command -v dnf &>/dev/null; then
        printf '%s\n' "dnf"
        return 0
    fi
    if command -v yum &>/dev/null; then
        printf '%s\n' "yum"
        return 0
    fi
    if command -v pacman &>/dev/null; then
        printf '%s\n' "pacman"
        return 0
    fi
    if command -v zypper &>/dev/null; then
        printf '%s\n' "zypper"
        return 0
    fi
    return 1
}

_install_linux_docker_packages() {
    local method
    method="$(_linux_docker_install_method)" || return 1
    case "$method" in
        get.docker.com)
            curl -fsSL https://get.docker.com | sudo sh
            ;;
        apt)
            sudo apt-get update -qq
            sudo apt-get install -y docker.io docker-compose-plugin
            ;;
        dnf)
            sudo dnf install -y docker docker-compose-plugin \
                || sudo dnf install -y moby-engine docker-compose
            ;;
        yum)
            sudo yum install -y docker docker-compose
            ;;
        pacman)
            sudo pacman -Syu --noconfirm docker docker-compose
            ;;
        zypper)
            sudo zypper install -y docker docker-compose
            ;;
        *)
            return 1
            ;;
    esac
}

_start_linux_docker_daemon() {
    if command -v systemctl &>/dev/null; then
        sudo systemctl enable --now docker 2>/dev/null || sudo systemctl start docker 2>/dev/null || true
    fi
    sudo service docker start 2>/dev/null || true
}

_wait_for_linux_docker_daemon() {
    local timeout=${1:-45}
    local elapsed=0
    local interval=3
    while [[ $elapsed -lt $timeout ]]; do
        if linux_docker_daemon_up; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 1
}

_save_wizard_selection_for_docker_reexec() {
    # `sg docker` starts a fresh shell process. Preserve the decisions already
    # made in the universal wizard so enabling Docker access cannot send the
    # user back through profile, extras, interface, or runtime questions.
    export BUGTRACEAI_DOCKER_RESUME_INSTALL=1
    export BUGTRACEAI_DOCKER_RESUME_PROFILE="${INSTALL_PROFILE:-}"
    export BUGTRACEAI_DOCKER_RESUME_MODE="${DEPLOY_MODE:-}"
    export BUGTRACEAI_DOCKER_RESUME_INSTALL_WEB="${INSTALL_WEB:-false}"
    export BUGTRACEAI_DOCKER_RESUME_INSTALL_CLI="${INSTALL_CLI:-false}"
    export BUGTRACEAI_DOCKER_RESUME_INSTALL_API="${INSTALL_BTAI:-false}"
    export BUGTRACEAI_DOCKER_RESUME_CLI_INTERFACE="${CLI_INTERFACE:-api}"
    export BUGTRACEAI_DOCKER_RESUME_CLI_RUNTIME="${CLI_RUNTIME:-docker}"
    export BUGTRACEAI_DOCKER_RESUME_CLI_GLOBAL="${CLI_GLOBAL:-no}"
    export BUGTRACEAI_DOCKER_RESUME_CLI_MANAGED="${CLI_MANAGED:-false}"
    export BUGTRACEAI_DOCKER_RESUME_MCP_CLI="${MCP_CLI_ENABLED:-false}"
    export BUGTRACEAI_DOCKER_RESUME_MCP_RECON="${MCP_RECON_ENABLED:-false}"
    export BUGTRACEAI_DOCKER_RESUME_MCP_KALI="${MCP_KALI_ENABLED:-false}"
}

_restore_wizard_selection_after_docker_reexec() {
    [[ "${BUGTRACEAI_DOCKER_RESUME_INSTALL:-}" == "1" ]] || return 1

    INSTALL_PROFILE="${BUGTRACEAI_DOCKER_RESUME_PROFILE:-}"
    DEPLOY_MODE="${BUGTRACEAI_DOCKER_RESUME_MODE:-}"
    INSTALL_WEB="${BUGTRACEAI_DOCKER_RESUME_INSTALL_WEB:-false}"
    INSTALL_CLI="${BUGTRACEAI_DOCKER_RESUME_INSTALL_CLI:-false}"
    INSTALL_BTAI="${BUGTRACEAI_DOCKER_RESUME_INSTALL_API:-false}"
    CLI_INTERFACE="${BUGTRACEAI_DOCKER_RESUME_CLI_INTERFACE:-api}"
    CLI_RUNTIME="${BUGTRACEAI_DOCKER_RESUME_CLI_RUNTIME:-docker}"
    CLI_GLOBAL="${BUGTRACEAI_DOCKER_RESUME_CLI_GLOBAL:-no}"
    CLI_MANAGED="${BUGTRACEAI_DOCKER_RESUME_CLI_MANAGED:-false}"
    MCP_CLI_ENABLED="${BUGTRACEAI_DOCKER_RESUME_MCP_CLI:-false}"
    MCP_RECON_ENABLED="${BUGTRACEAI_DOCKER_RESUME_MCP_RECON:-false}"
    MCP_KALI_ENABLED="${BUGTRACEAI_DOCKER_RESUME_MCP_KALI:-false}"

    unset BUGTRACEAI_DOCKER_RESUME_INSTALL BUGTRACEAI_DOCKER_RESUME_PROFILE \
        BUGTRACEAI_DOCKER_RESUME_MODE BUGTRACEAI_DOCKER_RESUME_INSTALL_WEB \
        BUGTRACEAI_DOCKER_RESUME_INSTALL_CLI BUGTRACEAI_DOCKER_RESUME_INSTALL_API \
        BUGTRACEAI_DOCKER_RESUME_CLI_INTERFACE BUGTRACEAI_DOCKER_RESUME_CLI_RUNTIME \
        BUGTRACEAI_DOCKER_RESUME_CLI_GLOBAL BUGTRACEAI_DOCKER_RESUME_CLI_MANAGED \
        BUGTRACEAI_DOCKER_RESUME_MCP_CLI BUGTRACEAI_DOCKER_RESUME_MCP_RECON \
        BUGTRACEAI_DOCKER_RESUME_MCP_KALI
    return 0
}

_reexec_in_docker_group() {
    [[ $EUID -eq 0 ]] && return 0
    sudo usermod -aG docker "$USER"
    # Only restart the launcher when this file is the running process. A sourced
    # caller (tests, AI installer) applies the group and continues.
    if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
        return 0
    fi
    if ! command -v sg &>/dev/null; then
        warn "Added $USER to the docker group. Run: newgrp docker"
        return 1
    fi
    info "Applying docker group, restarting launcher..."
    _save_wizard_selection_for_docker_reexec
    local reexec_cmd
    printf -v reexec_cmd '%q ' "$0" "${ORIG_ARGS[@]}"
    exec sg docker "$reexec_cmd"
}

# Install and/or start Docker Engine on Linux so the wizard can continue.
# Pass "yes" to skip the confirmation (the caller already asked).
ensure_linux_docker_engine() {
    local assume_yes="${1:-}"

    if linux_docker_usable; then
        return 0
    fi

    if ! command -v docker &>/dev/null; then
        echo ""
        warn "Docker Engine is not installed."
        echo -e "  ${DIM}The launcher can install it with Docker's official installer (get.docker.com).${NC}"
        if [[ "$assume_yes" != "yes" ]]; then
            echo -en "${YELLOW}Install Docker Engine now? [Y/n]: ${NC}"
            read -r confirm
            if [[ "$(to_lower "${confirm:-}")" == "n" ]]; then
                return 1
            fi
        fi
        info "Installing Docker Engine..."
        if ! _install_linux_docker_packages; then
            error "Failed to install Docker Engine."
            echo -e "  ${DIM}Manual install: https://docs.docker.com/engine/install/${NC}"
            return 1
        fi
        echo -e "  ${OK} Docker Engine installed"
    fi

    if linux_docker_usable; then
        detect_compose_cmd
        return 0
    fi

    if ! linux_docker_daemon_up; then
        info "Starting Docker daemon..."
        _start_linux_docker_daemon
        if ! _wait_for_linux_docker_daemon 45; then
            error "Docker daemon did not become ready."
            echo -e "  ${DIM}Start it with: sudo systemctl start docker${NC}"
            return 1
        fi
    fi

    if linux_docker_usable; then
        detect_compose_cmd
        return 0
    fi

    if sudo docker info &>/dev/null 2>&1; then
        _reexec_in_docker_group || return 1
        if linux_docker_usable; then
            detect_compose_cmd
            return 0
        fi
        warn "Added $USER to the docker group. Docker commands may need sudo until you log in again."
        detect_compose_cmd
        return 0
    fi

    error "Docker Engine is not ready."
    return 1
}

ensure_homebrew() {
    if command -v brew &>/dev/null; then
        return 0
    fi

    warn "Homebrew is required for automated macOS dependency installation."
    echo -en "${YELLOW}Install Homebrew now? [Y/n]: ${NC}"
    read -r confirm
    if [[ "$(to_lower "${confirm:-}")" == "n" ]]; then
        return 1
    fi

    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1

    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi

    command -v brew &>/dev/null
}

ensure_macos_brew_packages() {
    local formulas=("$@")
    local missing=()
    local formula
    for formula in "${formulas[@]}"; do
        if ! brew list --formula "$formula" &>/dev/null; then
            missing+=("$formula")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    info "Installing Homebrew packages: ${missing[*]}"
    brew install "${missing[@]}" || {
        error "Failed to install Homebrew packages: ${missing[*]}"
        return 1
    }
}

colima_profile_arch() {
    colima list 2>/dev/null | awk 'NR==2{print $3}'
}

maybe_fix_colima_arch() {
    # On Apple Silicon, running an x86_64 Colima VM causes image arch mismatches.
    if [[ "$(uname -m)" != "arm64" ]]; then
        return 0
    fi

    local arch
    arch="$(colima_profile_arch)"
    if [[ "$arch" != "x86_64" ]]; then
        return 0
    fi

    warn "Detected Colima profile arch=x86_64 on Apple Silicon."
    warn "This can fail with container image format errors."
    echo -en "${YELLOW}Recreate Colima as arm64 (aarch64)? [Y/n]: ${NC}"
    read -r confirm
    if [[ "$(to_lower "${confirm:-}")" == "n" ]]; then
        warn "Continuing with x86_64 Colima profile (may fail for some images)."
        return 0
    fi

    info "Recreating Colima profile with arm64 architecture..."
    colima stop >/dev/null 2>&1 || true
    colima delete -f >/dev/null 2>&1 || true
}

ensure_docker_desktop_runtime() {
    ensure_macos_docker_path

    if docker info &>/dev/null 2>&1; then
        return 0
    fi

    if [[ ! -d "/Applications/Docker.app" ]]; then
        if ! ensure_homebrew; then
            error "Homebrew is required to install Docker Desktop automatically."
            return 1
        fi
        info "Installing Docker Desktop..."
        if ! brew install --cask docker; then
            error "Failed to install Docker Desktop via Homebrew."
            return 1
        fi
    fi

    info "Starting Docker Desktop..."
    open -a Docker || true

    if wait_for_docker_daemon 150; then
        ensure_macos_docker_path
        return 0
    fi

    error "Docker Desktop did not become ready in time."
    return 1
}

ensure_colima_runtime() {
    ensure_macos_docker_path

    if ! ensure_homebrew; then
        error "Homebrew is required for Colima setup."
        return 1
    fi

    if ! ensure_macos_brew_packages docker docker-compose colima qemu lima-additional-guestagents; then
        error "Failed to install required packages for Colima."
        return 1
    fi
    ensure_macos_docker_path
    maybe_fix_colima_arch

    if docker info &>/dev/null 2>&1; then
        return 0
    fi

    info "Starting Colima (Docker runtime)..."
    local start_cmd=(colima start --runtime docker)
    if [[ "$(uname -m)" == "arm64" ]]; then
        start_cmd+=(--arch aarch64)
    fi
    local start_output
    start_output=$("${start_cmd[@]}" 2>&1) || {
        if echo "$start_output" | grep -qi "guest agent"; then
            warn "Missing Lima guest agents detected. Installing helper package and retrying..."
            ensure_macos_brew_packages lima-additional-guestagents || true
            "${start_cmd[@]}" >/dev/null 2>&1 || {
                error "Colima failed to start."
                echo "$start_output" >&2
                return 1
            }
        else
            error "Colima failed to start."
            echo "$start_output" >&2
            return 1
        fi
    }

    if wait_for_docker_daemon 90; then
        detect_compose_cmd
        return 0
    fi

    error "Docker daemon did not become ready after Colima start."
    return 1
}

ensure_macos_runtime_ready() {
    ensure_macos_docker_path
    detect_compose_cmd

    if docker info &>/dev/null 2>&1; then
        return 0
    fi

    echo ""
    select_option "Docker daemon is down. Select runtime for macOS setup:" \
        "Colima (Docker Desktop-free, recommended for OSS stack)" \
        "Docker Desktop"

    case $MENU_SELECTION in
        0) ensure_colima_runtime ;;
        1) ensure_docker_desktop_runtime ;;
        *) return 1 ;;
    esac
}

# Propose port with max 3 attempts. Exits if none accepted.
# Usage: propose_port "Label" default_port RESULT_VAR
propose_port() {
    local label=$1 default=$2 result_var=$3
    local attempts=0
    local port

    port=$(find_free_port "$default") || port=$default

    while [[ $attempts -lt 3 ]]; do
        echo ""
        echo -e "  ${BOLD}$label${NC}: ${CYAN}$port${NC}"
        echo -en "  ${YELLOW}Accept? [Y] / n=next / or type a port: ${NC}"
        read -r answer

        case "$(to_lower "$answer")" in
            ""|y|yes)
                printf -v "$result_var" '%s' "$port"
                return 0
                ;;
            n|no)
                ((attempts++))
                port=$(find_free_port $((port + 1))) || {
                    error "No free ports found"
                    exit 1
                }
                ;;
            *)
                if [[ "$answer" =~ ^[0-9]+$ ]] && [[ "$answer" -ge 1024 ]] && [[ "$answer" -le 65535 ]]; then
                    if port_available "$answer"; then
                        printf -v "$result_var" '%s' "$answer"
                        return 0
                    else
                        warn "Port $answer is already in use"
                        ((attempts++))
                    fi
                else
                    warn "Invalid port number (must be 1024-65535)"
                    ((attempts++))
                fi
                ;;
        esac
    done

    error "Could not configure port for $label after 3 attempts."
    exit 1
}

# Numbered selection menu. Sets MENU_SELECTION to chosen index.
select_option() {
    local question=$1
    shift
    local options=("$@")
    local total=${#options[@]}

    echo -e "\n${YELLOW}$question${NC}\n"
    for i in "${!options[@]}"; do
        echo -e "  ${CYAN}$((i + 1)))${NC} ${options[$i]}"
    done
    echo ""

    while true; do
        echo -en "${YELLOW}Choice [1-$total]: ${NC}"
        if ! read -r choice; then
            error "Input closed (EOF) before a selection was made. Run from an interactive terminal."
            exit 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$total" ]]; then
            MENU_SELECTION=$((choice - 1))
            return 0
        fi
        error "Please enter a number between 1 and $total"
    done
}

# MCP Descriptions for multi-select menu
MCP_DESCRIPTIONS=(
    "BugTraceAI Scanner: Core vulnerability scanning engine with AI-powered analysis"
    "reconFTW: Automated subdomain enumeration, OSINT gathering, and vulnerability detection"
    "Kali Linux toolbox: Full penetration testing toolkit (nmap, nuclei, sqlmap, ffuf, etc.) - 3GB+ download"
)

# Multi-select menu with SPACE to toggle, ENTER to confirm
# Returns SELECTED_INDICES array with indices of selected options
# Numbered multi-select menu. Returns SELECTED_INDICES array.
select_multi() {
    local question=$1
    shift
    local -a options=("$@")
    local total=${#options[@]}
    local -a selected=()

    # Initialize all as unselected (false)
    for i in "${!options[@]}"; do
        selected[$i]=false
    done

    # Apply pre-selections from optional global PRE_SELECTED array. The
    # ${PRE_SELECTED[@]+...} guard keeps this safe even when PRE_SELECTED is
    # undeclared (and under a future `set -u`).
    for idx in ${PRE_SELECTED[@]+"${PRE_SELECTED[@]}"}; do
        if [[ $idx -ge 0 && $idx -lt $total ]]; then
            selected[$idx]=true
        fi
    done

    while true; do
        echo -e "\n${YELLOW}$question${NC}\n"
        for i in "${!options[@]}"; do
            local mark="◯"
            ${selected[$i]} && mark="◉"
            echo -e "  ${CYAN}$((i + 1)))${NC} [${mark}] ${options[$i]}"
        done
        echo ""
        echo -e "  ${DIM}Enter numbers to toggle selections (e.g., '1 3'), or press ENTER to confirm current setup.${NC}"
        echo -en "${YELLOW}Selection: ${NC}"
        read -r choices

        if [[ -z "$choices" ]]; then
            break
        fi

        for num in $choices; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [[ "$num" -ge 1 ]] && [[ "$num" -le "$total" ]]; then
                local idx=$((num - 1))
                if ${selected[$idx]}; then
                    selected[$idx]=false
                else
                    selected[$idx]=true
                fi
            else
                warn "Ignoring invalid choice: $num"
            fi
        done
    done

    SELECTED_INDICES=()
    for i in "${!selected[@]}"; do
        ${selected[$i]} && SELECTED_INDICES+=($i)
    done
}

# ── Version Check ──────────────────────────────────────────────────────────

# Compare two semver strings. Returns 0 (true) if $2 > $1.
_is_semver_like() {
    local version="${1#v}"
    local version_pattern='^[0-9]+([.][0-9]+){0,3}([-+][0-9A-Za-z.-]+)?$'
    [[ "$version" =~ $version_pattern ]]
}

_version_is_newer() {
    local current="$1" latest="$2"
    [[ -z "$current" || -z "$latest" ]] && return 1
    _is_semver_like "$current" && _is_semver_like "$latest" || return 1
    # Strip leading 'v' and any pre-release suffix (-beta, -alpha, -rc.N)
    current="${current#v}"; current="${current%%-*}"
    latest="${latest#v}";   latest="${latest%%-*}"
    [[ "$current" == "$latest" ]] && return 1
    local higher
    higher=$(printf '%s\n%s' "$current" "$latest" | sort -V | tail -1)
    [[ "$higher" == "$latest" ]]
}

# Fetch latest version for a repo from GitHub Releases API (cached).
# Uses one cache file per repo: $VERSION_CACHE.<repo-name>
# Each file contains: <unix_timestamp> <version>
# Usage: _get_latest_version "BugTraceAI-CLI" → prints version or empty
_get_latest_version() {
    local repo="$1" now cached_time cached_ver cache_file

    cache_file="${VERSION_CACHE}.${repo}"
    now=$(date +%s)

    # Read cache if it exists
    if [[ -f "$cache_file" ]]; then
        cached_time=$(awk '{print $1}' "$cache_file" 2>/dev/null)
        cached_ver=$(awk '{print $2}' "$cache_file" 2>/dev/null)

        if ! _is_semver_like "$cached_ver"; then
            cached_ver=""
        elif [[ -n "$cached_time" ]] && (( now - cached_time < VERSION_CACHE_TTL )); then
            echo "$cached_ver"
            return
        fi
    fi

    # Fetch from GitHub (5s timeout, silent fail)
    local tag
    tag=$(curl -sf --max-time 5 \
        -H "User-Agent: BugTraceAI-Launcher/${VERSION}" \
        "${GITHUB_API_BASE}/${repo}/releases/latest" 2>/dev/null \
        | awk -F'"' '/"tag_name"/{print $4}')

    if [[ -n "$tag" ]]; then
        local clean="${tag#v}"
        if _is_semver_like "$clean"; then
            mkdir -p "$(dirname "$cache_file")" 2>/dev/null
            echo "$now $clean" > "$cache_file" 2>/dev/null
            echo "$clean"
            return
        fi
    fi

    # Return a valid cached value even if expired (better than nothing)
    echo "${cached_ver:-}"
}

_install_dir_is_cache_only() {
    [[ -d "$INSTALL_DIR" ]] || return 1

    local entry
    entry=$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 ! -name '.version_cache*' -print -quit 2>/dev/null)
    [[ -z "$entry" ]]
}

cleanup_legacy_version_cache_dir() {
    [[ -f "$STATE_FILE" ]] && return 0
    _install_dir_is_cache_only || return 0

    rm -f "$INSTALL_DIR"/.version_cache* 2>/dev/null || true
    rmdir "$INSTALL_DIR" 2>/dev/null || true
}

# Check all repos for updates and display a summary banner.
# Silent on network failure. Skips if curl is not available.
format_release_preview() {
    python3 -c 'import json,sys; p=json.load(sys.stdin); [print("%s: %s -> %s (%s)" % (c["component"].upper(), c["current"], c["target"], p["release"])) for c in p["components"] if c["current"] != c["target"]]'
}

check_for_updates() {
    command -v curl &>/dev/null || return 0

    local has_update=false
    local lines=()
    local recon_note=""

    # Check Launcher version
    local latest_launcher
    latest_launcher=$(_get_latest_version "$REPOS_LAUNCHER")
    if _version_is_newer "$VERSION" "$latest_launcher"; then
        has_update=true
        lines+=("     Launcher: ${VERSION} → ${latest_launcher}")
    fi

    # Components are updated as one compatible cohort, including beta tags.
    if [[ -f "$STATE_FILE" ]] && command -v python3 >/dev/null; then
        local release_preview
        release_preview=$(python3 "$SCRIPT_DIR/release_manager.py" preview --install-dir "$INSTALL_DIR" --json 2>/dev/null || true)
        if [[ -n "$release_preview" ]]; then
            local component_line
            while IFS= read -r component_line; do
                [[ -z "$component_line" ]] && continue
                has_update=true
                lines+=("     $component_line")
            done < <(printf '%s' "$release_preview" | format_release_preview)
        fi
    fi

    # Check Recon version. reconftw-mcp has no parseable local version, so we
    # cannot compare installed-vs-latest. Rather than flag an "update available"
    # on every run (alert fatigue), only surface the latest release as an
    # informational note and never gate the action banner on it.
    if [[ -d "$RECON_DIR" ]]; then
        local latest_recon
        latest_recon=$(_get_latest_version "$REPOS_RECON")
        if [[ -n "$latest_recon" ]]; then
            recon_note="     Recon:    latest release ${latest_recon} (managed separately; preserved during core updates)"
        fi
    fi

    # Display banner if any real version update was detected
    if $has_update; then
        echo ""
        echo -e "  ${YELLOW}⚡ Updates available:${NC}"
        for line in "${lines[@]}"; do
            echo -e "  ${YELLOW}${line}${NC}"
        done
        [[ -n "$recon_note" ]] && echo -e "  ${DIM}${recon_note}${NC}"
        echo -e "  ${DIM}Run: ./launcher.sh update${NC}"
        echo ""
    elif [[ -n "$recon_note" ]]; then
        # No version update, but note the recon release informationally only.
        echo ""
        echo -e "  ${DIM}${recon_note}${NC}"
        echo ""
    fi
}

# ── Pre-flight Checks ───────────────────────────────────────────────────────

# On macOS, Docker Desktop may not be in PATH by default
if $IS_MACOS; then
    ensure_macos_docker_path
fi
detect_compose_cmd

check_deps() {
    info "Checking requirements..."
    echo ""
    local ok=true

    if $IS_MACOS; then
        ensure_macos_docker_path
        if ! docker info &>/dev/null 2>&1; then
            if ! ensure_macos_runtime_ready; then
                ok=false
            fi
        fi
    fi

    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        echo -e "  ${OK} Docker $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
    elif ! $IS_MACOS && ensure_linux_docker_engine; then
        echo -e "  ${OK} Docker $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
    else
        echo -e "  ${FAIL} Docker not found or not running"
        ok=false
    fi

    detect_compose_cmd
    if [[ -n "$COMPOSE_CMD" ]]; then
        version=$($COMPOSE_CMD version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        echo -e "  ${OK} Docker Compose $version"
    else
        if $IS_MACOS; then
            if ensure_homebrew && ensure_macos_brew_packages docker-compose; then
                detect_compose_cmd
            fi
        fi

        if [[ -n "$COMPOSE_CMD" ]]; then
            version=$($COMPOSE_CMD version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
            echo -e "  ${OK} Docker Compose $version"
        elif ! $IS_MACOS; then
            # Try auto-installing Docker Compose v2 plugin
            echo -e "  ${YELLOW}⚠${NC}  Docker Compose not found — attempting auto-install..."
            local compose_installed=false

            # Method 1: apt package (works if Docker's official repo is configured)
            if command -v apt-get &>/dev/null; then
                install_output=$(sudo apt-get install -y docker-compose-plugin 2>&1)
                if [[ $? -eq 0 ]] && docker compose version &>/dev/null; then
                    compose_installed=true
                else
                    echo -e "       ${DIM}apt package not available, trying direct download...${NC}"
                fi
            fi

            # Method 2: Download binary from GitHub (universal fallback)
            if ! $compose_installed; then
                local arch
                arch=$(uname -m)
                case "$arch" in
                    x86_64)  arch="x86_64" ;;
                    aarch64) arch="aarch64" ;;
                    armv7l)  arch="armv7" ;;
                    *) arch="" ;;
                esac

                if [[ -n "$arch" ]]; then
                    local plugin_dir="/usr/local/lib/docker/cli-plugins"
                    local plugin_path="$plugin_dir/docker-compose"
                    local download_url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}"

                    echo -e "       ${DIM}Downloading from github.com/docker/compose...${NC}"
                    if sudo mkdir -p "$plugin_dir" && \
                       sudo curl -fsSL "$download_url" -o "$plugin_path" && \
                       sudo chmod +x "$plugin_path" && \
                       docker compose version &>/dev/null; then
                        compose_installed=true
                    else
                        sudo rm -f "$plugin_path" 2>/dev/null
                    fi
                fi
            fi

            if $compose_installed; then
                COMPOSE_CMD="docker compose"
                version=$($COMPOSE_CMD version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
                echo -e "  ${OK} Docker Compose $version (auto-installed)"
            else
                echo -e "  ${FAIL} Failed to install Docker Compose"
                echo -e "       ${DIM}Manual install: https://docs.docker.com/compose/install/linux/${NC}"
                ok=false
            fi
        else
            echo -e "  ${FAIL} Docker Compose not found"
            echo -e "       ${DIM}Install via Homebrew: brew install docker-compose${NC}"
            ok=false
        fi
    fi

    if command -v git &>/dev/null; then
        echo -e "  ${OK} Git $(git --version | awk '{print $3}')"
    else
        echo -e "  ${FAIL} Git not found"
        ok=false
    fi

    if command -v curl &>/dev/null; then
        echo -e "  ${OK} curl"
    else
        echo -e "  ${FAIL} curl not found"
        ok=false
    fi

    local total_ram
    if $IS_MACOS; then
        total_ram=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
    else
        total_ram=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")
    fi
    if [[ "$total_ram" -ge 4096 ]]; then
        echo -e "  ${OK} RAM: ${total_ram}MB"
    else
        echo -e "  ${YELLOW}⚠${NC}  RAM: ${total_ram}MB (4GB+ recommended)"
    fi

    local disk
    if $IS_MACOS; then
        disk=$(df -g / 2>/dev/null | awk 'NR==2{print $4}' || echo "0")
    else
        disk=$(df -BG / 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4}' || echo "0")
    fi
    if [[ "$disk" -ge 10 ]]; then
        echo -e "  ${OK} Disk: ${disk}GB free"
    else
        echo -e "  ${YELLOW}⚠${NC}  Disk: ${disk}GB free (10GB+ recommended)"
    fi

    echo ""

    if [[ "$ok" == false ]]; then
        error "Missing required dependencies."
        [[ -n "$INSTALL_LOG_FILE" ]] && echo -e "  ${DIM}Install log: $INSTALL_LOG_FILE${NC}"
        echo ""
        if $IS_MACOS; then
            echo -e "  Install Docker Desktop: ${CYAN}https://docs.docker.com/desktop/install/mac-install/${NC}"
            echo -e "  Install Git & curl:     ${DIM}xcode-select --install${NC}  or  ${DIM}brew install git curl${NC}"
        else
            echo -e "  Install Docker:          ${CYAN}https://docs.docker.com/engine/install/${NC}"
            echo -e "  Install Docker Compose:  ${DIM}sudo apt install docker-compose-plugin${NC}"
            echo -e "  Install Git & curl:      ${DIM}sudo apt install git curl${NC}"
        fi
        exit 1
    fi

    success "All checks passed"
    echo ""
}

# ── Wizard ───────────────────────────────────────────────────────────────────

ai_installer_available() {
    command -v python3 >/dev/null 2>&1 && [[ -f "$SCRIPT_DIR/ai_installer.py" ]]
}

launch_ai_installer() {
    if ! command -v python3 >/dev/null 2>&1; then
        error "Python3 is required for the AI Setup & Repair Assistant."
        exit 1
    fi

    if [[ ! -f "$SCRIPT_DIR/ai_installer.py" ]]; then
        error "AI Setup & Repair Assistant not found: $SCRIPT_DIR/ai_installer.py"
        exit 1
    fi

    chmod +x "$SCRIPT_DIR/ai_installer.py"
    info "Starting AI Setup & Repair Assistant (DeepSeek V4.1 Flash · Qwen 3.8 Max fallback)..."
    exec python3 "$SCRIPT_DIR/ai_installer.py"
}

offer_installer_mode() {
    if [[ "${BUGTRACEAI_SKIP_AI_PROMPT:-}" == "1" ]] || ! ai_installer_available; then
        return 0
    fi

    select_option "Choose how to proceed:" \
        "Standard guided installer (manual choices)" \
        "AI Setup & Repair Assistant (Experimental — installs & troubleshoots)"

    if [[ $MENU_SELECTION -eq 1 ]]; then
        launch_ai_installer
    fi
}

# The interactive entry point uses an isolated, version-pinned Textual runtime.
# Direct profile commands and the classic fallback keep working without it.
python_venv_usable() {
    local python_bin="$1" probe_dir status=1
    command -v "$python_bin" >/dev/null 2>&1 || return 1
    probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/bugtraceai-venv-check.XXXXXX")" || return 1
    if "$python_bin" -m venv "$probe_dir/env" >/dev/null 2>&1 && \
       "$probe_dir/env/bin/python" -m pip --version >/dev/null 2>&1; then
        status=0
    fi
    rm -rf -- "$probe_dir"
    return "$status"
}

ensure_launcher_tui_python() {
    local candidate=""
    local candidates=(python3.12 python3.11 python3.10 python3)
    if [[ -n "${BUGTRACEAI_LAUNCHER_TUI_PYTHON:-}" ]]; then
        candidates=("$BUGTRACEAI_LAUNCHER_TUI_PYTHON")
    fi
    for candidate in "${candidates[@]}"; do
        if command -v "$candidate" >/dev/null 2>&1 && \
           "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
            LAUNCHER_TUI_SYSTEM_PYTHON="$(command -v "$candidate")"
            break
        fi
    done

    if [[ -z "${LAUNCHER_TUI_SYSTEM_PYTHON:-}" ]]; then
        info "Python 3.10+ is required for the visual Launcher; installing it with the system package manager..."
        if $IS_MACOS; then
            local brew_bin
            brew_bin="$(ensure_homebrew)" || return 1
            "$brew_bin" install python || return 1
            LAUNCHER_TUI_SYSTEM_PYTHON="$("$brew_bin" --prefix python 2>/dev/null)/bin/python3"
        elif command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update -qq && sudo apt-get install -y python3 python3-venv || return 1
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y python3 || return 1
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y python3 || return 1
        elif command -v pacman >/dev/null 2>&1; then
            sudo pacman -Syu --noconfirm python || return 1
        elif command -v zypper >/dev/null 2>&1; then
            sudo zypper install -y python3 python3-venv || return 1
        else
            error "Install Python 3.10+ and rerun, or set BUGTRACEAI_CLASSIC=1 for the text wizard."
            return 1
        fi
        for candidate in "${candidates[@]}"; do
            if command -v "$candidate" >/dev/null 2>&1 && \
               "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
                LAUNCHER_TUI_SYSTEM_PYTHON="$(command -v "$candidate")"
                break
            fi
        done
    fi
    if [[ -z "${LAUNCHER_TUI_SYSTEM_PYTHON:-}" ]] || \
       ! "$LAUNCHER_TUI_SYSTEM_PYTHON" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
        error "Python 3.10+ is still unavailable."; return 1
    fi

    if ! python_venv_usable "$LAUNCHER_TUI_SYSTEM_PYTHON"; then
        info "Installing Python venv support for the visual Launcher..."
        if $IS_MACOS; then
            local brew_bin
            brew_bin="$(ensure_homebrew)" || return 1
            "$brew_bin" install python || return 1
        elif command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update -qq && sudo apt-get install -y python3-venv || return 1
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y python3 || return 1
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y python3 || return 1
        elif command -v pacman >/dev/null 2>&1; then
            sudo pacman -Syu --noconfirm python || return 1
        elif command -v zypper >/dev/null 2>&1; then
            sudo zypper install -y python3 python3-venv || return 1
        fi
    fi
    python_venv_usable "$LAUNCHER_TUI_SYSTEM_PYTHON" || {
        error "Python still cannot create a pip-ready virtual environment. Install your OS package for python3-venv."
        return 1
    }
}

launcher_tui_python() {
    local cache_root="${BUGTRACEAI_LAUNCHER_TUI_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/bugtraceai-launcher}"
    local venv="${BUGTRACEAI_LAUNCHER_TUI_VENV:-$cache_root/tui-venv}"
    local requirements="$SCRIPT_DIR/launcher-requirements.txt"
    local requirements_stamp="$venv/launcher-requirements.txt"

    ensure_launcher_tui_python || return 1
    mkdir -p "$(dirname "$venv")" || return 1
    if [[ ! -x "$venv/bin/python" ]] || ! "$venv/bin/python" -m pip --version >/dev/null 2>&1; then
        if [[ -e "$venv" ]]; then
            local incomplete_venv
            incomplete_venv="$(mktemp -d "${venv}.incomplete.XXXXXX")" || return 1
            rmdir "$incomplete_venv" || return 1
            mv "$venv" "$incomplete_venv" || return 1
            warn "Moved an incomplete Launcher TUI environment to $incomplete_venv."
        fi
        info "Preparing the isolated Launcher TUI runtime..."
        "$LAUNCHER_TUI_SYSTEM_PYTHON" -m venv "$venv" || return 1
    fi
    if ! cmp -s "$requirements" "$requirements_stamp" || \
       ! "$venv/bin/python" -m pip check >/dev/null 2>&1; then
        info "Installing the pinned Textual dependency in the user cache..."
        "$venv/bin/python" -m pip install --disable-pip-version-check --quiet --requirement "$requirements" || return 1
        cp "$requirements" "$requirements_stamp" || return 1
    fi
    "$venv/bin/python" - <<'PY' || return 1
from importlib.metadata import version
expected = {
    "textual": "8.2.8", "rich": "15.0.0", "markdown-it-py": "3.0.0",
    "mdit-py-plugins": "0.6.1", "platformdirs": "4.5.1", "pygments": "2.21.0",
    "typing-extensions": "4.15.0", "linkify-it-py": "2.2.0", "mdurl": "0.1.2",
}
for package, pinned in expected.items():
    if version(package) != pinned:
        raise SystemExit(f"{package} version does not match the Launcher pin")
PY
    "$venv/bin/python" -m pip check >/dev/null || return 1
    LAUNCHER_TUI_PYTHON="$venv/bin/python"
}

wizard_cli_preferences() {
    if [[ -n "$INSTALL_PROFILE" ]]; then
        if [[ "$DEPLOY_MODE" == cli ]]; then
            if [[ -n "$REQUESTED_RUNTIME" ]]; then
                CLI_RUNTIME="$REQUESTED_RUNTIME"
            else
                info "Your interfaces are selected. Now choose how to run them."
                select_option "How should BugTraceAI be installed and run?" \
                    "Local Python (.venv) - dependencies on this machine" \
                    "Docker - dependencies in containers; TUI uses your terminal"
                case $MENU_SELECTION in 0) CLI_RUNTIME=local ;; 1) CLI_RUNTIME=docker ;; esac
            fi
            CLI_MANAGED=true
        else
            [[ "$REQUESTED_RUNTIME" != local ]] || { error "WEB and API-target profiles currently require Docker."; return 1; }
            CLI_RUNTIME=docker
            info "This profile runs in Docker; the launcher connects its services."
        fi
    elif [[ "$DEPLOY_MODE" == cli ]]; then
        select_option "How will you use BugTraceAI CLI?" "Interactive terminal (TUI)" "API server + MCP" "Both TUI and API"
        case $MENU_SELECTION in 0) CLI_INTERFACE=tui ;; 1) CLI_INTERFACE=api ;; 2) CLI_INTERFACE=both ;; esac
        select_option "Where should the CLI run?" "Local Python environment" "Docker"
        case $MENU_SELECTION in 0) CLI_RUNTIME=local ;; 1) CLI_RUNTIME=docker ;; esac
        CLI_MANAGED=true
        MCP_CLI_ENABLED=false
        [[ "$CLI_INTERFACE" == tui ]] || MCP_CLI_ENABLED=true
    elif $INSTALL_CLI || $MCP_CLI_ENABLED; then
        select_option "WEB needs the CLI API. Include the terminal workspace too?" "API server + MCP" "Both API and TUI"
        if [[ $MENU_SELECTION -eq 1 ]]; then CLI_INTERFACE=both; else CLI_INTERFACE=api; fi
        CLI_RUNTIME=docker
    fi
    CLI_GLOBAL=no
    if [[ -n "$REQUESTED_GLOBAL" ]]; then
        [[ "$REQUESTED_GLOBAL" != yes || "$CLI_INTERFACE" != api ]] || { error "Global btai requires a terminal workspace."; return 1; }
        CLI_GLOBAL="$REQUESTED_GLOBAL"
    elif [[ "$CLI_INTERFACE" != api ]]; then
        select_option "Install global btai to open the TUI from any folder?" "Yes (current user, no sudo)" "No"
        [[ $MENU_SELECTION -ne 0 ]] || CLI_GLOBAL=yes
    fi
}

# New components expose an explicit backend; older releases accept flags in install.sh.
cli_runtime_installer() {
    if [[ -f "$CLI_DIR/scripts/install-runtime.sh" ]]; then
        printf '%s' "$CLI_DIR/scripts/install-runtime.sh"
    else
        printf '%s' "$CLI_DIR/install.sh"
    fi
}

# The launcher owns all user-facing choices and calls the leaf backend directly.
run_cli_installer() {
    local args=("$@") installer
    installer=$(cli_runtime_installer)
    [[ -f "$installer" ]] || { error "CLI runtime backend is missing: $installer"; return 1; }
    if grep -q -- '--launch' "$installer"; then args+=(--launch no); fi
    (cd "$CLI_DIR" && bash "$installer" "${args[@]}")
}

offer_workspace_launch() {
    [[ "${BUGTRACEAI_LAUNCHER_SKIP_POST_INSTALL:-}" == "1" ]] && return 0
    [[ "$CLI_INTERFACE" != api && -t 0 && -t 1 ]] || return 0
    local answer
    read -r -p "Open the terminal workspace now? [Y/n]: " answer || return 0
    case "$answer" in ''|y|Y|yes|YES)
        cmd_tui || warn "The workspace could not open. Installation is saved; retry ./launcher.sh tui."
        ;;
    esac
}

deploy_cli_only() {
    mkdir -p "$INSTALL_DIR" || return 1
    local workspace="${BUGTRACEAI_CLI_PATH:-${CLI_SETUP_CHECKOUT:-}}"
    if [[ -z "$workspace" && -f "$SCRIPT_DIR/../BugTraceAI-CLI-refactor/install.sh" ]]; then
        workspace="$SCRIPT_DIR/../BugTraceAI-CLI-refactor"
    fi
    if [[ -n "$workspace" ]]; then
        CLI_DIR="$(cd "$workspace" && pwd)" || return 1
    else
        clone_repos || return 1
    fi
    if ! grep -q -- '--interface' "$(cli_runtime_installer)" || ! grep -q -- '--global' "$(cli_runtime_installer)"; then
        error "This checkout needs the CLI 4.0.14+ installer. Select the private refactor with BUGTRACEAI_CLI_REPO / BUGTRACEAI_CLI_BRANCH."
        return 1
    fi
    # Finish the engine installation before optional user command registration.
    run_cli_installer --interface "$CLI_INTERFACE" --runtime "$CLI_RUNTIME" --global no || return 1
    INSTALL_CLI=true INSTALL_WEB=false INSTALL_BTAI=false
    DEPLOY_MODE=cli CLI_MANAGED=true
    if [[ "$CLI_RUNTIME" == docker && "$CLI_INTERFACE" != tui ]]; then
        CLI_PORT=$(awk -F= '$1=="CLI_PORT" {print $2}' "$CLI_DIR/.env")
        MCP_PORT=$(awk -F= '$1=="MCP_PORT" {print $2}' "$CLI_DIR/.env")
    fi
    save_state
    if [[ "$CLI_GLOBAL" == yes ]]; then
        run_cli_installer --interface "$CLI_INTERFACE" --runtime "$CLI_RUNTIME" --global yes --global-only || return 1
    fi
    success "CLI installed: $CLI_INTERFACE / $CLI_RUNTIME"
    [[ "$CLI_INTERFACE" == api ]] || info "Terminal: ./launcher.sh tui"
    [[ "$CLI_INTERFACE" == tui ]] || info "Server: ./launcher.sh api"
    offer_workspace_launch
}

apply_install_profile() {
    local requested="$1" key label description mode interface web cli api
    while IFS='|' read -r key label description mode interface web cli api; do
        [[ "$key" == "$requested" ]] || continue
        INSTALL_PROFILE="$key" DEPLOY_MODE="$mode" CLI_INTERFACE="$interface"
        INSTALL_WEB="$web" INSTALL_CLI="$cli" INSTALL_BTAI="$api"
        MCP_CLI_ENABLED=false
        [[ "$interface" == tui || "$cli" != true ]] || MCP_CLI_ENABLED=true
        MCP_RECON_ENABLED=false MCP_KALI_ENABLED=false CLI_MANAGED=false CLI_GLOBAL=no
        return 0
    done < "$SCRIPT_DIR/installation-profiles.tsv"
    error "Unknown installation profile: $requested"
    return 1
}

show_selected_components() {
    echo ""
    echo -e "${BOLD}Selected setup: ${INSTALL_PROFILE:-$DEPLOY_MODE}${NC}"
    $INSTALL_WEB && info "WEB dashboard and database"
    if $INSTALL_CLI; then
        [[ "$CLI_INTERFACE" == api ]] || info "Terminal workspace (TUI)"
        [[ "$CLI_INTERFACE" == tui ]] || info "Web-scanning backend (CLI API + MCP)"
    fi
    $INSTALL_BTAI && info "API-target scanning backend (BugTraceAI-API REST + MCP)"
    $MCP_RECON_ENABLED && info "reconFTW MCP"
    $MCP_KALI_ENABLED && info "Kali Linux toolbox"
    info "Runtime: $CLI_RUNTIME"
    [[ "$CLI_INTERFACE" == api ]] || info "Global btai: $CLI_GLOBAL"
    return 0
}

wizard_select_components() {
    INSTALL_WEB=false
    INSTALL_CLI=false
    INSTALL_BTAI=false
    MCP_CLI_ENABLED=false
    MCP_RECON_ENABLED=false
    MCP_KALI_ENABLED=false

    if [[ -z "$INSTALL_PROFILE" ]]; then
        local key label description mode interface web cli api
        local keys=() options=()
        if [[ -n "${BUGTRACEAI_LAUNCHER_INITIAL_PROFILE:-}" ]]; then
            info "Suggested profile: $BUGTRACEAI_LAUNCHER_INITIAL_PROFILE. Review the choices below."
        fi
        while IFS='|' read -r key label description mode interface web cli api; do
            keys+=("$key")
            options+=("$label\n     $description")
        done < "$SCRIPT_DIR/installation-profiles.tsv"
        options+=("Cancel")
        select_option "What do you want to use? The launcher installs all required components." "${options[@]}"
        [[ $MENU_SELECTION -lt ${#keys[@]} ]] || return 2
        INSTALL_PROFILE="${keys[$MENU_SELECTION]}"
    fi
    apply_install_profile "$INSTALL_PROFILE" || return 1

    if [[ "${BUGTRACEAI_MCP_SELECTION_PRESET:-}" == "1" ]]; then
        MCP_RECON_ENABLED="${BUGTRACEAI_MCP_RECON:-false}"
        MCP_KALI_ENABLED="${BUGTRACEAI_MCP_KALI:-false}"
        if ! $INSTALL_WEB && { $MCP_RECON_ENABLED || $MCP_KALI_ENABLED; }; then
            error "reconFTW and Kali add-ons require the WEB profile."
            return 1
        fi
        return 0
    fi

    # Step 2: Select Extras (only for Web+CLI or Solo WEB)
    if $INSTALL_WEB; then
        select_option "Would you like to add chat MCPs or the Kali toolbox?" \
            "Add Full Pack (reconFTW MCP + Kali toolbox)" \
            "Add Kali Linux toolbox (Full Pentest Toolkit - 3GB+)" \
            "Add reconFTW MCP (OSINT & Subdomains by @six2dez)" \
            "NONE (Only BugTraceAI core components)"
        
        case $MENU_SELECTION in
            0) # BOTH
                MCP_KALI_ENABLED=true
                MCP_RECON_ENABLED=true
                ;;
            1) # Kali
                MCP_KALI_ENABLED=true
                ;;
            2) # Recon
                MCP_RECON_ENABLED=true
                ;;
            3) # None
                ;;
        esac
        
        # If any specialized MCP is enabled, we ensure the core CLI agent is also there
        if $MCP_RECON_ENABLED || $MCP_KALI_ENABLED; then
            MCP_CLI_ENABLED=true
        fi
    fi

    return 0
}

wizard_select_provider() {
    select_option "Which LLM provider would you like to use?" \
        "OpenRouter — Multi-model access (Recommended)" \
        "Z.ai — GLM models (Chinese provider)" \
        "Anthropic — Claude direct API (x-api-key, sk-ant-...)"

    case $MENU_SELECTION in
        0) LLM_PROVIDER="openrouter" ;;
        1) LLM_PROVIDER="zai" ;;
        2) LLM_PROVIDER="anthropic" ;;
    esac

    echo ""
    success "Provider: $LLM_PROVIDER"
    echo ""
}

wizard_ask_api_key() {
    local key_label key_url key_prefix key_env_var key_min_len

    if [[ "$LLM_PROVIDER" == "zai" ]]; then
        key_label="Z.ai (GLM)"
        key_url="https://open.bigmodel.cn/usercenter/apikeys"
        key_prefix=""
        key_env_var="GLM_API_KEY"
        key_min_len=20
    elif [[ "$LLM_PROVIDER" == "anthropic" ]]; then
        key_label="Anthropic"
        key_url="https://console.anthropic.com/settings/keys"
        key_prefix="sk-ant-"
        key_env_var="ANTHROPIC_API_KEY"
        key_min_len=40
    else
        key_label="OpenRouter"
        key_url="https://openrouter.ai/keys"
        key_prefix="sk-or-"
        key_env_var="OPENROUTER_API_KEY"
        key_min_len=32
    fi

    echo -e "  ${DIM}BugTraceAI uses ${key_label} for AI-powered analysis.${NC}"
    echo -e "  ${DIM}Get your API key at: ${CYAN}${key_url}${NC}"
    echo -e "  ${DIM}You can configure the key later; press ENTER to continue without it.${NC}"
    echo ""

    while true; do
        echo -en "  ${YELLOW}${key_label} API key: ${NC}"
        if ! read -rs API_KEY; then
            echo ""
            error "Input closed (EOF) while reading API key. Run from an interactive terminal."
            exit 1
        fi
        echo ""

        if [[ -z "$API_KEY" ]]; then
            API_KEY_ENV_VAR=""
            info "Provider key skipped. Configure it before running AI-powered scans."
            return 0
        fi

        if (( ${#API_KEY} < key_min_len )); then
            error "${key_label} API key appears too short (minimum ${key_min_len} characters)"
            continue
        fi

        # Show masked key with last 4 chars for confirmation
        local key_len=${#API_KEY}
        if [[ $key_len -ge 8 ]]; then
            echo -e "  ${DIM}Key ends with: ...${API_KEY: -4}  (${key_len} characters)${NC}"
        else
            echo -e "  ${DIM}Key: ${API_KEY:0:2}...${API_KEY: -2}  (${key_len} characters)${NC}"
        fi

        echo -en "  ${YELLOW}Does this look correct? [Y/n]: ${NC}"
        if ! read -r confirm; then
            error "Input closed (EOF) while confirming API key. Run from an interactive terminal."
            exit 1
        fi
        if [[ "$(to_lower "$confirm")" == "n" ]]; then
            info "Let's try again..."
            continue
        fi

        # Provider-specific prefix validation
        if [[ -n "$key_prefix" && ! "$API_KEY" =~ ^${key_prefix} ]]; then
            warn "Key doesn't look like a ${key_label} key (expected ${key_prefix}...)"
            echo -en "  ${YELLOW}Continue anyway? [y/N]: ${NC}"
            read -r confirm
            [[ "$(to_lower "$confirm")" != "y" ]] && continue
        fi

        API_KEY_ENV_VAR="$key_env_var"
        break
    done

    success "API key configured"
    echo ""
}


wizard_configure_ports() {
    echo -e "${BOLD}Port Configuration${NC}"

    if $INSTALL_WEB; then
        propose_port "WEB frontend port" 6869 WEB_PORT
    fi

    if $INSTALL_CLI || $MCP_CLI_ENABLED; then
        propose_port "CLI API port" 8000 CLI_PORT
    fi

    if $INSTALL_BTAI; then
        propose_port "BugTraceAI-API REST port" 8005 BTAI_PORT
        propose_port "BugTraceAI-API MCP port" 8004 BTAI_MCP_PORT
    fi

    # MCP ports based on selection
    if $MCP_CLI_ENABLED; then
        propose_port "BugTraceAI MCP port" 8001 MCP_PORT
    fi

    if $MCP_RECON_ENABLED; then
        propose_port "reconFTW MCP port" 8002 RECON_PORT
    fi

    echo ""
    success "Ports configured"
    echo ""
}

wizard_show_summary() {
    echo ""
    echo -e "${BOLD}─── Configuration Summary ───${NC}"
    echo ""
    echo -e "  Profile:    ${CYAN}${INSTALL_PROFILE:-$DEPLOY_MODE}${NC}"
    echo -e "  Provider:   ${CYAN}$LLM_PROVIDER${NC}"

    # Show endpoints based on mode and selections
    if [[ -n "$WEB_PORT" ]]; then
        echo -e "  WEB:        ${CYAN}http://localhost:$WEB_PORT${NC}"
    fi
    if [[ -n "$CLI_PORT" ]]; then
        echo -e "  CLI API:    ${CYAN}http://localhost:$CLI_PORT${NC}"
    fi
    if [[ -n "$BTAI_PORT" ]]; then
        echo -e "  BugTraceAI-API REST: ${CYAN}http://localhost:$BTAI_PORT${NC}"
    fi

    # Show MCP agents
    local has_mcp_endpoints=false
    $INSTALL_BTAI && [[ -n "$BTAI_MCP_PORT" ]] && has_mcp_endpoints=true
    $MCP_CLI_ENABLED && has_mcp_endpoints=true
    $MCP_RECON_ENABLED && has_mcp_endpoints=true

    if $has_mcp_endpoints; then
        echo ""
        echo -e "  ${BOLD}MCP endpoints:${NC}"
        $INSTALL_BTAI && [[ -n "$BTAI_MCP_PORT" ]] && echo -e "    ${OK} BugTraceAI-API: ${CYAN}http://localhost:${BTAI_MCP_PORT}/mcp${NC}"
        $MCP_CLI_ENABLED && echo -e "    ${OK} BugTraceAI: ${CYAN}http://localhost:${MCP_PORT}/sse${NC}"
        $MCP_RECON_ENABLED && echo -e "    ${OK} reconFTW:   ${CYAN}http://localhost:${RECON_PORT}/sse${NC}"
    fi
    if $MCP_KALI_ENABLED; then
        echo -e "    ${OK} Kali toolbox: ${CYAN}docker exec -it kali-mcp-server bash${NC}"
    fi

    if [[ -n "$API_KEY_ENV_VAR" && -n "$API_KEY" ]]; then
        echo -e "  API Key:    ${DIM}...${API_KEY: -4} (${API_KEY_ENV_VAR})${NC}"
    else
        echo -e "  API Key:    ${DIM}not configured (can be added later)${NC}"
    fi
    echo -e "  Install at: ${DIM}$INSTALL_DIR${NC}"
    echo ""
    echo -e "${BOLD}─────────────────────────────${NC}"
    echo ""

    echo -en "${YELLOW}Proceed with installation? [Y/n]: ${NC}"
    read -r confirm
    if [[ "$(to_lower "$confirm")" == "n" ]]; then
        warn "Installation cancelled."
        exit 0
    fi
    echo ""
}

selected_docker_conflicts() {
    local cli_docker=false names cname include
    [[ "${INSTALL_CLI:-false}" == true && "${CLI_RUNTIME:-}" == docker ]] && cli_docker=true
    { $cli_docker || [[ "${INSTALL_WEB:-false}" == true || "${INSTALL_BTAI:-false}" == true || \
        "${MCP_KALI_ENABLED:-false}" == true || "${MCP_RECON_ENABLED:-false}" == true ]]; } || return 0
    command -v docker >/dev/null 2>&1 || return 0

    names=$(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
    while IFS= read -r cname; do
        [[ -n "$cname" ]] || continue
        include=false
        case "$cname" in
            bugtrace_api|bugtrace_mcp|bugtrace-mcp|bugtrace-cli-mcp)
                $cli_docker && include=true ;;
            bugtrace-api)
                [[ "${INSTALL_BTAI:-false}" == true ]] && include=true ;;
            bugtraceai-web-frontend|bugtraceai-web-backend|bugtraceai-web-db|bugtraceai-api-routes)
                [[ "${INSTALL_WEB:-false}" == true ]] && include=true ;;
            kali-mcp-server)
                [[ "${MCP_KALI_ENABLED:-false}" == true ]] && include=true ;;
            reconftw-mcp)
                [[ "${MCP_RECON_ENABLED:-false}" == true ]] && include=true ;;
        esac
        $include && printf '%s\n' "$cname"
    done <<< "$names"
}

prompt_docker_conflicts() {
    local existing_btai cname cstatus
    existing_btai=$(selected_docker_conflicts)
    [[ -n "$existing_btai" ]] || return 0

    echo ""
    warn "Containers for the selected Docker components already exist:"
    while IFS= read -r cname; do
        [[ -n "$cname" ]] || continue
        cstatus=$(docker ps -a --format '{{.Status}}' --filter "name=^${cname}$" 2>/dev/null | head -1)
        echo -e "    ${CYAN}•${NC} ${cname}  ${DIM}(${cstatus})${NC}"
    done <<< "$existing_btai"
    echo ""
    select_option "How should the selected components handle these containers?" \
        "Remove these containers and keep their data volumes" \
        "Keep them and continue (installation may hit name conflicts)" \
        "Cancel"

    case $MENU_SELECTION in
        0)
            echo "$existing_btai" | xargs -r docker rm -f 2>/dev/null || return 1
            success "Selected containers removed. Data volumes were preserved."
            ;;
        1)
            warn "Existing containers were left untouched; setup may stop if Docker reports a name conflict."
            ;;
        2)
            info "Installation cancelled. Existing containers and volumes were kept."
            return 1
            ;;
    esac
    echo ""
}

run_wizard() {
    local resume_after_docker_reexec=false

    # Restore stdin if piped (e.g. curl | bash)
    if [ ! -t 0 ] && [ -t 2 ] && [ -c /dev/tty ]; then
        # Reconnect only stdin. Redirecting fd 2 here permanently hid Git,
        # Docker, and launcher errors after curl | bash entered the wizard.
        exec </dev/tty || true
    fi

    if _restore_wizard_selection_after_docker_reexec; then
        resume_after_docker_reexec=true
    fi

    if ! $resume_after_docker_reexec && [[ -z "$INSTALL_PROFILE" && -t 0 && -t 1 && \
          "${BUGTRACEAI_LAUNCHER_TUI_CHILD:-}" != "1" && "${BUGTRACEAI_CLASSIC:-}" != "1" ]]; then
        if launcher_tui_python; then
            # Once Textual starts, propagate its exit status. In particular, a
            # failed install must return to the caller instead of opening the
            # classic wizard and accidentally offering a second installation.
            "$LAUNCHER_TUI_PYTHON" "$SCRIPT_DIR/launcher_tui.py" --launcher "$SCRIPT_DIR/launcher.sh"
            return $?
        else
            warn "The visual Launcher could not start; continuing with the compatible text wizard."
        fi
    fi

    show_banner
    if $resume_after_docker_reexec; then
        info "Resuming the selected installation after enabling Docker access."
    else
        [[ -n "$INSTALL_PROFILE" ]] || offer_installer_mode
        cleanup_legacy_version_cache_dir

        # Detect existing installation
        if [[ -f "$STATE_FILE" ]]; then
            warn "BugTraceAI is already installed at $INSTALL_DIR"
            echo ""
            select_option "What would you like to do?" \
                "Reinstall (wipe and start fresh)" \
                "Update (apply tested release versions)" \
                "Cancel"

            case $MENU_SELECTION in
                0)
                    info "Removing existing installation..."
                    _teardown_all
                    ;;
                1)
                    cmd_update
                    exit 0
                    ;;
                2)
                    info "Cancelled."
                    exit 0
                    ;;
            esac
            echo ""
        elif [[ -d "$INSTALL_DIR" ]]; then
            warn "Directory $INSTALL_DIR already exists (no previous launcher state found)."
            echo ""
            select_option "What would you like to do?" \
                "Replace (remove folder and install fresh)" \
                "Cancel"

            case $MENU_SELECTION in
                0)
                    info "Removing $INSTALL_DIR..."
                    _assert_safe_install_dir "$INSTALL_DIR"
                    rm -rf "$INSTALL_DIR"
                    ;;
                1)
                    info "Cancelled."
                    exit 0
                    ;;
            esac
            echo ""
        fi

        check_for_updates
        local selection_status
        wizard_select_components
        selection_status=$?
        [[ $selection_status -ne 2 ]] || { info "Cancelled."; return 0; }
        [[ $selection_status -eq 0 ]] || return "$selection_status"
        wizard_cli_preferences || return 1
        prompt_docker_conflicts || return 1
    fi

    show_selected_components
    if [[ "$DEPLOY_MODE" == cli ]]; then
        deploy_cli_only
        return $?
    fi
    check_docker install
    check_deps
    wizard_select_provider
    wizard_ask_api_key
    wizard_configure_ports
    wizard_show_summary
    deploy
}

# ── Deployment ───────────────────────────────────────────────────────────────

deploy() {
    info "Starting deployment..."
    echo ""

    step "Creating $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"
    # A reinstall can remove the directory from which the launcher was
    # invoked.  Re-enter the newly-created target before running Git so every
    # clone has a valid working directory and the deployment can continue to
    # WEB, CLI, API, and optional agents.
    if ! cd "$INSTALL_DIR"; then
        error "Cannot enter installation directory: $INSTALL_DIR"
        exit 1
    fi

    clone_repos || return 1
    if [[ "$CLI_INTERFACE" != api ]]; then _require_tui_cli_version "$CLI_DIR" || return 1; fi
    if [[ "$CLI_GLOBAL" == yes ]] && ! grep -q -- '--global-only' "$(cli_runtime_installer)"; then
        error "The selected CLI checkout does not support global btai. Use CLI 4.0.14+ via BUGTRACEAI_CLI_REPO / BUGTRACEAI_CLI_BRANCH."
        return 1
    fi
    if ! generate_env; then
        error "Deployment stopped because configuration generation failed."
        return 1
    fi
    if ! patch_compose; then
        error "Deployment stopped because Compose configuration patching failed."
        return 1
    fi
    if ! start_services; then
        error "Deployment stopped because one or more selected services failed to start."
        return 1
    fi
    if ! health_checks; then
        error "Deployment stopped because one or more selected services failed health checks."
        return 1
    fi
    save_state
    if [[ "$CLI_GLOBAL" == yes ]]; then
        run_cli_installer --interface "$CLI_INTERFACE" --runtime docker --global yes --global-only || return 1
    fi
    show_success
    offer_workspace_launch
}

clone_repos() {
    local components=()
    $INSTALL_WEB && components+=(web)
    { $INSTALL_CLI || $MCP_CLI_ENABLED; } && components+=(cli)
    $INSTALL_BTAI && components+=(api)
    local development_cli=false
    [[ -z "$CLI_BRANCH" && "$CLI_REPO" == 'https://github.com/BugTraceAI/BugTraceAI-CLI.git' ]] || development_cli=true
    local pinned_components=() component
    for component in "${components[@]}"; do
        [[ "$component" != cli ]] || ! $development_cli || continue
        pinned_components+=("$component")
    done
    if (( ${#pinned_components[@]} > 0 )); then
        # Resolve every selected release tag before creating any product checkout.
        python3 "$SCRIPT_DIR/release_manager.py" available --components "${pinned_components[@]}" || return 1
    fi
    for component in "${components[@]}"; do
        case "$component" in
            cli)
                if $development_cli; then
                    info 'Explicit CLI development source selected; release pinning is bypassed for this checkout.'
                    if [[ -e "$CLI_DIR" ]]; then
                        error 'A development checkout already exists. Update it directly; existing files were kept.'
                        return 1
                    fi
                    local args=(--depth 1)
                    [[ -z "$CLI_BRANCH" ]] || args+=(--branch "$CLI_BRANCH" --single-branch)
                    git clone "${args[@]}" "$CLI_REPO" "$CLI_DIR" || return 1
                else
                    python3 "$SCRIPT_DIR/release_manager.py" checkout --component cli --checkout "$CLI_DIR" || return 1
                fi ;;
            web) python3 "$SCRIPT_DIR/release_manager.py" checkout --component web --checkout "$WEB_DIR" || return 1 ;;
            api) python3 "$SCRIPT_DIR/release_manager.py" checkout --component api --checkout "$BTAI_DIR" || return 1 ;;
        esac
        echo -e "    ${OK} ${component} release source ready"
    done
    if ! $development_cli; then RELEASE_PINNED=true; fi

    # Clone Recon repo if needed
    if [[ "$DEPLOY_MODE" == "recon" || "$DEPLOY_MODE" == "custom" ]] || $MCP_RECON_ENABLED; then
        if [[ -d "$RECON_DIR/.git" ]]; then
            step "Updating reconftw-mcp..."
            if ! (cd "$RECON_DIR" && git pull --quiet) 2>/dev/null; then
                warn "Failed to update Recon repo (will use existing version)"
            fi
        else
            step "Cloning reconftw-mcp..."
            if [[ -e "$RECON_DIR" ]]; then
                error "An incomplete reconftw-mcp directory already exists. Preserve or repair it before retrying; it was not removed."
                return 1
            fi
            if ! git clone --depth 1 "$RECON_REPO" "$RECON_DIR"; then
                error "Failed to clone reconftw-mcp from $RECON_REPO"
                exit 1
            fi
        fi
        if ! ensure_recon_source; then
            exit 1
        fi
        echo -e "    ${OK} reconftw-mcp"
    fi
}

# API Compose reads both listener and host ports from the generated .env.
# No source-file patch is needed, which keeps update/rebuild idempotent.
patch_btai_compose() {
    [[ -f "$BTAI_DIR/docker-compose.yml" ]] || return 0
}

# Point the freshly-cloned CLI at the selected provider by rewriting the ACTIVE
# line within [PROVIDER] in bugtraceaicli.conf. The CLI reads PROVIDER from .env but
# then OVERRIDES it with this conf value at load time; the conf is baked into the
# image by `docker compose up --build` (COPY . .), so this host-side patch — run
# BEFORE the build, exactly like patch_compose — is what actually selects the
# provider inside the container. Idempotent + section-scoped. Also fixes a
# non-OpenRouter choice (e.g. Z.ai) that would otherwise deploy as the shipped
# openrouter-v2 default and then fail for a missing OPENROUTER_API_KEY.
set_cli_provider_active() {
    local conf="$CLI_DIR/bugtraceaicli.conf"
    local active
    case "$LLM_PROVIDER" in
        openrouter) active="openrouter-v2" ;;
        zai)        active="zai" ;;
        anthropic)  active="anthropic" ;;
        *)          active="openrouter-v2" ;;
    esac
    [[ -f "$conf" ]] || return 0
    if grep -q '^\[PROVIDER\]' "$conf"; then
        sed_inplace "/^\[PROVIDER\]/,/^\[/ s/^ACTIVE *=.*/ACTIVE = ${active}/" "$conf"
    else
        printf '\n[PROVIDER]\nACTIVE = %s\n' "$active" >> "$conf"
    fi
}

generate_env() {
    step "Generating configuration..."

    # Only persist provider credentials supplied by the user. This avoids
    # malformed empty `=` assignments in fresh API/CLI environment files.
    local provider_key_assignment=""
    if [[ -n "$API_KEY_ENV_VAR" && -n "$API_KEY" ]]; then
        provider_key_assignment="${API_KEY_ENV_VAR}=${API_KEY}"
    fi

    # WEB configuration
    if $INSTALL_WEB; then
        if [[ -n "$WEB_PORT" ]]; then
            # Universal access: use /cli-api for relative calls which works for both Local and VM/Remote.
            local cli_url="/cli-api"
            # The current WEB Compose contract requires a numeric CLI_API_PORT
            # even when WEB+API was selected without a local CLI. In that mode
            # it is only a placeholder for the lazy optional proxy; no CLI
            # container or host port is published.
            local cli_api_port="$CLI_PORT"
            [[ -n "$cli_api_port" ]] || cli_api_port=8000

            # Host port for PostgreSQL: default 5432, auto-bumped on conflict.
            # The backend reaches postgres over the docker network (postgres:5432);
            # this only affects the host-side mapping, so bumping is always safe.
            local pg_port
            pg_port=$(find_free_port 5432)
            # Validate it's actually numeric (defensive: never write garbage to .env)
            [[ "$pg_port" =~ ^[0-9]+$ ]] || pg_port=5432

            # umask 077 in a subshell so the secret-bearing file is created 0600
            # from the start (no world-readable window), then chmod as belt-and-braces.
            ( umask 077
              cat > "$WEB_DIR/.env.docker" << EOF
# BugTraceAI-WEB — Generated by Launcher v${VERSION} ($(iso_date))
POSTGRES_USER=bugtraceai
POSTGRES_PASSWORD=$(generate_password 24)
POSTGRES_DB=bugtraceai_web
POSTGRES_PORT=${pg_port}
FRONTEND_PORT=${WEB_PORT}
VITE_CLI_API_URL=${cli_url}
CLI_API_PORT=${cli_api_port}
VITE_BTAI_API_URL=/btai-api
BTAI_API_PORT=${BTAI_PORT}
BTAI_SHARED_NETWORK=${BTAI_SHARED_NETWORK}
EOF
            )

            # Add only endpoint variables for WEB-owned MCP services.  Profiles
            # are passed as explicit Docker Compose flags later; persisting
            # COMPOSE_PROFILES would silently start optional services too early.
            local web_mcp_env_needed=false
            $MCP_RECON_ENABLED && web_mcp_env_needed=true
            if $MCP_CLI_ENABLED && ! $INSTALL_CLI; then
                web_mcp_env_needed=true
            fi
            if $web_mcp_env_needed; then
                {
                    printf '\n# MCP Endpoint Configuration\n'
                    if $MCP_RECON_ENABLED && [[ -n "$RECON_PORT" ]]; then
                        printf 'RECON_MCP_PORT=%s\n' "$RECON_PORT"
                    fi
                    if $MCP_CLI_ENABLED && ! $INSTALL_CLI && [[ -n "$MCP_PORT" ]]; then
                        printf 'CLI_MCP_PORT=%s\n' "$MCP_PORT"
                    fi
                } >> "$WEB_DIR/.env.docker"
            fi

            chmod 600 "$WEB_DIR/.env.docker" 2>/dev/null || true
            echo -e "    ${OK} WEB config (.env.docker, mode 600)"
        fi
    fi

    # BugTraceAI-API configuration.  Provider credentials stay in this
    # deployment-local file (0600) and are never written into WEB or CLI files.
    if $INSTALL_BTAI; then
        patch_btai_compose
        ( umask 077
          cat > "$BTAI_DIR/.env" << EOF
# BugTraceAI-API — Generated by Launcher v${VERSION} ($(iso_date))
APEX_PROVIDER=${LLM_PROVIDER}
MCP_PORT=${BTAI_MCP_PORT}
API_PORT=${BTAI_PORT}
BTAI_SHARED_NETWORK=${BTAI_SHARED_NETWORK}
${provider_key_assignment}
EOF
        )
        chmod 600 "$BTAI_DIR/.env" 2>/dev/null || true
        echo -e "    ${OK} BugTraceAI-API config (.env, mode 600)"
    fi

    # CLI configuration
    if $INSTALL_CLI || $MCP_CLI_ENABLED; then
        # Universal access: set CORS to '*' so the API accepts connections from both local and remote (VM) clients.
        local cors="*"

        # The CLI .env holds the live LLM API key — create it 0600 (umask 077 in a
        # subshell) so no other local user can read the secret, then chmod to be sure.
        ( umask 077
          cat > "$CLI_DIR/.env" << EOF
# BugTraceAI-CLI — Generated by Launcher v${VERSION} ($(iso_date))
PROVIDER=${LLM_PROVIDER}
BUGTRACE_INTERFACE=${CLI_INTERFACE}
CLI_PORT=${CLI_PORT}
MCP_PORT=${MCP_PORT}
${provider_key_assignment}
BUGTRACE_CORS_ORIGINS=${cors}
BTAI_SHARED_NETWORK=${BTAI_SHARED_NETWORK}
EOF
        )
        chmod 600 "$CLI_DIR/.env" 2>/dev/null || true
        echo -e "    ${OK} CLI config (.env, mode 600)"

        # Select the provider preset in the (soon-to-be-baked) conf so the deployed
        # CLI actually uses $LLM_PROVIDER rather than the shipped default.
        set_cli_provider_active
        echo -e "    ${OK} CLI provider preset: ${LLM_PROVIDER}"
    fi

    # Generate MCP config for AI assistants
    generate_mcp_config
}

# Generate MCP configuration file for AI assistants (mcporter, claude, etc.)
generate_mcp_config() {
    local has_mcp_endpoints=false
    $INSTALL_BTAI && [[ -n "$BTAI_MCP_PORT" ]] && has_mcp_endpoints=true
    $MCP_CLI_ENABLED && has_mcp_endpoints=true
    $MCP_RECON_ENABLED && has_mcp_endpoints=true

    if ! $has_mcp_endpoints; then
        return
    fi

    step "Generating MCP configuration..."
    local config_file="$INSTALL_DIR/mcp-config.json"
    local entries=()

    if $INSTALL_BTAI && [[ -n "$BTAI_MCP_PORT" ]]; then
        entries+=("    \"bugtraceai-api\": { \"baseUrl\": \"http://localhost:${BTAI_MCP_PORT}/mcp\" }")
    fi

    if $MCP_CLI_ENABLED && [[ -n "$MCP_PORT" ]]; then
        entries+=("    \"bugtraceai\": { \"baseUrl\": \"http://localhost:${MCP_PORT}/sse\" }")
    fi

    if $MCP_RECON_ENABLED && [[ -n "$RECON_PORT" ]]; then
        entries+=("    \"reconftw\": { \"baseUrl\": \"http://localhost:${RECON_PORT}/sse\" }")
    fi

    # Join entries with comma+newline
    local servers=""
    local i
    for i in "${!entries[@]}"; do
        servers+="${entries[$i]}"
        if [[ $i -lt $((${#entries[@]} - 1)) ]]; then
            servers+=","
        fi
        servers+=$'\n'
    done

    cat > "$config_file" << EOF
{
  "mcpServers": {
${servers}  }
}
EOF
    echo -e "    ${OK} MCP config (mcp-config.json)"
}

# Make the optional CLI reverse-proxy DNS lookup lazy for WEB+API installs.
# Nginx resolves literal upstream hostnames while loading its configuration;
# without a CLI container that would prevent the whole WEB stack from starting.
patch_optional_web_cli_proxy() {
    if ! $INSTALL_WEB || $INSTALL_CLI || [[ ! -f "$WEB_DIR/nginx.conf" ]]; then
        return 0
    fi
    if grep -Fq 'set $cli_api_host bugtrace-cli-api;' "$WEB_DIR/nginx.conf"; then
        return 0
    fi

    local tmp_file
    tmp_file="$(mktemp)"
    awk '
    index($0, "proxy_pass http://bugtrace-cli-api:${CLI_API_PORT}/;") {
        print "        set $cli_api_host bugtrace-cli-api;"
        print "        proxy_pass http://$cli_api_host:${CLI_API_PORT}/;"
        next
    }
    { print }
    ' "$WEB_DIR/nginx.conf" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }
    if ! grep -Fq 'set $cli_api_host bugtrace-cli-api;' "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi
    mv "$tmp_file" "$WEB_DIR/nginx.conf"
}

# Make the long first WEB image build resilient to transient npm registry
# resets.  This is deliberately applied by the Launcher because it also has to
# work when the selected WEB snapshot predates the upstream Dockerfile fix.
patch_web_npm_resilience() {
    local dockerfile="$WEB_DIR/backend/Dockerfile"
    local tmp_file

    [[ -f "$dockerfile" ]] || return 0

    # Do not rewrite a WEB snapshot that already carries the fix.
    if grep -q 'npm config set fetch-retries' "$dockerfile"; then
        return 0
    fi

    # Only patch the known Dockerfile commands.  If WEB changes its install
    # strategy, leave it alone rather than applying a broad or unsafe rewrite.
    if ! grep -Eq '^RUN npm ci( --omit=dev)?[[:space:]]*$' "$dockerfile"; then
        return 0
    fi

    tmp_file="$(mktemp)" || return 1
    if ! awk '
        /^RUN npm ci --omit=dev[[:space:]]*$/ {
            print "RUN npm config set fetch-retries 5 && npm config set fetch-retry-mintimeout 20000 && npm config set fetch-retry-maxtimeout 120000 && npm ci --omit=dev --no-audit --no-fund"
            next
        }
        /^RUN npm ci[[:space:]]*$/ {
            print "RUN npm config set fetch-retries 5 && npm config set fetch-retry-mintimeout 20000 && npm config set fetch-retry-maxtimeout 120000 && npm ci --no-audit --no-fund"
            next
        }
        { print }
    ' "$dockerfile" > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    # Copy over the existing file so its original permissions remain intact.
    if ! cp "$tmp_file" "$dockerfile"; then
        rm -f "$tmp_file"
        return 1
    fi
    rm -f "$tmp_file"
    info "Applied npm registry retry settings to the WEB Dockerfile."
}

# Undo only the exact npm retry lines emitted by patch_web_npm_resilience.
# Any remaining diff is a user/upstream edit, so refuse to pull over it.
_restore_web_npm_patch_for_update() {
    local file="$WEB_DIR/backend/Dockerfile"
    [[ -f "$file" ]] || return 0
    if grep -q 'npm config set fetch-retries 5' "$file"; then
        sed_inplace \
            -e 's|^RUN npm config set fetch-retries 5 && npm config set fetch-retry-mintimeout 20000 && npm config set fetch-retry-maxtimeout 120000 && npm ci --omit=dev --no-audit --no-fund$|RUN npm ci --omit=dev|' \
            -e 's|^RUN npm config set fetch-retries 5 && npm config set fetch-retry-mintimeout 20000 && npm config set fetch-retry-maxtimeout 120000 && npm ci --no-audit --no-fund$|RUN npm ci|' "$file"
        if ! (cd "$WEB_DIR" && git diff --quiet -- backend/Dockerfile); then
            patch_web_npm_resilience >/dev/null 2>&1 || true
            error "WEB Dockerfile contains edits beyond the known launcher patch; preserving them and stopping update."
            return 1
        fi
    fi
}

# Restore only the tracked WEB files that exactly match the launcher's own
# Compose/nginx transformation.  A user edit in either file must stop update
# rather than being silently discarded or allowed to block git pull.
_restore_web_compose_patches_for_update() (
    local original_dir="$WEB_DIR" tmp rel changed=false
    [[ -d "$original_dir/.git" ]] || return 0
    tmp="$(mktemp -d)" || return 1
    for rel in docker-compose.yml nginx.conf; do
        if git -C "$original_dir" cat-file -e "HEAD:$rel" 2>/dev/null; then
            git -C "$original_dir" show "HEAD:$rel" > "$tmp/$rel" || {
                rm -rf "$tmp"
                return 1
            }
        fi
    done

    local saved_web_dir="$WEB_DIR" saved_cli_dir="$CLI_DIR"
    local saved_install_web="$INSTALL_WEB"
    WEB_DIR="$tmp"
    CLI_DIR="$tmp/no-cli"
    INSTALL_WEB=true
    patch_compose >/dev/null 2>&1 || {
        WEB_DIR="$saved_web_dir"
        CLI_DIR="$saved_cli_dir"
        INSTALL_WEB="$saved_install_web"
        rm -rf "$tmp"
        return 1
    }
    WEB_DIR="$saved_web_dir"
    CLI_DIR="$saved_cli_dir"
    INSTALL_WEB="$saved_install_web"

    for rel in docker-compose.yml nginx.conf; do
        if ! git -C "$original_dir" diff HEAD --quiet -- "$rel"; then
            if [[ ! -f "$tmp/$rel" || ! -f "$original_dir/$rel" ]] || ! cmp -s "$tmp/$rel" "$original_dir/$rel"; then
                rm -rf "$tmp"
                error "WEB $rel has edits beyond the known launcher patch; preserving them and stopping update."
                return 1
            fi
            changed=true
        fi
    done
    if $changed; then
        for rel in docker-compose.yml nginx.conf; do
            if ! git -C "$original_dir" diff HEAD --quiet -- "$rel"; then
                git -C "$original_dir" show "HEAD:$rel" > "$original_dir/$rel" || {
                    rm -rf "$tmp"
                    return 1
                }
            fi
        done
    fi
    rm -rf "$tmp"
)

# CLI has a smaller launcher patch surface, but it needs the same protection
# before pull because its selected host ports are written into Compose.
_restore_cli_compose_patch_for_update() (
    local original_dir="$CLI_DIR" tmp
    [[ -d "$original_dir/.git" && -f "$original_dir/docker-compose.yml" ]] || return 0
    if git -C "$original_dir" diff HEAD --quiet -- docker-compose.yml; then
        return 0
    fi
    tmp="$(mktemp -d)" || return 1
    git -C "$original_dir" show HEAD:docker-compose.yml > "$tmp/docker-compose.yml" || {
        rm -rf "$tmp"
        return 1
    }
    local saved_cli_dir="$CLI_DIR" saved_web_dir="$WEB_DIR"
    CLI_DIR="$tmp"
    WEB_DIR="$tmp/no-web"
    patch_compose >/dev/null 2>&1 || {
        CLI_DIR="$saved_cli_dir"
        WEB_DIR="$saved_web_dir"
        rm -rf "$tmp"
        return 1
    }
    CLI_DIR="$saved_cli_dir"
    WEB_DIR="$saved_web_dir"
    if ! cmp -s "$tmp/docker-compose.yml" "$original_dir/docker-compose.yml"; then
        rm -rf "$tmp"
        error "CLI docker-compose.yml has edits beyond the known launcher patch; preserving them and stopping update."
        return 1
    fi
    git -C "$original_dir" show HEAD:docker-compose.yml > "$original_dir/docker-compose.yml" || {
        rm -rf "$tmp"
        return 1
    }
    rm -rf "$tmp"
)

# Patch docker-compose files to use .env values and enable MCP profiles
patch_compose() {
    # Migrate installations produced by older launcher versions, which wrote
    # COMPOSE_PROFILES into .env.docker and could activate optional services
    # during an unrelated base WEB command.
    local web_env="$WEB_DIR/.env.docker"
    if [[ -f "$web_env" ]]; then
        sed_inplace '/^COMPOSE_PROFILES=/d' "$web_env"
    fi

    # Patch CLI docker-compose if CLI or any MCP is enabled
    if [[ -f "$CLI_DIR/docker-compose.yml" ]] && { $INSTALL_CLI || $MCP_CLI_ENABLED; }; then
        local compose="$CLI_DIR/docker-compose.yml"

        # CORS is loaded from .env via env_file; keep any other environment keys.
        sed_inplace '/BUGTRACE_CORS_ORIGINS/d' "$compose"
        remove_empty_environment_headers "$compose"

        # Patch port mapping if non-default
        if [[ -n "$CLI_PORT" && "$CLI_PORT" != "8000" ]]; then
            sed_inplace "s/\"8000:8000\"/\"${CLI_PORT}:8000\"/" "$compose"
        fi

        # Patch MCP port mapping if non-default
        if [[ -n "$MCP_PORT" && "$MCP_PORT" != "8001" ]]; then
            sed_inplace "s/\"8001:8001\"/\"${MCP_PORT}:8001\"/" "$compose"
        fi

        # WEB's nginx proxy resolves bugtrace-cli-api on the shared platform
        # bridge. Public CLI Compose files only attach the API to their private
        # project network, so add an external shared network and stable alias.
        if $INSTALL_WEB; then
            patch_cli_web_network "$compose" || return 1
        fi
    fi

    # Patch WEB docker-compose (MCP agents and platform-specific fixes)
    if [[ -f "$WEB_DIR/docker-compose.yml" ]]; then
        local web_compose="$WEB_DIR/docker-compose.yml"
        local host_arch
        host_arch="$(uname -m)"

        # Launcher expects MCP agents over SSE; make SSE default for WEB-managed MCP services.
        if $MCP_RECON_ENABLED; then
            sed_inplace 's/SSE_MODE=${RECON_SSE_MODE:-false}/SSE_MODE=${RECON_SSE_MODE:-true}/' "$web_compose"
        fi
        if $MCP_CLI_ENABLED && ! $INSTALL_CLI; then
            sed_inplace 's/SSE_MODE=${CLI_SSE_MODE:-false}/SSE_MODE=${CLI_SSE_MODE:-true}/' "$web_compose"
        fi

        # Patch reconFTW port if non-default
        if $MCP_RECON_ENABLED && [[ -n "$RECON_PORT" && "$RECON_PORT" != "8002" ]]; then
            sed_inplace "s/\"8002:8002\"/\"${RECON_PORT}:8002\"/" "$web_compose"
        fi

        # reconFTW base image is currently amd64-only; enforce emulation on ARM hosts.
        if $MCP_RECON_ENABLED && [[ "$host_arch" == "arm64" || "$host_arch" == "aarch64" ]]; then
            ensure_recon_amd64_platform "$web_compose"
            ensure_recon_health_timing "$web_compose"
        fi
        if $MCP_RECON_ENABLED; then
            ensure_recon_env_defaults "$web_compose"
            ensure_recon_local_build "$web_compose"
        fi
        if $MCP_KALI_ENABLED; then
            ensure_kali_startup_command "$web_compose"
        fi

        # WEB-only installs do not have a CLI container. Keep the optional
        # CLI route lazy so nginx can start while correctly returning 502 only
        # if somebody requests a feature that needs the absent CLI.
        patch_optional_web_cli_proxy

        # BugTraceAI-API owns and creates the shared bridge. WEB is deployed
        # from a separate Compose project, so it must attach to that bridge as
        # external instead of trying to create the same Docker network under
        # its own project label.
        if $INSTALL_BTAI; then
            patch_web_api_shared_network "$web_compose" || return 1
        fi

        # Patch CLI MCP port if non-default
        if $MCP_CLI_ENABLED && [[ -n "$MCP_PORT" && "$MCP_PORT" != "8001" ]]; then
            sed_inplace "s/\"8001:8001\"/\"${MCP_PORT}:8001\"/" "$web_compose"
        fi

    fi

    # A first WEB build can spend several minutes resolving npm packages.  A
    # transient registry reset (ECONNRESET/network aborted) must not make the
    # whole launcher report that WEB installation failed.  Apply this small,
    # idempotent compatibility patch to older/public WEB snapshots before the
    # first build; newer snapshots that already contain the retry settings are
    # left untouched.
    if [[ -f "$WEB_DIR/backend/Dockerfile" ]]; then
        patch_web_npm_resilience || return 1
    fi
}

# Make WEB join the network created by the separate BugTraceAI-API Compose
# project. Standalone WEB installs keep their own bridge and remain usable.
patch_web_api_shared_network() {
    local compose=$1 tmp_file
    [[ -f "$compose" ]] || return 0

    if awk '
        /^  bugtraceai-network:[[:space:]]*$/ { in_shared=1; found=1; next }
        in_shared && /^  [[:alnum:]_-]+:[[:space:]]*$/ { in_shared=0 }
        in_shared && /^    external:[[:space:]]*true[[:space:]]*$/ { external=1 }
        END { exit !(found && external) }
    ' "$compose"; then
        return 0
    fi

    if ! awk '
        /^  bugtraceai-network:[[:space:]]*$/ { in_shared=1; found=1; next }
        in_shared && /^  [[:alnum:]_-]+:[[:space:]]*$/ { in_shared=0 }
        in_shared && /^    name:[[:space:]]*\$\{BTAI_SHARED_NETWORK:-bugtraceai-platform\}[[:space:]]*$/ { named=1 }
        in_shared && /^    driver:[[:space:]]*bridge[[:space:]]*$/ { bridge=1 }
        END { exit !(found && named && bridge) }
    ' "$compose"; then
        error "WEB Compose has no supported API-shared network declaration; the original file was preserved."
        return 1
    fi

    tmp_file="$(mktemp)" || return 1
    if ! awk '
        /^  bugtraceai-network:[[:space:]]*$/ { in_shared=1; found=1; print; next }
        in_shared && /^  [[:alnum:]_-]+:[[:space:]]*$/ { in_shared=0 }
        in_shared && /^    driver:[[:space:]]*bridge[[:space:]]*$/ { print "    external: true"; changed=1; next }
        { print }
        END { if (!found || !changed) exit 2 }
    ' "$compose" > "$tmp_file"; then
        rm -f "$tmp_file"
        error "Could not apply WEB's shared-network patch; the original file was preserved."
        return 1
    fi
    mv "$tmp_file" "$compose"
}

# Connect the CLI API container to WEB/API's shared bridge without changing
# the CLI-only runtime. The API-target service is started first and creates
# this network; the explicit alias matches WEB's nginx upstream.
patch_cli_web_network() {
    local compose=$1 tmp_file
    [[ -f "$compose" ]] || return 0

    if grep -Fq 'bugtrace-cli-api' "$compose" && \
       grep -Fq 'name: ${BTAI_SHARED_NETWORK:-bugtraceai-platform}' "$compose"; then
        return 0
    fi
    if grep -q '^networks:[[:space:]]*$' "$compose"; then
        error "CLI Compose already defines custom networks; cannot safely add the WEB bridge automatically."
        return 1
    fi
    if ! grep -q '^  api:[[:space:]]*$' "$compose"; then
        error "CLI Compose layout is unsupported for the WEB shared-network patch."
        return 1
    fi

    tmp_file="$(mktemp)" || return 1
    if ! awk '
        function api_network() {
            print "    networks:"
            print "      default: {}"
            print "      btai_shared:"
            print "        aliases:"
            print "          - bugtrace-cli-api"
            api_network_added=1
        }
        function shared_network() {
            print "networks:"
            print "  default: {}"
            print "  btai_shared:"
            print "    name: ${BTAI_SHARED_NETWORK:-bugtraceai-platform}"
            print "    external: true"
            print ""
            shared_network_added=1
        }
        /^  api:[[:space:]]*$/ { in_api=1; print; next }
        in_api && /^  [[:alnum:]_-]+:[[:space:]]*$/ {
            if (!api_network_added) api_network()
            in_api=0
            print
            next
        }
        /^volumes:[[:space:]]*$/ {
            if (in_api && !api_network_added) api_network()
            in_api=0
            if (!shared_network_added) shared_network()
        }
        { print }
        END {
            if (in_api && !api_network_added) api_network()
            if (!shared_network_added) shared_network()
            if (!api_network_added || !shared_network_added) exit 2
        }
    ' "$compose" > "$tmp_file"; then
        rm -f "$tmp_file"
        error "Could not apply the CLI shared-network patch; the original Compose file was preserved."
        return 1
    fi
    if ! mv "$tmp_file" "$compose"; then
        rm -f "$tmp_file"
        return 1
    fi
}

# Docker compose helpers
_web_compose() {
    if [[ -z "$COMPOSE_CMD" ]]; then error "Docker Compose not found. Run: ./launcher.sh"; return 1; fi
    # Do not inherit a caller's COMPOSE_PROFILES, including one left in an old
    # .env.docker. An empty process value takes precedence over --env-file;
    # optional agents are selected solely through explicit --profile flags.
    (cd "$WEB_DIR" && COMPOSE_PROFILES= $COMPOSE_CMD --env-file .env.docker "$@")
}

_cli_compose() {
    if [[ -z "$COMPOSE_CMD" ]]; then error "Docker Compose not found. Run: ./launcher.sh"; return 1; fi
    if $CLI_MANAGED && [[ "$CLI_INTERFACE" == tui && "$CLI_RUNTIME" == docker ]]; then
        (cd "$CLI_DIR" && $COMPOSE_CMD -f docker-compose.tui.yml "$@")
    else
        (cd "$CLI_DIR" && $COMPOSE_CMD "$@")
    fi
}

_btai_compose() {
    if [[ -z "$COMPOSE_CMD" ]]; then error "Docker Compose not found. Run: ./launcher.sh"; return 1; fi
    (cd "$BTAI_DIR" && DOCKER_DEFAULT_PLATFORM=linux/amd64 $COMPOSE_CMD "$@")
}

# Run a docker compose command, streaming its OWN output to the terminal.
# Usage: _build_with_progress "label" compose_fn [extra_args...]
#   compose_fn: _web_compose or _cli_compose
#
# No custom spinner: we pipe through `tee`, so docker sees a non-TTY stdout and
# falls back to its classic plain scrolling build log — exactly what you'd see
# running `docker compose build` in a normal terminal. `tee` also keeps a copy
# in the build log for the failure-tail diagnostics below. This removes the whole
# class of hand-rolled-ANSI / smeared-line / broken-TTY bugs.
_build_with_progress() {
    local label=$1; shift
    local build_log="$INSTALL_DIR/.build.log"

    echo -e "    ${DIM}${label}: building — live docker output below (can take several minutes)${NC}"
    "$@" 2>&1 | tee -a "$build_log"
    return "${PIPESTATUS[0]}"
}

_start_web_profile() {
    local label=$1
    shift
    local build_log="$INSTALL_DIR/.build.log"

    if _build_with_progress "$label" _web_compose "$@"; then
        return 0
    fi
    echo ""
    error "Failed to start $label."
    echo -e "    ${DIM}Last lines from build log:${NC}"
    tail -5 "$build_log" 2>/dev/null | while IFS= read -r line; do
        echo -e "    ${RED}│${NC} ${DIM}${line}${NC}"
    done
    echo -e "    ${DIM}Full log: ${build_log}${NC}"
    return 1
}

_start_cli_service() {
    local build_log="$INSTALL_DIR/.build.log"

    if [[ ! -f "$CLI_DIR/docker-compose.yml" ]]; then
        error "CLI docker-compose.yml not found — clone may have failed."
        return 1
    fi

    echo ""
    step "Building & starting CLI service..."
    echo -e "    ${DIM}(compiles Go tools + installs browser — may take 10-15 min on first run)${NC}"
    if ! _build_with_progress "CLI" _cli_compose up -d --build; then
        echo ""
        error "Failed to start CLI service."
        echo -e "    ${DIM}Last lines from build log:${NC}"
        tail -5 "$build_log" 2>/dev/null | while IFS= read -r line; do
            echo -e "    ${RED}│${NC} ${DIM}${line}${NC}"
        done
        echo -e "    ${DIM}Full log: ${build_log}${NC}"
        echo -e "    ${DIM}Or run: ./launcher.sh logs cli${NC}"
        return 1
    fi
    echo -e "    ${OK} CLI service started"
}

start_services() {
    local build_log="$INSTALL_DIR/.build.log"
    : > "$build_log"

    # Start the standalone API before WEB so its reverse-proxy target is ready
    # while the frontend container is booting.
    if $INSTALL_BTAI; then
        if [[ ! -f "$BTAI_DIR/docker-compose.yml" ]]; then
            error "BugTraceAI-API docker-compose.yml not found — clone may have failed."
            exit 1
        fi
        echo ""
        step "Building & starting BugTraceAI-API..."
        if ! _build_with_progress "BugTraceAI-API" _btai_compose up -d --build; then
            error "Failed to start BugTraceAI-API."
            exit 1
        fi
        echo -e "    ${OK} BugTraceAI-API started"
    fi

    # Start CLI before WEB. The WEB nginx configuration references the CLI
    # service on the shared Docker network and can fail at startup if DNS is
    # resolved before the CLI container exists.
    if $INSTALL_CLI || $MCP_CLI_ENABLED; then
        _start_cli_service || exit 1
    fi

    # Start WEB services
    if $INSTALL_WEB && [[ -n "$WEB_PORT" ]]; then
        if [[ ! -f "$WEB_DIR/docker-compose.yml" ]]; then
            error "WEB docker-compose.yml not found — clone may have failed."
            exit 1
        fi
        echo ""
        step "Building & starting WEB services..."
        echo -e "    ${DIM}(postgres + backend + frontend — may take 5-10 min on first run)${NC}"
        if ! _build_with_progress "WEB" _web_compose up -d --build; then
            echo ""
            error "Failed to start WEB services."
            echo -e "    ${DIM}Last lines from build log:${NC}"
            tail -5 "$build_log" 2>/dev/null | while IFS= read -r line; do
                echo -e "    ${RED}│${NC} ${DIM}${line}${NC}"
            done
            echo -e "    ${DIM}Full log: ${build_log}${NC}"
            echo -e "    ${DIM}Or run: ./launcher.sh logs web${NC}"
            exit 1
        fi
        echo -e "    ${OK} WEB services started"
    fi

    # Start optional WEB-owned agents only after the base services and CLI are
    # up. Each profile is a separate Compose invocation so a recon build cannot
    # cancel Kali's image pull (public WEB names recon `reconftw-mcp:local`).
    resolve_web_mcp_profiles
    if (( ${#WEB_MCP_PROFILE_ARGS[@]} > 0 )) && [[ -f "$WEB_DIR/docker-compose.yml" ]]; then
        local profile_label
        local optional_ok=true
        profile_label="$(IFS=,; printf '%s' "${WEB_MCP_PROFILE_NAMES[*]}")"
        echo ""
        step "Starting optional agents (profiles: ${profile_label})..."

        if $MCP_RECON_ENABLED; then
            if ! ensure_recon_source; then
                error "Cannot start reconFTW until its source is available."
                optional_ok=false
            elif _start_web_profile "reconFTW" --profile recon up -d --build; then
                echo -e "    ${OK} reconFTW MCP started"
            else
                warn "reconFTW MCP failed to start. Core services are already up."
                optional_ok=false
            fi
        fi
        if $MCP_KALI_ENABLED; then
            if _start_web_profile "Kali" --profile kali up -d; then
                echo -e "    ${OK} Kali Linux toolbox started"
            else
                warn "Kali toolbox failed to start. Core services are already up."
                optional_ok=false
            fi
        fi
        if ! $optional_ok; then
            return 1
        fi
    fi
}

# Wait for a URL to respond, with visual feedback
# Pass "sse" as $4 for an SSE stream, or "mcp" for a Streamable HTTP endpoint.
wait_for_url() {
    local url=$1 label=$2 timeout=${3:-120} type=${4:-http}
    local elapsed=0 interval=3

    while [[ $elapsed -lt $timeout ]]; do
    if [[ "$type" == "sse" ]]; then
            local sse_status
            sse_status=$(curl -sS -N --max-time 2 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
            # A stream is healthy only when curl received an HTTP 2xx status;
            # an arbitrary timeout from an unreachable endpoint is not enough.
            if [[ "$sse_status" =~ ^2[0-9][0-9]$ ]]; then
                printf "\r    ${OK} %-30s\n" "$label"
                return 0
            fi
        elif [[ "$type" == "health" || "$type" == "webhealth" || "$type" == "cli-health" ]]; then
            local health_body health_status health_file
            local healthy_status_pattern='"status"[[:space:]]*:[[:space:]]*"(healthy|ok|ready|up|alive|running|pass)"'
            local misconfigured_status_pattern='"status"[[:space:]]*:[[:space:]]*"misconfigured"'
            local provider_ready_pattern='"provider_ready"[[:space:]]*:[[:space:]]*true'
            local api_key_missing_pattern='"api_key_configured"[[:space:]]*:[[:space:]]*false'
            local web_success_pattern='"success"[[:space:]]*:[[:space:]]*true'
            local web_data_pattern='"data"[[:space:]]*:[[:space:]]*\{'
            local healthy=false
            health_file="$(mktemp "${TMPDIR:-/tmp}/btai-health.XXXXXX")" || return 1
            health_body=$(curl -sS --max-time 2 -o "$health_file" -w '%{http_code}' "$url" 2>/dev/null || true)
            health_status="$(cat "$health_file" 2>/dev/null || true)"
            rm -f "$health_file"
            if [[ "$type" == "health" || "$type" == "cli-health" ]]; then
                if [[ "$health_status" =~ $healthy_status_pattern ]]; then
                    healthy=true
                elif [[ "$type" == "cli-health" && \
                        "$health_status" =~ $misconfigured_status_pattern && \
                        "$health_status" =~ $provider_ready_pattern && \
                        "$health_status" =~ $api_key_missing_pattern ]]; then
                    healthy=true
                fi
            elif [[ "$type" == "webhealth" && \
                    "$health_status" =~ $web_success_pattern && \
                    "$health_status" =~ $web_data_pattern && \
                    "$health_status" =~ $healthy_status_pattern ]]; then
                healthy=true
            fi
            if [[ "$health_body" =~ ^2[0-9][0-9]$ ]] && $healthy; then
                printf "\\r    ${OK} %-30s\\n" "$label"
                return 0
            fi
        elif [[ "$type" == "mcp" ]]; then
            local mcp_status
            mcp_status=$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' \
                -H 'Accept: application/json, text/event-stream' "$url" 2>/dev/null || true)
            # GET /mcp may legitimately return 400/405 until a client sends a
            # JSON-RPC request. Those statuses still prove the listener exists;
            # 000 means no HTTP response was received.
            local mcp_status_pattern='^(2[0-9][0-9]|400|405|406)$'
            if [[ "$mcp_status" =~ $mcp_status_pattern ]]; then
                printf "\r    ${OK} %-30s\n" "$label"
                return 0
            fi
        else
            curl -sf --max-time 2 "$url" &>/dev/null
            local res=$?
            if [[ $res -eq 0 ]]; then
                printf "\r    ${OK} %-30s\n" "$label"
                return 0
            fi
        fi
        printf "\r    ${DIM}waiting for %s... (%ds/%ds)${NC}" "$label" "$elapsed" "$timeout"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    printf "\r    ${FAIL} %-30s (timeout after %ds)\n" "$label" "$timeout"
    return 1
}

health_checks() {
    echo ""
    info "Running health checks..."
    echo ""

    local all_ok=true

    # A selected component without a host port is a failed deployment, not a
    # component whose health check can be skipped.
    if $INSTALL_WEB && [[ -z "$WEB_PORT" ]]; then
        error "WEB is selected but has no configured host port."
        all_ok=false
    fi
    if $INSTALL_BTAI && { [[ -z "$BTAI_PORT" ]] || [[ -z "$BTAI_MCP_PORT" ]]; }; then
        error "BugTraceAI-API is selected but one or more host ports are missing."
        all_ok=false
    fi
    if { $INSTALL_CLI || $MCP_CLI_ENABLED; } && [[ -z "$CLI_PORT" ]]; then
        error "CLI is selected but has no configured host port."
        all_ok=false
    fi
    if $MCP_CLI_ENABLED && [[ -z "$MCP_PORT" ]]; then
        error "BugTraceAI MCP is selected but has no configured host port."
        all_ok=false
    fi
    if $MCP_RECON_ENABLED && [[ -z "$RECON_PORT" ]]; then
        error "reconFTW MCP is selected but has no configured host port."
        all_ok=false
    fi

    # WEB health check
    if $INSTALL_WEB && [[ -n "$WEB_PORT" ]]; then
        wait_for_url "http://localhost:${WEB_PORT}" "WEB (port ${WEB_PORT})" 120 || all_ok=false
        wait_for_url "http://localhost:${WEB_PORT}/health" "WEB backend health" 120 webhealth || all_ok=false
        wait_for_url "http://localhost:${WEB_PORT}/kr-api/health" "API Discovery (Kiterunner)" 120 health || all_ok=false
        if $INSTALL_BTAI; then
            wait_for_url "http://localhost:${WEB_PORT}/btai-api/health" "WEB to BugTraceAI-API proxy" 120 health || all_ok=false
        fi
        if $INSTALL_CLI; then
            wait_for_url "http://localhost:${WEB_PORT}/cli-api/health" "WEB to CLI proxy" 120 cli-health || all_ok=false
        fi
    fi

    if $INSTALL_BTAI && [[ -n "$BTAI_PORT" ]]; then
        wait_for_url "http://localhost:${BTAI_PORT}/health" "BugTraceAI-API (port ${BTAI_PORT})" 180 health || all_ok=false
    fi

    if $INSTALL_BTAI && [[ -n "$BTAI_MCP_PORT" ]]; then
        wait_for_url "http://localhost:${BTAI_MCP_PORT}/mcp" \
            "BugTraceAI-API MCP (port ${BTAI_MCP_PORT})" 120 mcp || all_ok=false
    fi

    # CLI health check
    if { $INSTALL_CLI || $MCP_CLI_ENABLED; } && [[ -n "$CLI_PORT" ]]; then
        wait_for_url "http://localhost:${CLI_PORT}/health" "CLI (port ${CLI_PORT})" 120 cli-health || all_ok=false
    fi

    # MCP agents health checks
    if $MCP_CLI_ENABLED && [[ -n "$MCP_PORT" ]]; then
        wait_for_url "http://localhost:${MCP_PORT}/sse" "BugTraceAI MCP (port ${MCP_PORT})" 120 sse || all_ok=false
    fi

    if $MCP_RECON_ENABLED && [[ -n "$RECON_PORT" ]]; then
        local recon_timeout=180
        local host_arch
        host_arch="$(uname -m)"
        if [[ "$host_arch" == "arm64" || "$host_arch" == "aarch64" ]]; then
            # reconFTW runs in amd64 emulation on Apple Silicon and may need extra warmup time.
            recon_timeout=300
        fi
        wait_for_url "http://localhost:${RECON_PORT}/sse" "reconFTW MCP (port ${RECON_PORT})" "$recon_timeout" sse || all_ok=false
    fi

    if $MCP_KALI_ENABLED; then
        # Kali is a toolbox container, not an HTTP/SSE MCP endpoint.
        local kali_status kali_ready=false attempt
        for attempt in {1..20}; do
            kali_status=$(docker ps --format '{{.Status}}' --filter "name=^kali-mcp-server$" 2>/dev/null | head -1)
            if [[ -n "$kali_status" ]] && docker exec kali-mcp-server sh -lc 'command -v nmap >/dev/null && command -v hydra >/dev/null && command -v python3 >/dev/null' >/dev/null 2>&1; then
                kali_ready=true
                break
            fi
            sleep 3
        done
        if $kali_ready; then
            echo -e "    ${OK} Kali toolbox (running)"
        else
            echo -e "    ${FAIL} Kali toolbox (not running)"
            all_ok=false
        fi
    fi

    echo ""
    if [[ "$all_ok" == true ]]; then
        success "All services healthy!"
        return 0
    else
        warn "Some services didn't respond. Check logs: ./launcher.sh logs"
        return 1
    fi
}

save_state() {
    cat > "$STATE_FILE" << EOF
{
  "version": "${VERSION}",
  "mode": "${DEPLOY_MODE}",
  "install_profile": "${INSTALL_PROFILE}",
  "cli_interface": "${CLI_INTERFACE}",
  "cli_runtime": "${CLI_RUNTIME}",
  "cli_global": "${CLI_GLOBAL}",
  "cli_managed": ${CLI_MANAGED},
  "cli_checkout": "${CLI_DIR}",
  "web_port": "${WEB_PORT}",
  "cli_port": "${CLI_PORT}",
  "btai_port": "${BTAI_PORT}",
  "btai_mcp_port": "${BTAI_MCP_PORT}",
  "mcp_port": "${MCP_PORT}",
  "recon_port": "${RECON_PORT}",
  "provider": "${LLM_PROVIDER}",
  "install_web": ${INSTALL_WEB},
  "install_cli": ${INSTALL_CLI},
  "install_btai": ${INSTALL_BTAI},
  "mcp_cli_enabled": ${MCP_CLI_ENABLED},
  "mcp_recon_enabled": ${MCP_RECON_ENABLED},
  "mcp_kali_enabled": ${MCP_KALI_ENABLED},
  "install_dir": "${INSTALL_DIR}",
  "deployed_at": "$(iso_date)"
}
EOF
    chmod 600 "$STATE_FILE"
    if $RELEASE_PINNED; then
        python3 "$SCRIPT_DIR/release_manager.py" record --install-dir "$INSTALL_DIR" || return 1
    fi
}

show_success() {
    # Detect host IP for remote access
    local host_ip=""
    if command -v hostname &>/dev/null; then
        host_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [[ -z "$host_ip" ]]; then
        host_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
    fi

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}     ${BOLD}BugTraceAI deployed successfully!${NC}            ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""

    # Show main endpoints (local)
    echo -e "  ${BOLD}Local access:${NC}"
    if [[ -n "$WEB_PORT" ]]; then
        echo -e "  ${ARROW} WEB Interface: ${BOLD}${CYAN}http://localhost:${WEB_PORT}${NC}"
    fi
    if [[ -n "$CLI_PORT" ]]; then
        echo -e "  ${ARROW} CLI API:       ${BOLD}${CYAN}http://localhost:${CLI_PORT}${NC}"
        echo -e "  ${ARROW} API Docs:      ${BOLD}${CYAN}http://localhost:${CLI_PORT}/docs${NC}"
    fi
    if [[ -n "$BTAI_PORT" ]]; then
        echo -e "  ${ARROW} BugTraceAI-API REST: ${BOLD}${CYAN}http://localhost:${BTAI_PORT}${NC}"
    fi

    # Show remote access if IP detected and different from localhost
    if [[ -n "$host_ip" && "$host_ip" != "127.0.0.1" ]]; then
        echo ""
        echo -e "  ${BOLD}Remote access (from other machines on your network):${NC}"
        if [[ -n "$WEB_PORT" ]]; then
            echo -e "  ${ARROW} WEB Interface: ${BOLD}${CYAN}http://${host_ip}:${WEB_PORT}${NC}"
        fi
        if [[ -n "$CLI_PORT" ]]; then
            echo -e "  ${ARROW} CLI API:       ${BOLD}${CYAN}http://${host_ip}:${CLI_PORT}${NC}"
        fi
        if [[ -n "$BTAI_PORT" ]]; then
            echo -e "  ${ARROW} BugTraceAI-API REST: ${BOLD}${CYAN}http://${host_ip}:${BTAI_PORT}${NC}"
        fi
        if $INSTALL_BTAI && [[ -n "$BTAI_MCP_PORT" ]]; then
            echo -e "  ${ARROW} BugTraceAI-API MCP:  ${BOLD}${CYAN}http://${host_ip}:${BTAI_MCP_PORT}/mcp${NC}"
        fi
    fi

    # Show only real MCP endpoints here. Kali is rendered separately because
    # its upstream image is an interactive toolbox, not a network MCP server.
    local has_mcp_endpoints=false
    $INSTALL_BTAI && [[ -n "$BTAI_MCP_PORT" ]] && has_mcp_endpoints=true
    $MCP_CLI_ENABLED && has_mcp_endpoints=true
    $MCP_RECON_ENABLED && has_mcp_endpoints=true

    if $has_mcp_endpoints; then
        echo ""
        echo -e "  ${BOLD}MCP endpoints:${NC}"
        $INSTALL_BTAI && [[ -n "$BTAI_MCP_PORT" ]] && echo -e "    ${OK} BugTraceAI-API: ${CYAN}http://localhost:${BTAI_MCP_PORT}/mcp${NC}"
        $MCP_CLI_ENABLED && echo -e "    ${OK} BugTraceAI: ${CYAN}http://localhost:${MCP_PORT}/sse${NC}"
        $MCP_RECON_ENABLED && echo -e "    ${OK} reconFTW:   ${CYAN}http://localhost:${RECON_PORT}/sse${NC} (by @six2dez)"

        echo ""
        echo -e "  ${BOLD}Connect your AI assistant:${NC}"
        echo -e "  ${DIM}Config file: ${INSTALL_DIR}/mcp-config.json${NC}"
        echo ""

        local mcp_host="${host_ip:-localhost}"
        echo -e "  ${DIM}Add to your MCP client config:${NC}"
        echo ""

        if $INSTALL_BTAI && [[ -n "$BTAI_MCP_PORT" ]]; then
            echo -e "    ${CYAN}\"bugtraceai-api\": {${NC}"
            echo -e "    ${CYAN}  \"baseUrl\": \"http://${mcp_host}:${BTAI_MCP_PORT}/mcp\"${NC}"
            echo -e "    ${CYAN}}${NC}"
        fi
        if $MCP_CLI_ENABLED; then
            echo -e "    ${CYAN}\"bugtraceai\": {${NC}"
            echo -e "    ${CYAN}  \"baseUrl\": \"http://${mcp_host}:${MCP_PORT}/sse\"${NC}"
            echo -e "    ${CYAN}}${NC}"
        fi
        if $MCP_RECON_ENABLED; then
            echo -e "    ${CYAN}\"reconftw\": {${NC}"
            echo -e "    ${CYAN}  \"baseUrl\": \"http://${mcp_host}:${RECON_PORT}/sse\"${NC}"
            echo -e "    ${CYAN}}${NC}"
        fi
    fi

    if $MCP_KALI_ENABLED; then
        echo ""
        echo -e "  ${BOLD}Kali toolbox:${NC} ${CYAN}docker exec -it kali-mcp-server bash${NC}"
        echo -e "  ${YELLOW}Kali Tip:${NC} To scan this machine from Kali, use:"
        echo -e "     ${BOLD}${DIM}nmap -Pn host.docker.internal${NC}"
    fi

    echo ""
    echo -e "  ${BOLD}Commands:${NC}"
    if $INSTALL_CLI && [[ "$CLI_INTERFACE" == tui || "$CLI_INTERFACE" == both ]]; then
        echo -e "    ${DIM}./launcher.sh tui${NC}          Terminal workspace (CLI 4.x)"
    fi
    echo -e "    ${DIM}./launcher.sh status${NC}       Service dashboard"
    echo -e "    ${DIM}./launcher.sh logs${NC}         View logs"
    echo -e "    ${DIM}./launcher.sh stop${NC}         Stop services"
    echo -e "    ${DIM}./launcher.sh update${NC}       Update & rebuild"
    echo ""
}

# ── Service Management Commands ──────────────────────────────────────────────

load_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        error "BugTraceAI not installed. Run: ./launcher.sh"
        exit 1
    fi
    CLI_GLOBAL=$(awk -F'"' '/"cli_global"/{print $4}' "$STATE_FILE")
    [[ "$CLI_GLOBAL" == yes ]] || CLI_GLOBAL=no
    local saved_interface saved_runtime saved_checkout saved_managed
    saved_interface=$(awk -F'"' '/"cli_interface"/{print $4}' "$STATE_FILE")
    saved_runtime=$(awk -F'"' '/"cli_runtime"/{print $4}' "$STATE_FILE")
    saved_checkout=$(awk -F'"' '/"cli_checkout"/{print $4}' "$STATE_FILE")
    CLI_PROFILE_SAVED=false
    case "$saved_interface/$saved_runtime" in tui/local|api/local|both/local|tui/docker|api/docker|both/docker) CLI_PROFILE_SAVED=true ;; esac
    saved_managed=$(awk '/"cli_managed"/ {gsub(/[, ]/, "", $2); print $2}' "$STATE_FILE")
    case "$saved_interface" in tui|api|both) CLI_INTERFACE="$saved_interface" ;; *) CLI_INTERFACE=api ;; esac
    case "$saved_runtime" in local|docker) CLI_RUNTIME="$saved_runtime" ;; *) CLI_RUNTIME=docker ;; esac
    [[ "$saved_managed" == true ]] && CLI_MANAGED=true || CLI_MANAGED=false
    if $CLI_MANAGED && [[ -n "$saved_checkout" ]]; then CLI_DIR="$saved_checkout"; fi
    DEPLOY_MODE=$(awk -F'"' '/"mode"/{print $4}' "$STATE_FILE")
    INSTALL_PROFILE=$(awk -F'"' '/"install_profile"/{print $4}' "$STATE_FILE")
    WEB_PORT=$(awk -F'"' '/"web_port"/{print $4}' "$STATE_FILE" 2>/dev/null || echo "")
    CLI_PORT=$(awk -F'"' '/"cli_port"/{print $4}' "$STATE_FILE" 2>/dev/null || echo "")
    BTAI_PORT=$(awk -F'"' '/"btai_port"/{print $4}' "$STATE_FILE" 2>/dev/null || echo "")
    BTAI_MCP_PORT=$(awk -F'"' '/"btai_mcp_port"/{print $4}' "$STATE_FILE" 2>/dev/null || echo "")
    MCP_PORT=$(awk -F'"' '/"mcp_port"/{print $4}' "$STATE_FILE" 2>/dev/null || echo "")
    RECON_PORT=$(awk -F'"' '/"recon_port"/{print $4}' "$STATE_FILE" 2>/dev/null || echo "")
    LLM_PROVIDER=$(awk -F'"' '/"provider"/{print $4}' "$STATE_FILE" 2>/dev/null || echo "")
    if [[ -z "$LLM_PROVIDER" && -f "$CLI_DIR/.env" ]]; then
        LLM_PROVIDER=$(awk -F= '/^PROVIDER=/{print $2; exit}' "$CLI_DIR/.env" 2>/dev/null || echo "")
    fi
    [[ -z "$LLM_PROVIDER" ]] && LLM_PROVIDER="openrouter"
    
    # Load MCP enabled states (handle both boolean and string)
    local mcp_cli mcp_recon mcp_kali
    mcp_cli=$(grep -o '"mcp_cli_enabled": [^,}]*' "$STATE_FILE" 2>/dev/null | grep -oE '(true|false)')
    mcp_recon=$(grep -o '"mcp_recon_enabled": [^,}]*' "$STATE_FILE" 2>/dev/null | grep -oE '(true|false)')
    mcp_kali=$(grep -o '"mcp_kali_enabled": [^,}]*' "$STATE_FILE" 2>/dev/null | grep -oE '(true|false)')
    
    [[ "$mcp_cli" == "true" ]] && MCP_CLI_ENABLED=true || MCP_CLI_ENABLED=false
    [[ "$mcp_recon" == "true" ]] && MCP_RECON_ENABLED=true || MCP_RECON_ENABLED=false
    [[ "$mcp_kali" == "true" ]] && MCP_KALI_ENABLED=true || MCP_KALI_ENABLED=false

    # Load explicit install flags; fallback for legacy state files.
    local install_web install_cli install_btai
    install_web=$(grep -o '"install_web": [^,}]*' "$STATE_FILE" 2>/dev/null | grep -oE '(true|false)')
    install_cli=$(grep -o '"install_cli": [^,}]*' "$STATE_FILE" 2>/dev/null | grep -oE '(true|false)')
    install_btai=$(grep -o '"install_btai": [^,}]*' "$STATE_FILE" 2>/dev/null | grep -oE '(true|false)')
    if [[ -n "$install_web" || -n "$install_cli" ]]; then
        [[ "$install_web" == "true" ]] && INSTALL_WEB=true || INSTALL_WEB=false
        [[ "$install_cli" == "true" ]] && INSTALL_CLI=true || INSTALL_CLI=false
        [[ "$install_btai" == "true" ]] && INSTALL_BTAI=true || INSTALL_BTAI=false
    else
        INSTALL_WEB=false
        INSTALL_CLI=false
        [[ "$DEPLOY_MODE" == "web" || "$DEPLOY_MODE" == "full" || "$DEPLOY_MODE" == "custom" || "$DEPLOY_MODE" == "recon" ]] && INSTALL_WEB=true
        [[ "$DEPLOY_MODE" == "cli" || "$DEPLOY_MODE" == "full" ]] && INSTALL_CLI=true
        INSTALL_BTAI=false
    fi

    # The CLI installer can reconfigure a standalone install independently.
    # Read its validated profile without executing configuration as shell code.
    if $CLI_MANAGED && [[ -f "$CLI_DIR/.bugtrace-install.env" ]]; then
        local cli_interface cli_runtime cli_global
        cli_interface=$(awk -F= '$1=="INTERFACE" {print $2}' "$CLI_DIR/.bugtrace-install.env")
        cli_runtime=$(awk -F= '$1=="RUNTIME" {print $2}' "$CLI_DIR/.bugtrace-install.env")
        cli_global=$(awk -F= '$1=="GLOBAL" {print $2}' "$CLI_DIR/.bugtrace-install.env")
        case "$cli_interface/$cli_runtime" in
            tui/local|api/local|both/local|tui/docker|api/docker|both/docker)
                CLI_INTERFACE="$cli_interface" CLI_RUNTIME="$cli_runtime" CLI_PROFILE_SAVED=true
                [[ "$cli_global" == yes ]] && CLI_GLOBAL=yes || CLI_GLOBAL=no
                [[ "$CLI_INTERFACE" == tui ]] && MCP_CLI_ENABLED=false || MCP_CLI_ENABLED=true
                ;;
            *) error "Invalid saved CLI installation profile at $CLI_DIR/.bugtrace-install.env"; return 1 ;;
        esac
    fi

    # Older state files have no API fields.  Preserve their behavior until the
    # user runs a new deployment, instead of silently cloning a new service.
    [[ -z "$BTAI_PORT" ]] && BTAI_PORT=""
    [[ -z "$BTAI_MCP_PORT" ]] && BTAI_MCP_PORT=""
    return 0
}

cmd_status() {
    load_state || return 1
    if $CLI_MANAGED && { [[ "$CLI_RUNTIME" == local ]] || [[ "$CLI_INTERFACE" == tui ]]; }; then
        info "CLI: $CLI_INTERFACE / $CLI_RUNTIME — use ./launcher.sh tui or ./launcher.sh api as installed."
        return
    fi
    echo ""
    echo -e "${BOLD}BugTraceAI Status${NC}  (mode: ${CYAN}$DEPLOY_MODE${NC})"
    echo "──────────────────────────────────────────"

    check_for_updates

    # WEB Stack
    if [[ -n "$WEB_PORT" ]]; then
        echo -e "\n  ${BOLD}WEB Stack${NC} (port ${WEB_PORT})"
        for c in bugtraceai-web-db bugtraceai-web-backend bugtraceai-web-frontend; do
            _print_container_status "$c"
        done
    fi

    # CLI Stack
    if [[ -n "$CLI_PORT" ]]; then
        echo -e "\n  ${BOLD}CLI Stack${NC} (port ${CLI_PORT})"
        _print_container_status "bugtrace_api"
    fi

    if $INSTALL_BTAI; then
        echo -e "\n  ${BOLD}BugTraceAI-API${NC} (port ${BTAI_PORT})"
        _print_container_status "bugtrace-api"
    fi

    # MCP Agents
    if $MCP_CLI_ENABLED || $MCP_RECON_ENABLED || $MCP_KALI_ENABLED; then
        echo -e "\n  ${BOLD}MCP Agents${NC}"
        $MCP_CLI_ENABLED && _print_container_status "$(_core_mcp_existing_name)"
        $MCP_RECON_ENABLED && _print_container_status "reconftw-mcp"
        $MCP_KALI_ENABLED && _print_container_status "kali-mcp-server"
    fi

    echo ""

    # Endpoints
    echo -e "  ${BOLD}Endpoints:${NC}"
    [[ -n "$WEB_PORT" ]] && echo -e "    WEB:  ${CYAN}http://localhost:${WEB_PORT}${NC}"
    [[ -n "$CLI_PORT" ]] && echo -e "    CLI:  ${CYAN}http://localhost:${CLI_PORT}${NC}"
    [[ -n "$BTAI_PORT" ]] && echo -e "    BugTraceAI-API REST: ${CYAN}http://localhost:${BTAI_PORT}${NC}"
    $INSTALL_BTAI && [[ -n "$BTAI_MCP_PORT" ]] && echo -e "    BugTraceAI-API MCP:  ${CYAN}http://localhost:${BTAI_MCP_PORT}/mcp${NC}"
    $MCP_CLI_ENABLED && [[ -n "$MCP_PORT" ]] && echo -e "    BugTraceAI MCP: ${CYAN}http://localhost:${MCP_PORT}/sse${NC}"
    $MCP_RECON_ENABLED && [[ -n "$RECON_PORT" ]] && echo -e "    reconFTW MCP:   ${CYAN}http://localhost:${RECON_PORT}/sse${NC}"
    echo ""
}

_core_mcp_container_names() {
    printf '%s\n' "bugtrace_mcp" "bugtrace-mcp" "bugtrace-cli-mcp"
}

_core_mcp_container_name() {
    printf '%s' "bugtrace_mcp"
}

_docker_ps() {
    local output

    if output=$(docker ps "$@" 2>/dev/null); then
        printf '%s\n' "$output"
        return 0
    fi

    # Linux installs may run Compose through sudo while the current login is
    # still outside the docker group. Use cached sudo credentials without
    # prompting from status checks or other non-interactive callers.
    if ! $IS_MACOS && output=$(sudo -n docker ps "$@" 2>/dev/null); then
        printf '%s\n' "$output"
        return 0
    fi

    return 1
}

_core_mcp_existing_name() {
    local name existing_names
    existing_names=$(_docker_ps -a --format '{{.Names}}') || return 1
    while IFS= read -r name; do
        if grep -qx "$name" <<< "$existing_names"; then
            printf '%s' "$name"
            return 0
        fi
    done < <(_core_mcp_container_names)
    _core_mcp_container_name
}

_print_container_status() {
    local name=$1
    local status
    if ! status=$(_docker_ps -a --format '{{.Status}}' --filter "name=^${name}$"); then
        echo -e "    ${DIM}Docker access unavailable — run 'sudo -v' or add your user to the docker group${NC}"
        return 0
    fi
    status=$(head -1 <<< "$status")

    if [[ -z "$status" ]]; then
        echo -e "    ${DIM}$name — not found${NC}"
    elif echo "$status" | grep -q "Up"; then
        echo -e "    ${OK} $name — ${GREEN}running${NC} ($status)"
    else
        echo -e "    ${FAIL} $name — ${RED}stopped${NC} ($status)"
    fi
}

_managed_container_names() {
    docker ps -a --format '{{.Names}}' 2>/dev/null |
        grep -E '^(bugtrace-api|bugtrace_api|bugtrace_mcp|bugtrace-mcp|bugtrace-cli-mcp|bugtraceai-web-(frontend|backend|db)|bugtraceai-api-routes|kali-mcp-server|reconftw-mcp)$' |
        sort -u || true
}

cmd_start() {
    load_state || return 1
    if $CLI_MANAGED && { [[ "$CLI_RUNTIME" == local ]] || [[ "$CLI_INTERFACE" == tui ]]; }; then
        info "CLI: $CLI_INTERFACE / $CLI_RUNTIME — use ./launcher.sh tui or ./launcher.sh api as installed."
        return
    fi
    check_docker
    info "Starting services..."
    local ok=true
    local recon_ready=true

    if $INSTALL_BTAI && [[ -d "$BTAI_DIR" ]]; then
        patch_btai_compose
        _btai_compose up -d || { error "Failed to start BugTraceAI-API"; ok=false; }
    fi

    # Keep the same dependency order as a fresh deployment: CLI DNS must
    # exist before nginx in WEB starts.
    if [[ -d "$CLI_DIR" ]] && [[ -n "$CLI_PORT" ]]; then
        _cli_compose up -d || { error "Failed to start CLI service"; ok=false; }
    fi
    
    # Start WEB services
    if [[ -d "$WEB_DIR" ]] && [[ -n "$WEB_PORT" ]]; then
        _web_compose up -d || { error "Failed to start WEB services"; ok=false; }
    fi
    
    # Start optional WEB-owned agents with explicit profiles, one at a time.
    resolve_web_mcp_profiles
    if $MCP_RECON_ENABLED && ! ensure_recon_source; then
        error "Skipping selected reconFTW MCP profile because its build context is unavailable."
        recon_ready=false
        ok=false
    fi
    if [[ -d "$WEB_DIR" ]]; then
        if $MCP_RECON_ENABLED && $recon_ready; then
            _web_compose --profile recon up -d --build || { error "Failed to start reconFTW MCP"; ok=false; }
        fi
        if $MCP_KALI_ENABLED; then
            _web_compose --profile kali up -d || { error "Failed to start Kali toolbox"; ok=false; }
        fi
    fi
    
    if $ok; then
        success "Services started"
        return 0
    fi
    warn "Some services failed to start. Run: ./launcher.sh logs"
    return 1
}

cmd_stop() {
    load_state || return 1
    if $CLI_MANAGED && { [[ "$CLI_RUNTIME" == local ]] || [[ "$CLI_INTERFACE" == tui ]]; }; then
        info "CLI: $CLI_INTERFACE / $CLI_RUNTIME — use ./launcher.sh tui or ./launcher.sh api as installed."
        return
    fi
    check_docker
    info "Stopping services..."

    if $INSTALL_BTAI && [[ -d "$BTAI_DIR" ]]; then
        _btai_compose stop 2>/dev/null || true
    fi
    
    # Stop optional WEB-owned agents first.
    resolve_web_mcp_profiles
    if [[ -d "$WEB_DIR" ]] && (( ${#WEB_MCP_PROFILE_ARGS[@]} > 0 )); then
        _web_compose "${WEB_MCP_PROFILE_ARGS[@]}" stop 2>/dev/null || true
    fi
    
    # Stop CLI
    [[ -d "$CLI_DIR" ]] && [[ -n "$CLI_PORT" ]] && _cli_compose stop
    
    # Stop WEB
    [[ -d "$WEB_DIR" ]] && [[ -n "$WEB_PORT" ]] && _web_compose stop
    
    success "Services stopped"
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_logs() {
    load_state || return 1
    local target="${1:-}"

    if $CLI_MANAGED && [[ "$CLI_RUNTIME" == local ]]; then
        case "$target" in
            ""|cli|api|mcp) ;;
            *) error "This local installation has CLI logs only."; return 1 ;;
        esac
        local log_file
        for log_file in "$CLI_DIR/logs/execution.log" "$CLI_DIR/logs/bugtrace.jsonl" "$CLI_DIR/logs/errors.log"; do
            if [[ -f "$log_file" ]]; then
                tail -n 100 -f "$log_file"
                return $?
            fi
        done
        info "No local scanner logs yet. Start a scan with ./launcher.sh tui or ./launcher.sh api."
        return 0
    fi

    if [[ -z "$target" ]]; then
        if $INSTALL_WEB && $INSTALL_CLI; then
            echo ""
            echo "Specify which logs to view:"
            echo -e "  ${DIM}./launcher.sh logs web${NC}"
            echo -e "  ${DIM}./launcher.sh logs api${NC}"
            echo -e "  ${DIM}./launcher.sh logs cli${NC}"
            echo -e "  ${DIM}./launcher.sh logs mcp${NC}"
            echo ""
            exit 0
        elif $INSTALL_CLI; then
            target="cli"
        elif $INSTALL_WEB; then
            target="web"
        elif $INSTALL_BTAI; then
            target="api"
        else
            error "Nothing installed to show logs for."
            exit 1
        fi
    fi

    case "$target" in
        api|btai)
            if [[ -d "$BTAI_DIR" ]]; then
                _btai_compose logs -f --tail=100
            else
                error "BugTraceAI-API not installed"
            fi
            ;;
        web)
            if [[ -d "$WEB_DIR" ]]; then
                _web_compose logs -f --tail=100
            else
                error "WEB not installed"
            fi
            ;;
        cli)
            if [[ -d "$CLI_DIR" ]]; then
                _cli_compose logs -f --tail=100
            else
                error "CLI not installed"
            fi
            ;;
        mcp)
            if $MCP_CLI_ENABLED && [[ -d "$CLI_DIR" ]]; then
                _cli_compose logs -f --tail=100 mcp
            else
                error "MCP not installed"
            fi
            ;;
        *)
            error "Unknown target: $target (use 'web', 'api', 'cli', or 'mcp')"
            exit 1
            ;;
    esac
}

# Source and image updates are prepared as one pinned, recoverable transaction.
cmd_update() {
    load_state || return 1
    local action=update
    case "${1:-}" in
        '') [[ $# -eq 0 ]] || { error 'Unexpected update arguments.'; return 2; } ;;
        --plan|--check) action=preview; shift ;;
        --recover) action=recover; shift ;;
        *) error 'Usage: ./launcher.sh update [--plan|--recover]'; return 2 ;;
    esac
    [[ $# -eq 0 ]] || { error 'Unexpected update arguments.'; return 2; }
    if [[ "$action" != preview ]] && { ! $CLI_MANAGED || [[ "$CLI_RUNTIME" == docker ]]; }; then
        check_docker || return 1
    fi
    BUGTRACEAI_RELEASE_COMPOSE="${COMPOSE_CMD:-docker compose}" \
        python3 "$SCRIPT_DIR/release_manager.py" "$action" --install-dir "$INSTALL_DIR" --launcher "$SCRIPT_DIR/launcher.sh"
}

# Patch .env.docker in-place: fix config values without regenerating passwords.
_patch_env_docker() {
    local envfile="$WEB_DIR/.env.docker"
    [[ ! -f "$envfile" ]] && return

    # In full mode, VITE_CLI_API_URL must be /cli-api (nginx proxy) for remote access
    if [[ "$DEPLOY_MODE" == "full" ]]; then
        if grep -q 'VITE_CLI_API_URL=http://localhost' "$envfile" 2>/dev/null; then
            sed_inplace 's|VITE_CLI_API_URL=http://localhost[^[:space:]]*|VITE_CLI_API_URL=/cli-api|' "$envfile"
            echo -e "    ${OK} Fixed VITE_CLI_API_URL → /cli-api"
        fi
    fi
}

cmd_uninstall() {
    load_state || return 1
    if $CLI_MANAGED && [[ "$CLI_RUNTIME" == local ]]; then
        info "Local checkout and reports are kept at $CLI_DIR. Remove its virtual environment manually if no longer needed."
        return
    fi
    check_docker
    echo ""
    warn "This will remove all BugTraceAI containers, volumes, and data."
    echo -e "  ${DIM}Install directory: $INSTALL_DIR${NC}"
    echo ""
    echo -en "${YELLOW}Are you sure? [y/N]: ${NC}"
    read -r confirm
    [[ "$(to_lower "$confirm")" != "y" ]] && { info "Cancelled."; exit 0; }

    _teardown_all || { error "Uninstall stopped before deleting installation files."; return 1; }

    success "BugTraceAI uninstalled."
}

# Tear down all services and remove install directory
_teardown_all() {
    local failed=false remaining
    _assert_safe_install_dir "$INSTALL_DIR" require_marker || return 1
    if [[ -d "$BTAI_DIR" && -f "$BTAI_DIR/docker-compose.yml" ]]; then
        step "Stopping BugTraceAI-API..."
        (cd "$BTAI_DIR" && $COMPOSE_CMD down -v --remove-orphans) || failed=true
    fi
    if [[ -d "$CLI_DIR" && -f "$CLI_DIR/docker-compose.yml" ]]; then
        step "Stopping CLI..."
        (cd "$CLI_DIR" && $COMPOSE_CMD down -v --remove-orphans) || failed=true
    fi
    if [[ -d "$WEB_DIR" && -f "$WEB_DIR/docker-compose.yml" ]]; then
        step "Stopping WEB..."
        # Enable both optional profiles so their services are included in down.
        (cd "$WEB_DIR" && $COMPOSE_CMD --env-file .env.docker --profile recon --profile kali down -v --remove-orphans) || failed=true
    fi
    remaining="$(_managed_container_names)"
    if [[ -n "$remaining" ]]; then
        error "Managed BugTraceAI containers remain after teardown; installation files were kept: $remaining"
        failed=true
    fi
    if $failed; then
        error "One or more Compose stacks could not be stopped; installation files were kept."
        return 1
    fi
    step "Removing $INSTALL_DIR..."
    _assert_safe_install_dir "$INSTALL_DIR" require_marker
    rm -rf "$INSTALL_DIR"
    return $?
}

# ── Docker Check ─────────────────────────────────────────────────────────────

check_docker() {
    local may_install="${1:-}"

    if $IS_MACOS; then
        ensure_macos_docker_path
        if ! docker info &>/dev/null 2>&1; then
            if ! ensure_macos_runtime_ready; then
                error "Docker runtime is not ready."
                exit 1
            fi
        fi
    elif [[ "$may_install" == "install" ]]; then
        if ! ensure_linux_docker_engine; then
            error "Docker Engine is not ready."
            echo -e "  Install Docker: ${CYAN}https://docs.docker.com/engine/install/${NC}"
            exit 1
        fi
    fi

    if ! command -v docker &>/dev/null; then
        error "Docker not found."
        if $IS_MACOS; then
            echo -e "  Install runtime with launcher helper (recommended): rerun ./launcher.sh"
            echo -e "  Or install manually:"
            echo -e "    - Docker Desktop: ${CYAN}https://docs.docker.com/desktop/install/mac-install/${NC}"
            echo -e "    - Colima stack:   ${DIM}brew install docker docker-compose colima qemu lima-additional-guestagents${NC}"
        else
            echo -e "  Install Docker: ${CYAN}https://docs.docker.com/engine/install/${NC}"
        fi
        exit 1
    fi

    if ! docker info &>/dev/null 2>&1; then
        if $IS_MACOS; then
            error "Docker is not running."
            echo -e "  ${DIM}Open Docker Desktop and make sure it is running.${NC}"
            exit 1
        fi

        # Check if Docker daemon is running at all
        if ! sudo docker info &>/dev/null 2>&1; then
            error "Docker daemon is not running."
            echo -e "  ${DIM}Start Docker first: sudo systemctl start docker${NC}"
            exit 1
        fi

        # Daemon runs but current user lacks permission — fix it
        info "Adding $USER to the docker group..."
        sudo usermod -aG docker "$USER"
        info "Applying new group, restarting launcher..."
        local reexec_cmd
        printf -v reexec_cmd '%q ' "$0" "${ORIG_ARGS[@]}"
        exec sg docker "$reexec_cmd"
    fi

    detect_compose_cmd
}

# An explicit local path overrides saved routing; otherwise honor the installation profile.
_require_tui_cli_version() {
    local checkout="$1"
    local cli_version_pattern='^([0-9]+)\.'
    if [[ -f "$checkout/VERSION" ]]; then
        local cli_version
        cli_version=$(tr -d '[:space:]' < "$checkout/VERSION")
        if [[ "$cli_version" =~ $cli_version_pattern ]] && (( ${BASH_REMATCH[1]} < 4 )); then
            error "Legacy CLI $cli_version cannot open this workspace. Use the CLI 4.x refactor checkout."
            return 1
        fi
    fi
    return 0
}

_run_local_tui() {
    local workspace="$1"
    shift
    if [[ ! -x "$workspace/bugtraceai-cli" ]]; then
        error "CLI workspace not found or not executable: $workspace/bugtraceai-cli"
        return 1
    fi
    _require_tui_cli_version "$workspace" || return 1
    "$workspace/bugtraceai-cli" tui "$@"
}

cmd_tui() {
    local workspace="${BUGTRACEAI_CLI_PATH:-}"
    if [[ -n "$workspace" ]]; then
        _run_local_tui "$workspace" "$@"
        return $?
    fi
    if [[ -f "$STATE_FILE" ]]; then load_state || return 1; fi
    if { $CLI_MANAGED || $CLI_PROFILE_SAVED; } && [[ "$CLI_INTERFACE" == api ]]; then
        error "This installation selected API only. Run the installer to add TUI."
        return 1
    fi
    if { $CLI_MANAGED || $CLI_PROFILE_SAVED; } && [[ "$CLI_RUNTIME" == docker ]]; then
        _require_tui_cli_version "$CLI_DIR" || return 1
        check_docker
        if [[ "$CLI_INTERFACE" == tui ]]; then
            _cli_compose run --rm -e "TERM=${TERM:-xterm-256color}" scanner tui "$@"
        else
            _cli_compose exec -e "TERM=${TERM:-xterm-256color}" api python3 -m bugtrace tui "$@"
        fi
        return $?
    fi
    if $CLI_MANAGED && [[ "$CLI_RUNTIME" == local ]]; then
        workspace="$CLI_DIR"
    elif [[ -f "$SCRIPT_DIR/../BugTraceAI-CLI-refactor/bugtraceai-cli" ]]; then
        workspace="$SCRIPT_DIR/../BugTraceAI-CLI-refactor"
    fi
    if [[ -n "$workspace" ]]; then
        _run_local_tui "$workspace" "$@"
        return $?
    fi
    if [[ ! -t 0 || ! -t 1 ]]; then
        error "The terminal workspace needs an interactive terminal. Run ./launcher.sh tui in your terminal."
        return 1
    fi
    load_state || return 1
    if [[ ! -f "$CLI_DIR/docker-compose.yml" ]]; then
        error "CLI is not installed. Install a CLI 4.x checkout or set BUGTRACEAI_CLI_PATH."
        return 1
    fi
    check_docker
    _cli_compose exec -e "TERM=${TERM:-xterm-256color}" api python3 -m bugtrace tui "$@"
}

cmd_api() {
    load_state || return 1
    if [[ "$CLI_INTERFACE" == tui ]]; then error "This installation selected TUI only."; return 1; fi
    if $CLI_MANAGED && [[ "$CLI_RUNTIME" == local ]]; then
        "$CLI_DIR/bugtraceai-cli" serve "$@"
    else
        check_docker
        _cli_compose up -d api mcp
    fi
}

cmd_cli_setup() {
    if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --reuse ) ]]; then
        error "Usage: ./launcher.sh setup-cli [--reuse]"
        return 1
    fi
    CLI_SETUP_CHECKOUT=""
    if [[ -f "$STATE_FILE" ]]; then
        load_state || return 1
        if $INSTALL_WEB || $INSTALL_BTAI; then
            error "This installation includes WEB/API. Use a separate BUGTRACEAI_DIR for standalone CLI setup; the existing platform state was kept."
            return 1
        fi
        if $CLI_MANAGED; then CLI_SETUP_CHECKOUT="$CLI_DIR"; fi
    fi
    if [[ "${1:-}" == --reuse ]]; then
        load_state || return 1
        run_cli_installer --reuse
        return $?
    fi
    DEPLOY_MODE=cli INSTALL_CLI=true INSTALL_WEB=false INSTALL_BTAI=false
    if [[ -n "$INSTALL_PROFILE" ]]; then
        apply_install_profile "$INSTALL_PROFILE" || return 1
        [[ "$DEPLOY_MODE" == cli ]] || { error "Use ./launcher.sh install for platform profiles."; return 1; }
    fi
    wizard_cli_preferences || return 1
    deploy_cli_only
}

parse_profile_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile|--runtime|--global)
                [[ $# -ge 2 ]] || { error "Missing value for $1"; return 1; }
                case "$1" in
                    --profile) INSTALL_PROFILE="$2" ;;
                    --runtime) REQUESTED_RUNTIME="$2" ;;
                    --global) REQUESTED_GLOBAL="$2" ;;
                esac
                shift 2 ;;
            *) error "Unknown install option: $1"; return 1 ;;
        esac
    done
    case "$REQUESTED_RUNTIME" in ''|local|docker) ;; *) error "Runtime must be local or docker."; return 1 ;; esac
    case "$REQUESTED_GLOBAL" in ''|yes|no) ;; *) error "Global choice must be yes or no."; return 1 ;; esac
    if [[ -n "$INSTALL_PROFILE" ]]; then
        apply_install_profile "$INSTALL_PROFILE" || return 1
        [[ "$REQUESTED_RUNTIME" != local || "$DEPLOY_MODE" == cli ]] || { error "WEB and API-target profiles currently require Docker."; return 1; }
        [[ "$REQUESTED_GLOBAL" != yes || "$CLI_INTERFACE" != api ]] || { error "Global btai requires a terminal workspace."; return 1; }
    fi
}

cmd_install_plan() {
    local BUGTRACEAI_INSTALL_LOG="" INSTALL_LOG_FILE=""
    parse_profile_options "$@" || return 1
    [[ -n "$INSTALL_PROFILE" ]] || { error "Choose --profile terminal|web|full|server|terminal-server|api."; return 1; }
    CLI_RUNTIME="${REQUESTED_RUNTIME:-docker}"
    if [[ -z "$REQUESTED_RUNTIME" && "$DEPLOY_MODE" == cli ]]; then
        CLI_RUNTIME="choose local Python or Docker during installation"
    fi
    CLI_GLOBAL="${REQUESTED_GLOBAL:-no}"
    if [[ -z "$REQUESTED_GLOBAL" && "$CLI_INTERFACE" != api ]]; then
        CLI_GLOBAL="choose during installation"
    fi
    show_selected_components
    info "Install directory: $INSTALL_DIR"
    info "Preview only: no downloads, package installation or services started."
}

cmd_repair() {
    load_state || return 1
    if $CLI_MANAGED; then
        run_cli_installer --reuse || return 1
    else
        check_docker install
        # Preserve provider, ports, database credentials and selected components.
        # Missing configuration needs guided setup instead of guessed defaults.
        if { $INSTALL_WEB && [[ ! -f "$WEB_DIR/.env.docker" ]]; } ||
           { $INSTALL_BTAI && [[ ! -f "$BTAI_DIR/.env" ]]; } ||
           { $INSTALL_CLI && [[ ! -f "$CLI_DIR/.env" ]]; }; then
            error "Saved configuration is missing. Use the AI repair assistant or restore it before repair."
            return 1
        fi
        patch_compose || return 1
        start_services || return 1
        health_checks || return 1
    fi
    success "Repaired the saved installation; component choices and configuration kept."
}

# ── Help ─────────────────────────────────────────────────────────────────────

show_help() {
    echo ""
    echo -e "${BOLD}BugTraceAI Launcher v${VERSION}${NC}"
    echo ""
    echo "Usage: ./launcher.sh [command]"
    echo ""
    echo "Commands:"
    echo "  (no args)       Universal installation wizard"
    echo "  install         Same wizard; accepts --profile, --runtime and --global"
    echo "  plan            Preview --profile without installing anything"
    echo "  api             Start the installed CLI API"
    echo "  setup-cli       Choose interface and runtime for a standalone CLI"
    echo "  tui [--demo]    Open the terminal workspace (real scans by default)"
    echo "  status          Show service status"
    echo "  start           Start all services"
    echo "  stop            Stop all services"
    echo "  restart         Restart all services"
    echo "  logs [web|api|cli|mcp] View logs"
    echo "  update          Apply and verify the tested release combination"
    echo "  update --plan   Preview installed and target component versions"
    echo "  update --recover Recover an interrupted update from its journal"
    echo "  repair          Rebuild/verify the saved selection without pulling updates"
    echo "  uninstall       Remove everything"
    echo ""
    echo "Profiles: terminal | web | full | server | terminal-server | api"
    echo "Example: ./launcher.sh install --profile terminal --runtime local --global yes"
    echo "Preview: ./launcher.sh plan --profile full"
    echo "Local checkout override: BUGTRACEAI_CLI_PATH=/path/to/CLI ./launcher.sh tui"
    echo "Install source overrides: BUGTRACEAI_CLI_REPO / BUGTRACEAI_CLI_BRANCH"
    echo "Docs: https://docs.bugtraceai.com"

    check_for_updates
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    ORIG_ARGS=("$@")
    if [[ "${1:-}" == plan ]]; then shift; cmd_install_plan "$@"; return $?; fi
    local update_plan_option_pattern='^--(plan|check)$'
    if [[ "${1:-}" == update && "${2:-}" =~ $update_plan_option_pattern ]]; then shift; cmd_update "$@"; return $?; fi
    _init_install_log
    _log_event INFO "command: ${1:-wizard}"
    case "${1:-}" in
        "")         run_wizard ;;
        install)    shift; parse_profile_options "$@" && run_wizard ;;
        tui)        shift; cmd_tui "$@" ;;
        api)        shift; cmd_api "$@" ;;
        setup-cli)  shift; cmd_cli_setup "$@" ;;
        status)     cmd_status ;;
        start)      cmd_start ;;
        stop)       cmd_stop ;;
        restart)    cmd_restart ;;
        logs)       cmd_logs "${2:-}" ;;
        update)     shift; cmd_update "$@" ;;
        repair)     cmd_repair ;;
        uninstall)  cmd_uninstall ;;
        help|--help|-h) show_help ;;
        *)
            error "Unknown command: $1"
            echo "Run: ./launcher.sh help"
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
