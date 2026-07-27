#!/bin/bash
#
# BugTraceAI Launcher
# One-command deployment for the BugTraceAI security platform
#
# Usage: ./launcher.sh [command]
#
# Commands:
#   (none)        Interactive setup wizard
#   status        Show service status
#   start         Start all services
#   stop          Stop all services
#   restart       Restart all services
#   logs [web|cli|mcp] View logs
#   update        Pull latest & rebuild
#   uninstall     Remove everything
#

# ── Constants ────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/VERSION"
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || printf '2.8.6')"
# Fail loudly if HOME is unset/empty rather than silently deriving "/bugtraceai"
# (which would later flow into `rm -rf "$INSTALL_DIR"`).
: "${HOME:?HOME must be set}"
INSTALL_DIR="${BUGTRACEAI_DIR:-$HOME/bugtraceai}"
STATE_FILE="$INSTALL_DIR/.launcher-state"
WEB_DIR="$INSTALL_DIR/BugTraceAI-WEB"
CLI_DIR="$INSTALL_DIR/BugTraceAI-CLI"
RECON_DIR="$INSTALL_DIR/reconftw-mcp"
WEB_REPO="https://github.com/BugTraceAI/BugTraceAI-WEB.git"
CLI_REPO="https://github.com/BugTraceAI/BugTraceAI-CLI.git"
RECON_REPO="https://github.com/BugTraceAI/reconftw-mcp.git"

# GitHub repos for version checks
GITHUB_API_BASE="https://api.github.com/repos/BugTraceAI"
REPOS_CLI="BugTraceAI-CLI"
REPOS_WEB="BugTraceAI-WEB"
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
WEB_PORT=""
CLI_PORT=""
MCP_PORT=""
API_KEY=""
API_KEY_ENV_VAR=""
LLM_PROVIDER="openrouter"
MENU_SELECTION=0

# MCP Selection state
INSTALL_WEB=false
INSTALL_CLI=false
MCP_CLI_ENABLED=false
MCP_RECON_ENABLED=false
MCP_KALI_ENABLED=false
RECON_PORT=""
KALI_PORT=""
SELECTED_INDICES=()

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

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
# WARN/ERROR go to stderr so they never pollute a function's stdout that a
# caller captures via $(...) — e.g. find_free_port feeding POSTGRES_PORT.
warn()    { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
step()    { echo -e "  ${ARROW} $1"; }

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
    clear
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
}

# ── Utility Functions ────────────────────────────────────────────────────────

port_available() {
    local port=$1
    # Check if port was already selected in THIS session
    [[ "$port" == "$WEB_PORT" ]] && return 1
    [[ "$port" == "$CLI_PORT" ]] && return 1
    [[ "$port" == "$MCP_PORT" ]] && return 1
    [[ "$port" == "$RECON_PORT" ]] && return 1
    [[ "$port" == "$KALI_PORT" ]] && return 1

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
    in_recon && /^  [^[:space:]]/ {
        if (!has_platform) print "    platform: linux/amd64"
        in_recon=0
    }
    in_recon && /^[[:space:]]+platform:[[:space:]]*linux\/amd64[[:space:]]*$/ { has_platform=1 }
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
    BEGIN { in_recon=0; has_auto=0; inserted=0 }
    /^  reconftw-mcp:[[:space:]]*$/ { in_recon=1; has_auto=0; inserted=0; print; next }
    in_recon && /^[[:space:]]+- RECONFTW_AUTO_INSTALL=/ { has_auto=1 }
    in_recon && /^[[:space:]]+- MCP_PORT=8002[[:space:]]*$/ {
        print
        if (!has_auto && !inserted) {
            print "      - RECONFTW_AUTO_INSTALL=false"
            inserted=1
        }
        next
    }
    in_recon && /^  [^[:space:]]/ {
        if (!has_auto && !inserted) print "      - RECONFTW_AUTO_INSTALL=false"
        in_recon=0
    }
    { print }
    END {
        if (in_recon && !has_auto && !inserted) print "      - RECONFTW_AUTO_INSTALL=false"
    }
    ' "$compose_file" > "$tmp_file"

    mv "$tmp_file" "$compose_file"
}

ensure_kali_startup_command() {
    local compose_file=$1
    local tmp_file
    tmp_file="$(mktemp)"

    awk '
    BEGIN { in_kali=0; in_cmd=0 }
    /^  kali-mcp:[[:space:]]*$/ { in_kali=1; print; next }
    in_kali && /^  [^[:space:]]/ { in_kali=0; in_cmd=0 }
    in_kali && /^[[:space:]]+command:[[:space:]]*>[[:space:]]*$/ {
        in_cmd=1
        print "    command: >"
        print "      bash -lc \"set -e; echo '\''Waiting for network initialization...'\''; sleep 5; apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y nmap ffuf nuclei sqlmap dirb gobuster nikto hydra john hashcat curl wget netcat-openbsd python3 python3-pip git vim; command -v nmap hydra python3 >/dev/null; echo '\''Kali MCP Server ready!'\''; tail -f /dev/null\""
        next
    }
    in_cmd {
        if (in_kali && /^[[:space:]]+(extra_hosts:|restart:|networks:|ports:|volumes:|environment:|cap_add:|security_opt:|profiles:|container_name:|image:)/) {
            in_cmd=0
            print
        }
        next
    }
    { print }
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
    "Kali Linux: Full penetration testing toolkit (nmap, nuclei, sqlmap, ffuf, etc.) - 3GB+ download"
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
    [[ "$version" =~ ^[0-9]+([.][0-9]+){0,3}([-+][0-9A-Za-z.-]+)?$ ]]
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

    # Check CLI version (read from deployed repo if available)
    if [[ -d "$CLI_DIR" ]]; then
        local cli_ver=""
        cli_ver=$(read_cli_version)
        if [[ -n "$cli_ver" ]]; then
            local latest_cli
            latest_cli=$(_get_latest_version "$REPOS_CLI")
            if _version_is_newer "$cli_ver" "$latest_cli"; then
                has_update=true
                lines+=("     CLI:      ${cli_ver} → ${latest_cli}")
            fi
        fi
    fi

    # Check WEB version (read from package.json if available)
    if [[ -d "$WEB_DIR" ]]; then
        local web_ver=""
        web_ver=$(read_web_version)
        if [[ -n "$web_ver" ]]; then
            local latest_web
            latest_web=$(_get_latest_version "$REPOS_WEB")
            if _version_is_newer "$web_ver" "$latest_web"; then
                has_update=true
                lines+=("     WEB:      ${web_ver} → ${latest_web}")
            fi
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
            recon_note="     Recon:    latest release ${latest_recon} (run update to refresh)"
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
    info "Starting AI Setup & Repair Assistant (provider selected at startup)..."
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

wizard_select_components() {
    # Step 1: Select Base Installation Mode
    select_option "What would you like to install?" \
        "BugTraceAI Web + CLI (Full Platform - Recommended)" \
        "Solo BugTraceAI CLI (Engine Only - Standalone)" \
        "Solo BugTraceAI WEB (UI Only)"

    INSTALL_WEB=false
    INSTALL_CLI=false
    MCP_CLI_ENABLED=false
    MCP_RECON_ENABLED=false
    MCP_KALI_ENABLED=false

    case $MENU_SELECTION in
        0) # Web + CLI
            INSTALL_WEB=true
            INSTALL_CLI=true
            MCP_CLI_ENABLED=true
            DEPLOY_MODE="full"
            ;;
        1) # Solo CLI
            INSTALL_CLI=true
            DEPLOY_MODE="cli"
            ;;
        2) # Solo WEB
            INSTALL_WEB=true
            DEPLOY_MODE="web"
            ;;
    esac

    # Step 2: Select Extras (only for Web+CLI or Solo WEB)
    if $INSTALL_WEB; then
        select_option "Would you like to add any additional AI Agents (MCPs) for the Chat?" \
            "Add BOTH (Full Pack: Kali + reconFTW)" \
            "Add Kali Linux MCP (Full Pentest Toolkit - 3GB+)" \
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

    echo ""
    echo -e "${BOLD}Selected Components:${NC}"
    $INSTALL_WEB && echo -e "  ${OK} WEB Dashboard"
    $INSTALL_CLI && echo -e "  ${OK} CLI Scanner"
    $MCP_CLI_ENABLED && echo -e "  ${OK} BugTraceAI MCP (Core Agent)"
    $MCP_RECON_ENABLED && echo -e "  ${OK} reconFTW MCP (by @six2dez)"
    $MCP_KALI_ENABLED && echo -e "  ${OK} Kali Linux MCP"

    echo ""
    success "Configuration set to $DEPLOY_MODE mode"
    echo ""
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
            error "API key cannot be empty"
            continue
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

    # MCP ports based on selection
    if $MCP_CLI_ENABLED; then
        propose_port "BugTraceAI MCP port" 8001 MCP_PORT
    fi

    if $MCP_RECON_ENABLED; then
        propose_port "reconFTW MCP port" 8002 RECON_PORT
    fi

    if $MCP_KALI_ENABLED; then
        propose_port "Kali MCP port" 8003 KALI_PORT
    fi

    echo ""
    success "Ports configured"
    echo ""
}

wizard_show_summary() {
    echo ""
    echo -e "${BOLD}─── Configuration Summary ───${NC}"
    echo ""
    echo -e "  Mode:       ${CYAN}$DEPLOY_MODE${NC}"
    echo -e "  Provider:   ${CYAN}$LLM_PROVIDER${NC}"

    # Show endpoints based on mode and selections
    if [[ -n "$WEB_PORT" ]]; then
        echo -e "  WEB:        ${CYAN}http://localhost:$WEB_PORT${NC}"
    fi
    if [[ -n "$CLI_PORT" ]]; then
        echo -e "  CLI API:    ${CYAN}http://localhost:$CLI_PORT${NC}"
    fi

    # Show MCP agents
    local has_mcps=false
    $MCP_CLI_ENABLED && has_mcps=true
    $MCP_RECON_ENABLED && has_mcps=true
    $MCP_KALI_ENABLED && has_mcps=true

    if $has_mcps; then
        echo ""
        echo -e "  ${BOLD}MCP Agents:${NC}"
        $MCP_CLI_ENABLED && echo -e "    ${OK} BugTraceAI: ${CYAN}http://localhost:${MCP_PORT}/sse${NC}"
        $MCP_RECON_ENABLED && echo -e "    ${OK} reconFTW:   ${CYAN}http://localhost:${RECON_PORT}/sse${NC}"
        $MCP_KALI_ENABLED && echo -e "    ${OK} Kali:      ${CYAN}http://localhost:${KALI_PORT}${NC}"
    fi

    echo -e "  API Key:    ${DIM}...${API_KEY: -4} (${API_KEY_ENV_VAR})${NC}"
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

run_wizard() {
    # Restore stdin if piped (e.g. curl | bash)
    if [ ! -t 0 ] && [ -c /dev/tty ]; then
        exec </dev/tty 2>/dev/null || true
    fi

    show_banner
    offer_installer_mode
    cleanup_legacy_version_cache_dir
    check_docker

    # Detect existing BugTraceAI containers (running OR stopped — both cause name conflicts)
    local existing_btai
    existing_btai=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^(bugtrace[-_]api$|bugtrace[-_]mcp$|bugtrace-cli-mcp$|bugtraceai-web-(frontend|backend|db)$|bugtraceai-api-routes$|kali-mcp-server$|reconftw-mcp$)' || true)
    if [[ -n "$existing_btai" ]]; then
        echo ""
        warn "Existing BugTraceAI containers detected:"
        echo "$existing_btai" | while IFS= read -r cname; do
            local cstatus
            cstatus=$(docker ps -a --format '{{.Status}}' --filter "name=^${cname}$" 2>/dev/null | head -1)
            echo -e "    ${CYAN}•${NC} ${cname}  ${DIM}(${cstatus})${NC}"
        done
        echo ""
        select_option "These containers may cause conflicts. What would you like to do?" \
            "Remove them and continue with fresh install" \
            "Continue anyway (may cause name conflicts)" \
            "Cancel"

        case $MENU_SELECTION in
            0)
                info "Removing existing BugTraceAI containers and volumes..."
                echo "$existing_btai" | xargs -r docker rm -f 2>/dev/null || true
                # Remove associated Docker volumes discovered from real Docker state.
                local btai_volumes
                btai_volumes=$(
                    {
                        docker volume ls --filter "name=bugtraceai" --format '{{.Name}}' 2>/dev/null
                        docker volume ls --filter "name=bugtrace_" --format '{{.Name}}' 2>/dev/null
                    } | sort -u
                )
                if [[ -n "$btai_volumes" ]]; then
                    if printf '%s\n' "$btai_volumes" | xargs -r docker volume rm -f >/dev/null 2>&1; then
                        success "Containers and volumes removed."
                    else
                        warn "Containers removed, but some BugTraceAI volumes could not be removed."
                    fi
                else
                    success "Containers removed (no BugTraceAI volumes found)."
                fi
                ;;
            1)
                warn "Continuing — name conflicts may occur."
                ;;
            2)
                info "Cancelled."
                exit 0
                ;;
        esac
        echo ""
    fi

    # Detect existing installation
    if [[ -f "$STATE_FILE" ]]; then
        warn "BugTraceAI is already installed at $INSTALL_DIR"
        echo ""
        select_option "What would you like to do?" \
            "Reinstall (wipe and start fresh)" \
            "Update (pull latest and rebuild)" \
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
    check_deps
    wizard_select_components
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

    clone_repos
    generate_env
    patch_compose
    start_services
    health_checks
    save_state
    show_success
}

clone_repos() {
    # Clone WEB repo if needed
    if $INSTALL_WEB; then
        if [[ -n "$WEB_PORT" ]]; then
            if [[ -d "$WEB_DIR/.git" ]]; then
                step "Updating BugTraceAI-WEB..."
                if ! (cd "$WEB_DIR" && git pull --quiet) 2>/dev/null; then
                    warn "Failed to update WEB repo (will use existing version)"
                fi
            else
                step "Cloning BugTraceAI-WEB..."
                # Clean partial directory from failed previous attempt
                [[ -d "$WEB_DIR" && ! -d "$WEB_DIR/.git" ]] && rm -rf "$WEB_DIR"
                if ! git clone --depth 1 "$WEB_REPO" "$WEB_DIR"; then
                    error "Failed to clone BugTraceAI-WEB from $WEB_REPO"
                    error "Check your internet connection and try again."
                    exit 1
                fi
            fi
            echo -e "    ${OK} BugTraceAI-WEB"
        fi
    fi

    # Clone CLI repo if needed
    if $INSTALL_CLI || $MCP_CLI_ENABLED; then
        if [[ -d "$CLI_DIR/.git" ]]; then
            step "Updating BugTraceAI-CLI..."
            if ! (cd "$CLI_DIR" && git pull --quiet) 2>/dev/null; then
                warn "Failed to update CLI repo (will use existing version)"
            fi
        else
            step "Cloning BugTraceAI-CLI..."
            # Clean partial directory from failed previous attempt
            [[ -d "$CLI_DIR" && ! -d "$CLI_DIR/.git" ]] && rm -rf "$CLI_DIR"
            if ! git clone --depth 1 "$CLI_REPO" "$CLI_DIR"; then
                error "Failed to clone BugTraceAI-CLI from $CLI_REPO"
                error "Check your internet connection and try again."
                exit 1
            fi
        fi
        echo -e "    ${OK} BugTraceAI-CLI"
    fi

    # Clone Recon repo if needed
    if [[ "$DEPLOY_MODE" == "recon" || "$DEPLOY_MODE" == "custom" ]] || $MCP_RECON_ENABLED; then
        if [[ -d "$RECON_DIR/.git" ]]; then
            step "Updating reconftw-mcp..."
            if ! (cd "$RECON_DIR" && git pull --quiet) 2>/dev/null; then
                warn "Failed to update Recon repo (will use existing version)"
            fi
        else
            step "Cloning reconftw-mcp..."
            [[ -d "$RECON_DIR" && ! -d "$RECON_DIR/.git" ]] && rm -rf "$RECON_DIR"
            if ! git clone --depth 1 "$RECON_REPO" "$RECON_DIR"; then
                error "Failed to clone reconftw-mcp from $RECON_REPO"
                exit 1
            fi
        fi
        patch_recon_dockerfile_venv
        echo -e "    ${OK} reconftw-mcp"
    fi
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

    # WEB configuration
    if $INSTALL_WEB; then
        if [[ -n "$WEB_PORT" ]]; then
            # Universal access: use /cli-api for relative calls which works for both Local and VM/Remote.
            local cli_url="/cli-api"

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
EOF
            )

            # Add MCP ports if enabled
            if $MCP_RECON_ENABLED || $MCP_CLI_ENABLED || $MCP_KALI_ENABLED; then
                cat >> "$WEB_DIR/.env.docker" << EOF

# MCP Agent Configuration
COMPOSE_PROFILES=${COMPOSE_PROFILES:-}
RECON_MCP_PORT=${RECON_PORT:-8002}
CLI_MCP_PORT=${MCP_PORT:-8001}
EOF
            fi

            chmod 600 "$WEB_DIR/.env.docker" 2>/dev/null || true
            echo -e "    ${OK} WEB config (.env.docker, mode 600)"
        fi
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
${API_KEY_ENV_VAR}=${API_KEY}
BUGTRACE_CORS_ORIGINS=${cors}
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
    local has_mcps=false
    $MCP_CLI_ENABLED && has_mcps=true
    $MCP_RECON_ENABLED && has_mcps=true
    $MCP_KALI_ENABLED && has_mcps=true

    if ! $has_mcps; then
        return
    fi

    step "Generating MCP configuration..."
    local config_file="$INSTALL_DIR/mcp-config.json"
    local entries=()

    if $MCP_CLI_ENABLED && [[ -n "$MCP_PORT" ]]; then
        entries+=("    \"bugtraceai\": { \"baseUrl\": \"http://localhost:${MCP_PORT}/sse\" }")
    fi

    if $MCP_RECON_ENABLED && [[ -n "$RECON_PORT" ]]; then
        entries+=("    \"reconftw\": { \"baseUrl\": \"http://localhost:${RECON_PORT}/sse\" }")
    fi

    if $MCP_KALI_ENABLED && [[ -n "$KALI_PORT" ]]; then
        entries+=("    \"kali\": { \"baseUrl\": \"http://localhost:${KALI_PORT}\" }")
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

# Patch docker-compose files to use .env values and enable MCP profiles
patch_compose() {
    # Build COMPOSE_PROFILES based on MCP selection
    local profiles=""
    # If the user is installing the CLI standalone/full mode, the CLI's own docker-compose
    # runs the MCP. We only want the WEB to run the 'cli' mcp profile if we are in "Solo WEB" mode.
    if $MCP_CLI_ENABLED && ! $INSTALL_CLI; then
        profiles="$profiles,cli"
    fi
    $MCP_RECON_ENABLED && profiles="$profiles,recon"
    $MCP_KALI_ENABLED && profiles="$profiles,kali"
    # Remove leading comma
    profiles="${profiles#,}"
    export COMPOSE_PROFILES="$profiles"

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
        fi
        if $MCP_KALI_ENABLED; then
            ensure_kali_startup_command "$web_compose"
        fi

        # Patch CLI MCP port if non-default
        if $MCP_CLI_ENABLED && [[ -n "$MCP_PORT" && "$MCP_PORT" != "8001" ]]; then
            sed_inplace "s/\"8001:8001\"/\"${MCP_PORT}:8001\"/" "$web_compose"
        fi

        # Patch Kali port if non-default
        if $MCP_KALI_ENABLED && [[ -n "$KALI_PORT" && "$KALI_PORT" != "8003" ]]; then
            # Kali doesn't have a default port mapping, add if needed
            :
        fi
    fi
}

# Docker compose helpers
_web_compose() {
    if [[ -z "$COMPOSE_CMD" ]]; then error "Docker Compose not found. Run: ./launcher.sh"; return 1; fi
    (cd "$WEB_DIR" && $COMPOSE_CMD --env-file .env.docker "$@")
}

_cli_compose() {
    if [[ -z "$COMPOSE_CMD" ]]; then error "Docker Compose not found. Run: ./launcher.sh"; return 1; fi
    (cd "$CLI_DIR" && $COMPOSE_CMD "$@")
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

start_services() {
    local build_log="$INSTALL_DIR/.build.log"
    : > "$build_log"

    # Start WEB services
    if $INSTALL_WEB && [[ -n "$WEB_PORT" ]]; then
        if [[ ! -f "$WEB_DIR/docker-compose.yml" ]]; then
            error "WEB docker-compose.yml not found — clone may have failed."
            exit 1
        fi
        # Force-remove stale containers (from ANY project/install method)
        docker rm -f bugtraceai-web-frontend bugtraceai-web-backend bugtraceai-web-db bugtraceai-api-routes 2>/dev/null || true
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

    # Start CLI service
    if $INSTALL_CLI || $MCP_CLI_ENABLED; then
        if [[ ! -f "$CLI_DIR/docker-compose.yml" ]]; then
            error "CLI docker-compose.yml not found — clone may have failed."
            exit 1
        fi
        # Force-remove any stale containers with these names (from ANY project/install method)
        docker rm -f bugtrace_api bugtrace-api bugtrace_mcp bugtrace-mcp bugtrace-cli-mcp 2>/dev/null || true
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
            exit 1
        fi
        echo -e "    ${OK} CLI service started"
    fi

    # Start MCP agents via WEB docker-compose profiles
    if [[ -n "$COMPOSE_PROFILES" ]] && [[ -f "$WEB_DIR/docker-compose.yml" ]]; then
        echo ""
        step "Starting MCP agents (profiles: ${COMPOSE_PROFILES})..."

        # Convert comma-separated profiles to individual --profile flags
        local profile_flags=""
        local IFS=','
        read -ra ADDR <<< "$COMPOSE_PROFILES"
        IFS=$' \t\n' # restore default
        for profile in "${ADDR[@]}"; do
            profile_flags="$profile_flags --profile $profile"
        done

        if ! _build_with_progress "MCP" _web_compose $profile_flags up -d --build; then
            echo ""
            error "Failed to start MCP agents."
            echo -e "    ${DIM}Last lines from build log:${NC}"
            tail -5 "$build_log" 2>/dev/null | while IFS= read -r line; do
                echo -e "    ${RED}│${NC} ${DIM}${line}${NC}"
            done
            echo -e "    ${DIM}Full log: ${build_log}${NC}"
            exit 1
        fi

        $MCP_CLI_ENABLED && echo -e "    ${OK} BugTraceAI MCP started"
        $MCP_RECON_ENABLED && echo -e "    ${OK} reconFTW MCP started"
        $MCP_KALI_ENABLED && echo -e "    ${OK} Kali Linux MCP started"
    fi
}

# Wait for a URL to respond, with visual feedback
# Pass "sse" as $4 to treat curl timeout (code 28) as success for SSE endpoints
wait_for_url() {
    local url=$1 label=$2 timeout=${3:-120} type=${4:-http}
    local elapsed=0 interval=3

    while [[ $elapsed -lt $timeout ]]; do
        curl -sf --max-time 2 "$url" &>/dev/null
        local res=$?
        # Code 0 = success. Code 28 = curl timeout, only valid for SSE (stream stays open).
        if [[ $res -eq 0 ]] || [[ $res -eq 28 && "$type" == "sse" ]]; then
            printf "\r    ${OK} %-30s\n" "$label"
            return 0
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

    # WEB health check
    if [[ -n "$WEB_PORT" ]]; then
        wait_for_url "http://localhost:${WEB_PORT}" "WEB (port ${WEB_PORT})" 120 || all_ok=false
        # API Discovery (Kiterunner) — core WEB service, check via nginx proxy
        wait_for_url "http://localhost:${WEB_PORT}/kr-api/health" "API Discovery (Kiterunner)" 60 || all_ok=false
    fi

    # CLI health check
    if [[ -n "$CLI_PORT" ]]; then
        wait_for_url "http://localhost:${CLI_PORT}/health" "CLI (port ${CLI_PORT})" 120 || all_ok=false
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

    if $MCP_KALI_ENABLED && [[ -n "$KALI_PORT" ]]; then
        # Kali doesn't have HTTP endpoint, just check container
        local kali_status
        kali_status=$(docker ps --format '{{.Status}}' --filter "name=^kali-mcp-server$" 2>/dev/null | head -1)
        if [[ -n "$kali_status" ]] && echo "$kali_status" | grep -q "Up"; then
            echo -e "    ${OK} Kali MCP (running)"
        else
            echo -e "    ${FAIL} Kali MCP (not running)"
            all_ok=false
        fi
    fi

    echo ""
    if [[ "$all_ok" == true ]]; then
        success "All services healthy!"
    else
        warn "Some services didn't respond. Check logs: ./launcher.sh logs"
    fi
}

save_state() {
    cat > "$STATE_FILE" << EOF
{
  "version": "${VERSION}",
  "mode": "${DEPLOY_MODE}",
  "web_port": "${WEB_PORT}",
  "cli_port": "${CLI_PORT}",
  "mcp_port": "${MCP_PORT}",
  "recon_port": "${RECON_PORT}",
  "kali_port": "${KALI_PORT}",
  "provider": "${LLM_PROVIDER}",
  "install_web": ${INSTALL_WEB},
  "install_cli": ${INSTALL_CLI},
  "mcp_cli_enabled": ${MCP_CLI_ENABLED},
  "mcp_recon_enabled": ${MCP_RECON_ENABLED},
  "mcp_kali_enabled": ${MCP_KALI_ENABLED},
  "install_dir": "${INSTALL_DIR}",
  "deployed_at": "$(iso_date)"
}
EOF
    chmod 600 "$STATE_FILE"
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
    fi

    # Show MCP agents
    local has_mcps=false
    $MCP_CLI_ENABLED && has_mcps=true
    $MCP_RECON_ENABLED && has_mcps=true
    $MCP_KALI_ENABLED && has_mcps=true

    if $has_mcps; then
        echo ""
        echo -e "  ${BOLD}MCP Agents:${NC}"
        $MCP_CLI_ENABLED && echo -e "    ${OK} BugTraceAI: ${CYAN}http://localhost:${MCP_PORT}/sse${NC}"
        $MCP_RECON_ENABLED && echo -e "    ${OK} reconFTW:   ${CYAN}http://localhost:${RECON_PORT}/sse${NC} (by @six2dez)"
        $MCP_KALI_ENABLED && echo -e "    ${OK} Kali Linux: ${CYAN}(interactive container)${NC}"

        echo ""
        echo -e "  ${BOLD}Connect your AI assistant:${NC}"
        echo -e "  ${DIM}Config file: ${INSTALL_DIR}/mcp-config.json${NC}"
        echo ""

        local mcp_host="${host_ip:-localhost}"
        echo -e "  ${DIM}Add to your MCP client config:${NC}"
        echo ""

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
        echo -e "  ${YELLOW}Kali Tip:${NC} To scan this machine from Kali, use:"
        echo -e "     ${BOLD}${DIM}nmap -Pn host.docker.internal${NC}"
    fi

    echo ""
    echo -e "  ${BOLD}Commands:${NC}"
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
    DEPLOY_MODE=$(awk -F'"' '/"mode"/{print $4}' "$STATE_FILE")
    WEB_PORT=$(awk -F'"' '/"web_port"/{print $4}' "$STATE_FILE" 2>/dev/null || echo "")
    CLI_PORT=$(awk -F'"' '/"cli_port"/{print $4}' "$STATE_FILE" 2>/dev/null || echo "")
    MCP_PORT=$(awk -F'"' '/"mcp_port"/{print $4}' "$STATE_FILE" 2>/dev/null || echo "")
    RECON_PORT=$(awk -F'"' '/"recon_port"/{print $4}' "$STATE_FILE" 2>/dev/null || echo "")
    KALI_PORT=$(awk -F'"' '/"kali_port"/{print $4}' "$STATE_FILE" 2>/dev/null || echo "")
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
    local install_web install_cli
    install_web=$(grep -o '"install_web": [^,}]*' "$STATE_FILE" 2>/dev/null | grep -oE '(true|false)')
    install_cli=$(grep -o '"install_cli": [^,}]*' "$STATE_FILE" 2>/dev/null | grep -oE '(true|false)')
    if [[ -n "$install_web" || -n "$install_cli" ]]; then
        [[ "$install_web" == "true" ]] && INSTALL_WEB=true || INSTALL_WEB=false
        [[ "$install_cli" == "true" ]] && INSTALL_CLI=true || INSTALL_CLI=false
    else
        INSTALL_WEB=false
        INSTALL_CLI=false
        [[ "$DEPLOY_MODE" == "web" || "$DEPLOY_MODE" == "full" || "$DEPLOY_MODE" == "custom" || "$DEPLOY_MODE" == "recon" ]] && INSTALL_WEB=true
        [[ "$DEPLOY_MODE" == "cli" || "$DEPLOY_MODE" == "full" ]] && INSTALL_CLI=true
    fi
}

cmd_status() {
    load_state
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
    $MCP_CLI_ENABLED && [[ -n "$MCP_PORT" ]] && echo -e "    BugTraceAI MCP: ${CYAN}http://localhost:${MCP_PORT}/sse${NC}"
    $MCP_RECON_ENABLED && [[ -n "$RECON_PORT" ]] && echo -e "    reconFTW MCP:   ${CYAN}http://localhost:${RECON_PORT}/sse${NC}"
    echo ""
}

_core_mcp_container_names() {
    printf '%s\n' "bugtrace_mcp" "bugtrace-mcp" "bugtrace-cli-mcp"
}

_core_mcp_container_name() {
    if $INSTALL_CLI; then
        printf '%s' "bugtrace_mcp"
    else
        printf '%s' "bugtrace-cli-mcp"
    fi
}

_core_mcp_existing_name() {
    local name
    while IFS= read -r name; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
            printf '%s' "$name"
            return 0
        fi
    done < <(_core_mcp_container_names)
    _core_mcp_container_name
}

_print_container_status() {
    local name=$1
    local status
    status=$(docker ps -a --format '{{.Status}}' --filter "name=^${name}$" 2>/dev/null | head -1)

    if [[ -z "$status" ]]; then
        echo -e "    ${DIM}$name — not found${NC}"
    elif echo "$status" | grep -q "Up"; then
        echo -e "    ${OK} $name — ${GREEN}running${NC} ($status)"
    else
        echo -e "    ${FAIL} $name — ${RED}stopped${NC} ($status)"
    fi
}

cmd_start() {
    load_state
    info "Starting services..."
    local ok=true
    
    # Start WEB services
    if [[ -d "$WEB_DIR" ]] && [[ -n "$WEB_PORT" ]]; then
        _web_compose up -d || { error "Failed to start WEB services"; ok=false; }
    fi
    
    # Start CLI services
    if [[ -d "$CLI_DIR" ]] && [[ -n "$CLI_PORT" ]]; then
        _cli_compose up -d || { error "Failed to start CLI service"; ok=false; }
    fi
    
    # Start MCP agents
    if [[ -d "$WEB_DIR" ]] && ($MCP_CLI_ENABLED || $MCP_RECON_ENABLED || $MCP_KALI_ENABLED); then
        # Build profiles string
        local profiles=""
        if $MCP_CLI_ENABLED && ! $INSTALL_CLI; then
            profiles="$profiles,cli"
        fi
        $MCP_RECON_ENABLED && profiles="$profiles,recon"
        $MCP_KALI_ENABLED && profiles="$profiles,kali"
        profiles="${profiles#,}"

        if [[ -n "$profiles" ]]; then
            COMPOSE_PROFILES="$profiles" _web_compose up -d || { error "Failed to start MCP agents"; ok=false; }
        fi
    fi
    
    $ok && success "Services started" || warn "Some services failed to start. Run: ./launcher.sh logs"
}

cmd_stop() {
    load_state
    info "Stopping services..."
    
    # Stop MCP agents first
    if [[ -d "$WEB_DIR" ]] && ($MCP_CLI_ENABLED || $MCP_RECON_ENABLED || $MCP_KALI_ENABLED); then
        local profile_flags=""
        if $MCP_CLI_ENABLED && ! $INSTALL_CLI; then
            profile_flags="$profile_flags --profile cli"
        fi
        $MCP_RECON_ENABLED && profile_flags="$profile_flags --profile recon"
        $MCP_KALI_ENABLED && profile_flags="$profile_flags --profile kali"

        if [[ -n "$profile_flags" ]]; then
            _web_compose $profile_flags stop 2>/dev/null || true
        fi
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
    load_state
    local target="${1:-}"

    if [[ -z "$target" ]]; then
        if $INSTALL_WEB && $INSTALL_CLI; then
            echo ""
            echo "Specify which logs to view:"
            echo -e "  ${DIM}./launcher.sh logs web${NC}"
            echo -e "  ${DIM}./launcher.sh logs cli${NC}"
            echo -e "  ${DIM}./launcher.sh logs mcp${NC}"
            echo ""
            exit 0
        elif $INSTALL_CLI; then
            target="cli"
        elif $INSTALL_WEB; then
            target="web"
        else
            error "Nothing installed to show logs for."
            exit 1
        fi
    fi

    case "$target" in
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
            if $INSTALL_CLI && [[ -d "$CLI_DIR" ]]; then
                _cli_compose logs -f --tail=100 mcp
            elif $MCP_CLI_ENABLED && [[ -d "$WEB_DIR" ]]; then
                _web_compose logs -f --tail=100 bugtrace-cli-mcp
            else
                error "MCP not installed"
            fi
            ;;
        *)
            error "Unknown target: $target (use 'web', 'cli', or 'mcp')"
            exit 1
            ;;
    esac
}

cmd_update() {
    load_state
    info "Updating BugTraceAI..."
    echo ""
    local update_ok=true

    if [[ -d "$WEB_DIR/.git" ]] && [[ "$DEPLOY_MODE" == "web" || "$DEPLOY_MODE" == "full" || "$DEPLOY_MODE" == "custom" || "$DEPLOY_MODE" == "recon" ]]; then
        step "Pulling WEB updates..."
        # Reset launcher-patched compose before pull, then re-apply patches.
        (cd "$WEB_DIR" && git checkout -- docker-compose.yml 2>/dev/null || true)
        if ! (cd "$WEB_DIR" && git pull --quiet); then
            warn "Failed to pull WEB updates"
            update_ok=false
        fi
        # Patch .env.docker: ensure VITE_CLI_API_URL uses proxy path (safe: preserves passwords)
        _patch_env_docker
        patch_compose
        step "Rebuilding WEB..."
        # Include the same MCP --profile flags used at start/build time, otherwise
        # a plain `up` excludes the profile-gated MCP services (cli/recon/kali) and
        # they keep running on their OLD images after a git pull.
        local update_profile_flags=""
        if $MCP_CLI_ENABLED && ! $INSTALL_CLI; then
            update_profile_flags="$update_profile_flags --profile cli"
        fi
        $MCP_RECON_ENABLED && update_profile_flags="$update_profile_flags --profile recon"
        $MCP_KALI_ENABLED && update_profile_flags="$update_profile_flags --profile kali"
        if ! _web_compose $update_profile_flags up -d --build; then
            error "Failed to rebuild WEB services"
            update_ok=false
        else
            echo -e "    ${OK} WEB updated"
        fi
    fi

    if [[ -d "$CLI_DIR/.git" ]] && { $INSTALL_CLI || $MCP_CLI_ENABLED; }; then
        step "Pulling CLI updates..."
        # Reset patched files before pull, then re-patch
        (cd "$CLI_DIR" && git checkout -- docker-compose.yml 2>/dev/null || true)
        if ! (cd "$CLI_DIR" && git pull --quiet); then
            warn "Failed to pull CLI updates"
            update_ok=false
        fi
        patch_compose
        step "Rebuilding CLI..."
        if ! _cli_compose up -d --build; then
            error "Failed to rebuild CLI service"
            update_ok=false
        else
            echo -e "    ${OK} CLI updated"
        fi
    fi

    if [[ -d "$RECON_DIR/.git" ]] && [[ "$DEPLOY_MODE" == "recon" || "$DEPLOY_MODE" == "custom" || "$MCP_RECON_ENABLED" == "true" ]]; then
        step "Pulling Recon updates..."
        if ! (cd "$RECON_DIR" && git pull --quiet); then
            warn "Failed to pull Recon updates"
            update_ok=false
        fi
        patch_recon_dockerfile_venv
        echo -e "    ${OK} Recon updated"
    fi

    # Clear version cache so next status check fetches fresh data
    rm -f "${VERSION_CACHE}".* 2>/dev/null

    echo ""
    if $update_ok; then
        success "Update complete!"
    else
        warn "Update finished with errors — review the messages above."
    fi
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
    load_state
    echo ""
    warn "This will remove all BugTraceAI containers, volumes, and data."
    echo -e "  ${DIM}Install directory: $INSTALL_DIR${NC}"
    echo ""
    echo -en "${YELLOW}Are you sure? [y/N]: ${NC}"
    read -r confirm
    [[ "$(to_lower "$confirm")" != "y" ]] && { info "Cancelled."; exit 0; }

    _teardown_all

    success "BugTraceAI uninstalled."
}

# Tear down all services and remove install directory
_teardown_all() {
    if [[ -d "$CLI_DIR" ]]; then
        step "Stopping CLI..."
        (cd "$CLI_DIR" && $COMPOSE_CMD down -v 2>/dev/null) || true
    fi
    if [[ -d "$WEB_DIR" ]]; then
        step "Stopping WEB..."
        (cd "$WEB_DIR" && $COMPOSE_CMD --env-file .env.docker down -v 2>/dev/null) || true
    fi
    step "Removing $INSTALL_DIR..."
    _assert_safe_install_dir "$INSTALL_DIR" require_marker
    rm -rf "$INSTALL_DIR"
}

# ── Docker Check ─────────────────────────────────────────────────────────────

check_docker() {
    if $IS_MACOS; then
        ensure_macos_docker_path
        if ! docker info &>/dev/null 2>&1; then
            if ! ensure_macos_runtime_ready; then
                error "Docker runtime is not ready."
                exit 1
            fi
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

# ── Help ─────────────────────────────────────────────────────────────────────

show_help() {
    echo ""
    echo -e "${BOLD}BugTraceAI Launcher v${VERSION}${NC}"
    echo ""
    echo "Usage: ./launcher.sh [command]"
    echo ""
    echo "Commands:"
    echo "  (no args)       Interactive setup wizard"
    echo "  status          Show service status"
    echo "  start           Start all services"
    echo "  stop            Stop all services"
    echo "  restart         Restart all services"
    echo "  logs [web|cli|mcp] View logs"
    echo "  update          Pull latest & rebuild"
    echo "  uninstall       Remove everything"
    echo ""
    echo "Docs: https://docs.bugtraceai.com"

    check_for_updates
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    ORIG_ARGS=("$@")
    case "${1:-}" in
        "")         run_wizard ;;
        status)     cmd_status ;;
        start)      check_docker; cmd_start ;;
        stop)       check_docker; cmd_stop ;;
        restart)    check_docker; cmd_restart ;;
        logs)       cmd_logs "${2:-}" ;;
        update)     check_docker; cmd_update ;;
        uninstall)  check_docker; cmd_uninstall ;;
        help|--help|-h) show_help ;;
        *)
            error "Unknown command: $1"
            echo "Run: ./launcher.sh help"
            exit 1
            ;;
    esac
}

main "$@"
