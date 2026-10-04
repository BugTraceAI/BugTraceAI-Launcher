#!/bin/bash
#
# BugTraceAI Uninstaller
# Completely removes BugTraceAI platform deployed by the Launcher
#

set -e

# ── Colors ─────────────────────────────────────────────────────────────────

RED='\033[0;31m'    GREEN='\033[0;32m'  YELLOW='\033[1;33m'
BLUE='\033[0;34m'   CYAN='\033[0;36m'   BOLD='\033[1m'
DIM='\033[2m'       NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
step()    { echo -e "  ${CYAN}>${NC} $1"; }

# ── Docker check ───────────────────────────────────────────────────────────

if ! docker info &>/dev/null 2>&1; then
    error "Docker is not running or current user lacks permission."
    echo -e "  ${DIM}Add your user to the docker group: sudo usermod -aG docker \$USER${NC}"
    exit 1
fi

# ── Paths ──────────────────────────────────────────────────────────────────

resolve_home() {
    local user="$1"
    local home=""
    if command -v getent >/dev/null 2>&1; then
        home="$(getent passwd "$user" | cut -d: -f6)"
    fi
    if [[ -z "$home" ]] && command -v dscl >/dev/null 2>&1; then
        home="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    fi
    if [[ -z "$home" ]] && [[ -r /etc/passwd ]]; then
        home="$(awk -F: -v u="$user" '$1 == u { print $6; exit }' /etc/passwd)"
    fi
    if [[ -z "$home" ]]; then
        home="$(eval echo "~$user" 2>/dev/null)"
        [[ "$home" == "~$user" ]] && home=""
    fi
    printf '%s' "$home"
}

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(resolve_home "$TARGET_USER")"
if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
    error "Could not resolve HOME for '$TARGET_USER'. Set BUGTRACEAI_DIR/BUGTRACEAI_LAUNCHER_DIR or run without sudo."
    exit 1
fi

INSTALL_DIR="${BUGTRACEAI_DIR:-$TARGET_HOME/bugtraceai}"
LAUNCHER_DIR="${BUGTRACEAI_LAUNCHER_DIR:-$TARGET_HOME/bugtraceai-launcher}"
STATE_FILE="$INSTALL_DIR/.launcher-state"
WEB_DIR="$INSTALL_DIR/BugTraceAI-WEB"
CLI_DIR="$INSTALL_DIR/BugTraceAI-CLI"
API_DIR="$INSTALL_DIR/BugTraceAI-API"

# Refuse to rm -rf an empty / root / unexpected path. Marker mode prevents a
# custom path that merely contains "bugtraceai" from being removed by mistake.
_assert_safe_dir() {
    local d="$1" mode="${2:-}" low slash_count has_marker=false
    low="$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')"
    if [[ -z "$d" || "$d" == "/" || "$low" != *bugtraceai* ]]; then
        error "Refusing to remove unsafe path: '${d:-<empty>}'"
        exit 1
    fi
    slash_count="$(printf '%s' "$d" | tr -cd '/' | wc -c | tr -d ' ')"
    if [[ "$slash_count" -lt 2 ]]; then
        error "Refusing to remove shallow path: '$d'"
        exit 1
    fi
    if [[ "$mode" == "require_marker" && -d "$d" ]]; then
        if [[ "$d" == "$INSTALL_DIR" ]]; then
            [[ -e "$d/.launcher-state" || -e "$d/mcp-config.json" || -d "$d/BugTraceAI-WEB" || -d "$d/BugTraceAI-CLI" ]] && has_marker=true
        elif [[ "$d" == "$LAUNCHER_DIR" ]]; then
            [[ -e "$d/launcher.sh" || -e "$d/uninstall.sh" ]] && has_marker=true
        else
            [[ -e "$d/.launcher-state" || -e "$d/launcher.sh" || -e "$d/mcp-config.json" ]] && has_marker=true
        fi
        if ! $has_marker; then
            error "Refusing to remove '$d': no BugTraceAI launcher marker found."
            exit 1
        fi
    fi
}

# Validate BOTH target paths UP FRONT, before any Docker teardown, so we never
# destroy resources and then abort mid-way on a bad path (partial uninstall).
_assert_safe_dir "$INSTALL_DIR" require_marker
_assert_safe_dir "$LAUNCHER_DIR" require_marker

managed_container_names() {
    docker ps -a --format '{{.Names}}' 2>/dev/null |
        grep -E '^(bugtrace-api|bugtrace_api|bugtrace_mcp|bugtrace-mcp|bugtrace-cli-mcp|bugtraceai-web-(frontend|backend|db)|bugtraceai-api-routes|kali-mcp-server|reconftw-mcp)$' |
        sort -u || true
}

# Detect docker compose command
if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    COMPOSE_CMD=""
fi

# ── Banner ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${RED}${BOLD}"
echo "  ╔════════════════════════════════════════╗"
echo "  ║      BugTraceAI — Uninstaller          ║"
echo "  ╚════════════════════════════════════════╝"
echo -e "${NC}"

# ── Inventory ──────────────────────────────────────────────────────────────

echo -e "${BOLD}Scanning installed components...${NC}"
echo ""

found_anything=false

# Check install directory
if [[ -d "$INSTALL_DIR" ]]; then
    step "Install directory: ${BOLD}$INSTALL_DIR${NC}"
    found_anything=true

    # Show deployed mode from state file
    if [[ -f "$STATE_FILE" ]]; then
        mode=$(grep -o '"mode"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" 2>/dev/null | cut -d'"' -f4)
        [[ -n "$mode" ]] && step "  Deployment mode: $mode"
    fi
else
    step "Install directory: ${DIM}not found${NC}"
fi

# Check launcher directory
if [[ -d "$LAUNCHER_DIR" ]]; then
    step "Launcher directory: ${BOLD}$LAUNCHER_DIR${NC}"
    found_anything=true
else
    step "Launcher directory: ${DIM}not found${NC}"
fi

# Check Docker containers
containers="$(managed_container_names)"
if [[ -n "$containers" ]]; then
    count=$(echo "$containers" | wc -l)
    step "Docker containers: ${BOLD}${count}${NC} found"
    echo "$containers" | while read -r c; do
        state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "unknown")
        echo -e "      ${DIM}- $c ($state)${NC}"
    done
    found_anything=true
else
    step "Docker containers: ${DIM}none${NC}"
fi

# Check Docker volumes
volumes=$(docker volume ls --filter "name=bugtraceai" --format "{{.Name}}" 2>/dev/null || true)
if [[ -n "$volumes" ]]; then
    count=$(echo "$volumes" | wc -l)
    step "Docker volumes: ${BOLD}${count}${NC} found"
    echo "$volumes" | while read -r v; do
        echo -e "      ${DIM}- $v${NC}"
    done
    found_anything=true
else
    step "Docker volumes: ${DIM}none${NC}"
fi

# Check Docker networks
networks=$(docker network ls --filter "name=bugtraceai" --format "{{.Name}}" 2>/dev/null || true)
if [[ -n "$networks" ]]; then
    count=$(echo "$networks" | wc -l)
    step "Docker networks: ${BOLD}${count}${NC} found"
    found_anything=true
else
    step "Docker networks: ${DIM}none${NC}"
fi

# Check Docker images
images=$(docker images --filter "reference=*bugtraceai*" --format "{{.Repository}}:{{.Tag}}" 2>/dev/null || true)
if [[ -n "$images" ]]; then
    count=$(echo "$images" | wc -l)
    step "Docker images: ${BOLD}${count}${NC} found"
    found_anything=true
else
    step "Docker images: ${DIM}none${NC}"
fi

echo ""

if [[ "$found_anything" == false ]]; then
    info "Nothing to uninstall. BugTraceAI is not installed on this system."
    exit 0
fi

# ── Confirmation ───────────────────────────────────────────────────────────

echo -e "${RED}${BOLD}WARNING: This will permanently remove all BugTraceAI data.${NC}"
echo -e "${DIM}This includes databases, scan reports, chat history, and configurations.${NC}"
echo ""
# `|| true` so a non-interactive stdin (EOF) doesn't abort under `set -e` before
# the Cancelled branch — an empty confirm safely never equals 'uninstall'.
read -rp "$(echo -e "${YELLOW}Type 'uninstall' to confirm: ${NC}")" confirm || true

if [[ "$confirm" != "uninstall" ]]; then
    info "Cancelled."
    exit 0
fi

echo ""

# ── Step 1: Stop Docker Compose stacks ─────────────────────────────────────

if [[ -n "$COMPOSE_CMD" ]]; then
    teardown_failed=false
    if [[ -d "$API_DIR" && -f "$API_DIR/docker-compose.yml" ]]; then
        step "Stopping BugTraceAI-API stack..."
        (cd "$API_DIR" && $COMPOSE_CMD down -v --remove-orphans) || teardown_failed=true
    fi
    if [[ -d "$CLI_DIR" && -f "$CLI_DIR/docker-compose.yml" ]]; then
        step "Stopping CLI stack..."
        (cd "$CLI_DIR" && $COMPOSE_CMD down -v --remove-orphans) || teardown_failed=true
    fi
    if [[ -d "$WEB_DIR" ]] && [[ -f "$WEB_DIR/docker-compose.yml" ]]; then
        step "Stopping WEB stack..."
        (cd "$WEB_DIR" && $COMPOSE_CMD --env-file .env.docker --profile recon --profile kali down -v --remove-orphans) || teardown_failed=true
    fi
    if [[ "$teardown_failed" == true ]]; then
        error "A Compose stack could not be stopped. No installation files or Docker resources were removed."
        exit 1
    fi
    remaining="$(managed_container_names)"
    if [[ -n "$remaining" ]]; then
        error "Managed BugTraceAI containers remain after teardown. No installation files or Docker resources were removed: $remaining"
        exit 1
    fi
elif [[ -n "$containers" || -f "$API_DIR/docker-compose.yml" || -f "$CLI_DIR/docker-compose.yml" || -f "$WEB_DIR/docker-compose.yml" ]]; then
    error "Compose is unavailable or managed containers remain; refusing to remove installation files while services may still be running."
    exit 1
fi

# ── Step 2: Remove install directory ──────────────────────────────────────

if [[ -d "$INSTALL_DIR" ]]; then
    step "Removing $INSTALL_DIR..."
    _assert_safe_dir "$INSTALL_DIR" require_marker
    rm -rf "$INSTALL_DIR"
fi

# ── Step 3: Remove launcher directory ─────────────────────────────────────

if [[ -d "$LAUNCHER_DIR" ]]; then
    step "Removing $LAUNCHER_DIR..."
    _assert_safe_dir "$LAUNCHER_DIR" require_marker
    rm -rf "$LAUNCHER_DIR"
fi

# ── Done ──────────────────────────────────────────────────────────────────

echo ""
success "BugTraceAI Compose stacks, project volumes, and launcher files have been removed. Docker images were retained."
echo ""
echo -e "${DIM}Docker Engine and Docker Compose were NOT removed.${NC}"
echo ""
