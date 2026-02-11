#!/bin/bash
#
# BugTraceAI Launcher v2.0
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
#   logs [web|cli] View logs
#   update        Pull latest & rebuild
#   uninstall     Remove everything
#

# ── Constants ────────────────────────────────────────────────────────────────

VERSION="2.0.0"
INSTALL_DIR="${BUGTRACEAI_DIR:-$HOME/bugtraceai}"
STATE_FILE="$INSTALL_DIR/.launcher-state"
WEB_DIR="$INSTALL_DIR/BugTraceAI-WEB"
CLI_DIR="$INSTALL_DIR/BugTraceAI-CLI"
WEB_REPO="https://github.com/BugTraceAI/BugTraceAI-WEB.git"
CLI_REPO="https://github.com/BugTraceAI/BugTraceAI-CLI.git"

# Wizard state
DEPLOY_MODE=""
WEB_PORT=""
CLI_PORT=""
API_KEY=""
MENU_SELECTION=0

# ── Colors & Symbols ────────────────────────────────────────────────────────

RED='\033[0;31m'    GREEN='\033[0;32m'  YELLOW='\033[1;33m'
BLUE='\033[0;34m'   CYAN='\033[0;36m'   BOLD='\033[1m'
DIM='\033[2m'       NC='\033[0m'
OK="${GREEN}✓${NC}" FAIL="${RED}✗${NC}" ARROW="${CYAN}➜${NC}"

# ── Logging ──────────────────────────────────────────────────────────────────

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
step()    { echo -e "  ${ARROW} $1"; }

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
    ! (ss -tuln 2>/dev/null || netstat -tuln 2>/dev/null) | grep -q ":$1 "
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
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-24}"
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
        read -rp "$(echo -e "  ${YELLOW}Accept? [Y] / n=next / or type a port: ${NC}")" answer

        case "${answer,,}" in
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

# Interactive arrow-key menu. Sets MENU_SELECTION to chosen index.
select_option() {
    local question=$1
    shift
    local options=("$@")
    local selected=0
    local total=${#options[@]}

    # Fallback: numbered menu if tput unavailable
    if ! command -v tput &>/dev/null || ! tput lines &>/dev/null 2>&1; then
        echo -e "\n${YELLOW}$question${NC}\n"
        for i in "${!options[@]}"; do
            echo -e "  ${CYAN}$((i + 1)))${NC} ${options[$i]}"
        done
        echo ""
        while true; do
            read -rp "$(echo -e "${YELLOW}Choice [1-$total]: ${NC}")" choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$total" ]]; then
                MENU_SELECTION=$((choice - 1))
                return 0
            fi
            error "Enter a number between 1 and $total"
        done
    fi

    # Interactive menu with arrow keys
    local total_lines=$((total + 2))
    local first_draw=true

    trap 'tput cnorm 2>/dev/null' INT TERM
    tput civis

    while true; do
        if [[ "$first_draw" == true ]]; then
            first_draw=false
        else
            tput cuu "$total_lines" 2>/dev/null
        fi

        echo -e "\033[K${YELLOW}$question${NC}"
        echo -e "\033[K"

        for i in "${!options[@]}"; do
            if [[ $i -eq $selected ]]; then
                echo -e "\033[K  ${CYAN}❯${NC} ${BOLD}${options[$i]}${NC}"
            else
                echo -e "\033[K    ${DIM}${options[$i]}${NC}"
            fi
        done

        read -rsn1 key
        case "$key" in
            $'\x1b')
                read -rsn2 -t 0.1 key
                case "$key" in
                    "[A") ((selected > 0)) && ((selected--)) || selected=$((total - 1)) ;;
                    "[B") ((selected < total - 1)) && ((selected++)) || selected=0 ;;
                esac
                ;;
            k) ((selected > 0)) && ((selected--)) || selected=$((total - 1)) ;;
            j) ((selected < total - 1)) && ((selected++)) || selected=0 ;;
            "") break ;;
        esac
    done

    tput cnorm
    trap - INT TERM

    MENU_SELECTION=$selected
}

# ── Pre-flight Checks ───────────────────────────────────────────────────────

# Detect docker compose command
COMPOSE_CMD=""
if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
elif docker-compose version &>/dev/null; then
    COMPOSE_CMD="docker-compose"
fi

check_deps() {
    info "Checking requirements..."
    echo ""
    local ok=true

    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        echo -e "  ${OK} Docker $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
    else
        echo -e "  ${FAIL} Docker not found or not running"
        ok=false
    fi

    if [[ -n "$COMPOSE_CMD" ]]; then
        version=$($COMPOSE_CMD version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        echo -e "  ${OK} Docker Compose $version"
    else
        echo -e "  ${FAIL} Docker Compose v2 not found"
        ok=false
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
    total_ram=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")
    if [[ "$total_ram" -ge 4096 ]]; then
        echo -e "  ${OK} RAM: ${total_ram}MB"
    else
        echo -e "  ${YELLOW}⚠${NC}  RAM: ${total_ram}MB (4GB+ recommended)"
    fi

    local disk
    disk=$(df -BG / 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4}' || echo "0")
    if [[ "$disk" -ge 10 ]]; then
        echo -e "  ${OK} Disk: ${disk}GB free"
    else
        echo -e "  ${YELLOW}⚠${NC}  Disk: ${disk}GB free (10GB+ recommended)"
    fi

    echo ""

    if [[ "$ok" == false ]]; then
        error "Missing required dependencies."
        echo ""
        echo -e "  Install Docker:  ${CYAN}https://docs.docker.com/engine/install/${NC}"
        echo -e "  Install Git:     ${DIM}sudo apt install git curl${NC}"
        exit 1
    fi

    success "All checks passed"
    echo ""
}

# ── Wizard ───────────────────────────────────────────────────────────────────

wizard_select_mode() {
    select_option "What would you like to install?" \
        "Full Platform (WEB + CLI) — Recommended" \
        "Standalone WEB — Browser-based analysis" \
        "Standalone CLI — Autonomous scanner"

    case $MENU_SELECTION in
        0) DEPLOY_MODE="full" ;;
        1) DEPLOY_MODE="web" ;;
        2) DEPLOY_MODE="cli" ;;
    esac

    echo ""
    success "Mode: $DEPLOY_MODE"
    echo ""
}

wizard_ask_api_key() {
    echo -e "  ${DIM}BugTraceAI uses OpenRouter for AI-powered analysis.${NC}"
    echo -e "  ${DIM}Get your API key at: ${CYAN}https://openrouter.ai/keys${NC}"
    echo ""

    while true; do
        read -rsp "$(echo -e "  ${YELLOW}OpenRouter API key: ${NC}")" API_KEY
        echo ""

        if [[ -z "$API_KEY" ]]; then
            error "API key cannot be empty"
            continue
        fi

        if [[ ! "$API_KEY" =~ ^sk-or- ]]; then
            warn "Key doesn't look like an OpenRouter key (expected sk-or-...)"
            read -rp "$(echo -e "  ${YELLOW}Continue anyway? [y/N]: ${NC}")" confirm
            [[ "${confirm,,}" != "y" ]] && continue
        fi

        break
    done

    success "API key configured"
    echo ""
}

wizard_configure_ports() {
    echo -e "${BOLD}Port Configuration${NC}"

    if [[ "$DEPLOY_MODE" == "web" || "$DEPLOY_MODE" == "full" ]]; then
        propose_port "WEB frontend port" 6869 WEB_PORT
    fi

    if [[ "$DEPLOY_MODE" == "cli" || "$DEPLOY_MODE" == "full" ]]; then
        propose_port "CLI API port" 8000 CLI_PORT
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

    case "$DEPLOY_MODE" in
        web)
            echo -e "  WEB:        ${CYAN}http://localhost:$WEB_PORT${NC}"
            ;;
        cli)
            echo -e "  CLI API:    ${CYAN}http://localhost:$CLI_PORT${NC}"
            ;;
        full)
            echo -e "  WEB:        ${CYAN}http://localhost:$WEB_PORT${NC}"
            echo -e "  CLI API:    ${CYAN}http://localhost:$CLI_PORT${NC}"
            ;;
    esac

    echo -e "  API Key:    ${DIM}${API_KEY:0:8}...${API_KEY: -4}${NC}"
    echo -e "  Install at: ${DIM}$INSTALL_DIR${NC}"
    echo ""
    echo -e "${BOLD}─────────────────────────────${NC}"
    echo ""

    read -rp "$(echo -e "${YELLOW}Proceed with installation? [Y/n]: ${NC}")" confirm
    if [[ "${confirm,,}" == "n" ]]; then
        warn "Installation cancelled."
        exit 0
    fi
    echo ""
}

run_wizard() {
    show_banner

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
    fi

    check_deps
    wizard_select_mode
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
    if [[ "$DEPLOY_MODE" == "web" || "$DEPLOY_MODE" == "full" ]]; then
        if [[ -d "$WEB_DIR/.git" ]]; then
            step "Updating BugTraceAI-WEB..."
            (cd "$WEB_DIR" && git pull --quiet) 2>/dev/null
        else
            step "Cloning BugTraceAI-WEB..."
            git clone --depth 1 "$WEB_REPO" "$WEB_DIR" 2>/dev/null
        fi
        echo -e "    ${OK} BugTraceAI-WEB"
    fi

    if [[ "$DEPLOY_MODE" == "cli" || "$DEPLOY_MODE" == "full" ]]; then
        if [[ -d "$CLI_DIR/.git" ]]; then
            step "Updating BugTraceAI-CLI..."
            (cd "$CLI_DIR" && git pull --quiet) 2>/dev/null
        else
            step "Cloning BugTraceAI-CLI..."
            git clone --depth 1 "$CLI_REPO" "$CLI_DIR" 2>/dev/null
        fi
        echo -e "    ${OK} BugTraceAI-CLI"
    fi
}

generate_env() {
    step "Generating configuration..."

    if [[ "$DEPLOY_MODE" == "web" || "$DEPLOY_MODE" == "full" ]]; then
        local cli_url=""
        [[ "$DEPLOY_MODE" == "full" ]] && cli_url="http://localhost:${CLI_PORT}"

        cat > "$WEB_DIR/.env.docker" << EOF
# BugTraceAI-WEB — Generated by Launcher v${VERSION} ($(date -Iseconds))
POSTGRES_USER=bugtraceai
POSTGRES_PASSWORD=$(generate_password 24)
POSTGRES_DB=bugtraceai_web
FRONTEND_PORT=${WEB_PORT}
VITE_CLI_API_URL=${cli_url}
EOF
        echo -e "    ${OK} WEB config (.env.docker)"
    fi

    if [[ "$DEPLOY_MODE" == "cli" || "$DEPLOY_MODE" == "full" ]]; then
        local cors="*"
        [[ "$DEPLOY_MODE" == "full" ]] && cors="http://localhost:${WEB_PORT}"

        cat > "$CLI_DIR/.env" << EOF
# BugTraceAI-CLI — Generated by Launcher v${VERSION} ($(date -Iseconds))
OPENROUTER_API_KEY=${API_KEY}
BUGTRACE_CORS_ORIGINS=${cors}
EOF
        echo -e "    ${OK} CLI config (.env)"
    fi
}

# Patch CLI docker-compose to use .env values instead of hardcoded ones
patch_compose() {
    if [[ "$DEPLOY_MODE" == "cli" || "$DEPLOY_MODE" == "full" ]]; then
        local compose="$CLI_DIR/docker-compose.yml"
        [[ ! -f "$compose" ]] && return

        # Remove entire environment section (CORS is loaded from .env via env_file)
        # This avoids leaving an empty "environment:" key which breaks Docker Compose
        sed -i '/^    environment:/d' "$compose"
        sed -i '/BUGTRACE_CORS_ORIGINS/d' "$compose"

        # Patch port mapping if non-default
        if [[ -n "$CLI_PORT" && "$CLI_PORT" != "8000" ]]; then
            sed -i "s/\"8000:8000\"/\"${CLI_PORT}:8000\"/" "$compose"
        fi
    fi
}

# Docker compose helpers
_web_compose() {
    (cd "$WEB_DIR" && $COMPOSE_CMD --env-file .env.docker "$@")
}

_cli_compose() {
    (cd "$CLI_DIR" && $COMPOSE_CMD "$@")
}

start_services() {
    if [[ "$DEPLOY_MODE" == "web" || "$DEPLOY_MODE" == "full" ]]; then
        echo ""
        step "Building & starting WEB services..."
        echo -e "    ${DIM}(postgres + backend + frontend — may take 5-10 min on first run)${NC}"
        _web_compose up -d --build
        echo -e "    ${OK} WEB services started"
    fi

    if [[ "$DEPLOY_MODE" == "cli" || "$DEPLOY_MODE" == "full" ]]; then
        echo ""
        step "Building & starting CLI service..."
        echo -e "    ${DIM}(compiles Go tools + installs browser — may take 10-15 min on first run)${NC}"
        _cli_compose up -d --build
        echo -e "    ${OK} CLI service started"
    fi
}

# Wait for a URL to respond, with visual feedback
wait_for_url() {
    local url=$1 label=$2 timeout=${3:-120}
    local elapsed=0 interval=3

    while [[ $elapsed -lt $timeout ]]; do
        if curl -sf "$url" &>/dev/null; then
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

    if [[ "$DEPLOY_MODE" == "web" || "$DEPLOY_MODE" == "full" ]]; then
        wait_for_url "http://localhost:${WEB_PORT}" "WEB (port ${WEB_PORT})" 120 || all_ok=false
    fi

    if [[ "$DEPLOY_MODE" == "cli" || "$DEPLOY_MODE" == "full" ]]; then
        wait_for_url "http://localhost:${CLI_PORT}/health" "CLI (port ${CLI_PORT})" 120 || all_ok=false
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
  "install_dir": "${INSTALL_DIR}",
  "deployed_at": "$(date -Iseconds)"
}
EOF
    chmod 600 "$STATE_FILE"
}

show_success() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}     ${BOLD}BugTraceAI deployed successfully!${NC}            ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""

    case "$DEPLOY_MODE" in
        web)
            echo -e "  ${ARROW} Open: ${BOLD}${CYAN}http://localhost:${WEB_PORT}${NC}"
            ;;
        cli)
            echo -e "  ${ARROW} CLI API: ${BOLD}${CYAN}http://localhost:${CLI_PORT}${NC}"
            echo -e "  ${ARROW} API Docs: ${BOLD}${CYAN}http://localhost:${CLI_PORT}/docs${NC}"
            ;;
        full)
            echo -e "  ${ARROW} WEB Interface: ${BOLD}${CYAN}http://localhost:${WEB_PORT}${NC}"
            echo -e "  ${ARROW} CLI API:        ${BOLD}${CYAN}http://localhost:${CLI_PORT}${NC}"
            echo -e "  ${ARROW} CLI is connected to WEB automatically"
            ;;
    esac

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
    DEPLOY_MODE=$(grep -oP '"mode":\s*"\K[^"]+' "$STATE_FILE")
    WEB_PORT=$(grep -oP '"web_port":\s*"\K[^"]+' "$STATE_FILE" 2>/dev/null || echo "")
    CLI_PORT=$(grep -oP '"cli_port":\s*"\K[^"]+' "$STATE_FILE" 2>/dev/null || echo "")
}

cmd_status() {
    load_state
    echo ""
    echo -e "${BOLD}BugTraceAI Status${NC}  (mode: ${CYAN}$DEPLOY_MODE${NC})"
    echo "──────────────────────────────────────────"

    if [[ "$DEPLOY_MODE" == "web" || "$DEPLOY_MODE" == "full" ]]; then
        echo -e "\n  ${BOLD}WEB Stack${NC} (port ${WEB_PORT})"
        for c in bugtraceai-web-db bugtraceai-web-backend bugtraceai-web-frontend; do
            _print_container_status "$c"
        done
    fi

    if [[ "$DEPLOY_MODE" == "cli" || "$DEPLOY_MODE" == "full" ]]; then
        echo -e "\n  ${BOLD}CLI Stack${NC} (port ${CLI_PORT})"
        _print_container_status "bugtrace_api"
    fi

    echo ""

    # Endpoints
    echo -e "  ${BOLD}Endpoints:${NC}"
    [[ -n "$WEB_PORT" ]] && echo -e "    WEB:  ${CYAN}http://localhost:${WEB_PORT}${NC}"
    [[ -n "$CLI_PORT" ]] && echo -e "    CLI:  ${CYAN}http://localhost:${CLI_PORT}${NC}"
    echo ""
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
    [[ -d "$WEB_DIR" && ("$DEPLOY_MODE" == "web" || "$DEPLOY_MODE" == "full") ]] && _web_compose up -d
    [[ -d "$CLI_DIR" && ("$DEPLOY_MODE" == "cli" || "$DEPLOY_MODE" == "full") ]] && _cli_compose up -d
    success "Services started"
}

cmd_stop() {
    load_state
    info "Stopping services..."
    [[ -d "$CLI_DIR" && ("$DEPLOY_MODE" == "cli" || "$DEPLOY_MODE" == "full") ]] && _cli_compose stop
    [[ -d "$WEB_DIR" && ("$DEPLOY_MODE" == "web" || "$DEPLOY_MODE" == "full") ]] && _web_compose stop
    success "Services stopped"
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_logs() {
    load_state
    local target="${1:-}"

    if [[ -z "$target" && "$DEPLOY_MODE" == "full" ]]; then
        echo ""
        echo "Specify which logs to view:"
        echo -e "  ${DIM}./launcher.sh logs web${NC}"
        echo -e "  ${DIM}./launcher.sh logs cli${NC}"
        echo ""
        exit 0
    fi

    case "$target" in
        web|"")
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
        *)
            error "Unknown target: $target (use 'web' or 'cli')"
            exit 1
            ;;
    esac
}

cmd_update() {
    load_state
    info "Updating BugTraceAI..."
    echo ""

    if [[ -d "$WEB_DIR/.git" && ("$DEPLOY_MODE" == "web" || "$DEPLOY_MODE" == "full") ]]; then
        step "Pulling WEB updates..."
        (cd "$WEB_DIR" && git pull --quiet)
        step "Rebuilding WEB..."
        _web_compose up -d --build
        echo -e "    ${OK} WEB updated"
    fi

    if [[ -d "$CLI_DIR/.git" && ("$DEPLOY_MODE" == "cli" || "$DEPLOY_MODE" == "full") ]]; then
        step "Pulling CLI updates..."
        # Reset patched files before pull, then re-patch
        (cd "$CLI_DIR" && git checkout -- docker-compose.yml 2>/dev/null || true)
        (cd "$CLI_DIR" && git pull --quiet)
        patch_compose
        step "Rebuilding CLI..."
        _cli_compose up -d --build
        echo -e "    ${OK} CLI updated"
    fi

    echo ""
    success "Update complete!"
}

cmd_uninstall() {
    load_state
    echo ""
    warn "This will remove all BugTraceAI containers, volumes, and data."
    echo -e "  ${DIM}Install directory: $INSTALL_DIR${NC}"
    echo ""
    read -rp "$(echo -e "${YELLOW}Are you sure? [y/N]: ${NC}")" confirm
    [[ "${confirm,,}" != "y" ]] && { info "Cancelled."; exit 0; }

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
    rm -rf "$INSTALL_DIR"
}

# ── Docker Check ─────────────────────────────────────────────────────────────

check_docker() {
    if ! docker info &>/dev/null 2>&1; then
        error "Docker is not running or current user lacks permission."
        echo -e "  ${DIM}Add your user to the docker group: sudo usermod -aG docker \$USER${NC}"
        exit 1
    fi
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
    echo "  logs [web|cli]  View logs"
    echo "  update          Pull latest & rebuild"
    echo "  uninstall       Remove everything"
    echo ""
    echo "Docs: https://docs.bugtraceai.com"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    case "${1:-}" in
        "")         check_docker; run_wizard ;;
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
