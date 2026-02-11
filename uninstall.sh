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

INSTALL_DIR="${BUGTRACEAI_DIR:-$HOME/bugtraceai}"
LAUNCHER_DIR="$HOME/bugtraceai-launcher"
STATE_FILE="$INSTALL_DIR/.launcher-state"
WEB_DIR="$INSTALL_DIR/BugTraceAI-WEB"
CLI_DIR="$INSTALL_DIR/BugTraceAI-CLI"

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
containers=$({ docker ps -a --filter "name=bugtraceai" --format "{{.Names}}"; docker ps -a --filter "name=bugtrace_" --format "{{.Names}}"; } | sort -u 2>/dev/null || true)
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
read -rp "$(echo -e "${YELLOW}Type 'uninstall' to confirm: ${NC}")" confirm

if [[ "$confirm" != "uninstall" ]]; then
    info "Cancelled."
    exit 0
fi

echo ""

# ── Step 1: Stop Docker Compose stacks ─────────────────────────────────────

if [[ -n "$COMPOSE_CMD" ]]; then
    if [[ -d "$WEB_DIR" ]] && [[ -f "$WEB_DIR/docker-compose.yml" ]]; then
        step "Stopping WEB stack..."
        (cd "$WEB_DIR" && $COMPOSE_CMD --env-file .env.docker down -v 2>/dev/null) || true
    fi

    if [[ -d "$CLI_DIR" ]] && [[ -f "$CLI_DIR/docker-compose.yml" ]]; then
        step "Stopping CLI stack..."
        (cd "$CLI_DIR" && $COMPOSE_CMD down -v 2>/dev/null) || true
    fi
fi

# ── Step 2: Remove remaining containers ────────────────────────────────────

containers=$({ docker ps -a --filter "name=bugtraceai" --format "{{.ID}}"; docker ps -a --filter "name=bugtrace_" --format "{{.ID}}"; } | sort -u 2>/dev/null || true)
if [[ -n "$containers" ]]; then
    step "Removing leftover containers..."
    echo "$containers" | xargs -r docker rm -f 2>/dev/null || true
fi

# ── Step 3: Remove volumes ─────────────────────────────────────────────────

volumes=$(docker volume ls --filter "name=bugtraceai" --format "{{.Name}}" 2>/dev/null || true)
if [[ -n "$volumes" ]]; then
    step "Removing Docker volumes..."
    echo "$volumes" | xargs -r docker volume rm -f 2>/dev/null || true
fi

# ── Step 4: Remove networks ───────────────────────────────────────────────

networks=$(docker network ls --filter "name=bugtraceai" --format "{{.Name}}" 2>/dev/null || true)
if [[ -n "$networks" ]]; then
    step "Removing Docker networks..."
    echo "$networks" | xargs -r docker network rm 2>/dev/null || true
fi

# ── Step 5: Remove Docker images ──────────────────────────────────────────

images=$(docker images --filter "reference=*bugtraceai*" --format "{{.ID}}" 2>/dev/null || true)
if [[ -n "$images" ]]; then
    step "Removing Docker images..."
    echo "$images" | xargs -r docker image rm -f 2>/dev/null || true
fi

# ── Step 6: Remove install directory ──────────────────────────────────────

if [[ -d "$INSTALL_DIR" ]]; then
    step "Removing $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
fi

# ── Step 7: Remove launcher directory ─────────────────────────────────────

if [[ -d "$LAUNCHER_DIR" ]]; then
    step "Removing $LAUNCHER_DIR..."
    rm -rf "$LAUNCHER_DIR"
fi

# ── Done ──────────────────────────────────────────────────────────────────

echo ""
success "BugTraceAI has been completely removed from this system."
echo ""
echo -e "${DIM}Docker Engine and Docker Compose were NOT removed.${NC}"
echo ""
