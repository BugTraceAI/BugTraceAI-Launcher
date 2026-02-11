#!/bin/bash
#
# BugTraceAI One-Liner Installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/BugTraceAI/BugTraceAI-Launcher/master/install.sh | sudo bash
#

set -e

RED='\033[0;31m'  GREEN='\033[0;32m'  CYAN='\033[0;36m'
YELLOW='\033[1;33m'  BOLD='\033[1m'  NC='\033[0m'

REPO_URL="https://github.com/BugTraceAI/BugTraceAI-Launcher.git"
LAUNCHER_DIR="/opt/bugtraceai-launcher"

info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ── Dependency Auto-Installer ───────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    error "This installer must be run as root."
    echo -e "  ${YELLOW}Usage:${NC} curl -fsSL <url> | ${BOLD}sudo${NC} bash"
    exit 1
fi

echo ""
echo -e "${CYAN}${BOLD}BugTraceAI Installer${NC}"
echo ""
info "Checking system requirements..."
echo ""

# Check basic tools
missing_basic=()
for cmd in git curl; do
    if ! command -v "$cmd" &>/dev/null; then
        missing_basic+=("$cmd")
    fi
done

if [[ ${#missing_basic[@]} -gt 0 ]]; then
    warn "Missing: ${missing_basic[*]}"
    
    # Detect package manager
    if command -v apt-get &>/dev/null; then
        echo -e "  ${CYAN}Would you like to install them now? [Y/n]${NC}"
        read -r confirm
        if [[ "${confirm,,}" != "n" ]]; then
            info "Installing ${missing_basic[*]}..."
            apt-get update -qq
            apt-get install -y "${missing_basic[@]}"
            success "Installed ${missing_basic[*]}"
        else
            error "Cannot proceed without: ${missing_basic[*]}"
            exit 1
        fi
    else
        error "Please install: ${missing_basic[*]}"
        exit 1
    fi
fi

# Check Docker
if ! command -v docker &>/dev/null; then
    error "Docker is not installed."
    echo ""
    echo -e "  ${YELLOW}Install Docker:${NC}"
    echo -e "    ${CYAN}https://docs.docker.com/engine/install/${NC}"
    echo ""
    echo -e "  ${DIM}Quick install for Ubuntu/Debian:${NC}"
    echo -e "    ${DIM}curl -fsSL https://get.docker.com | sudo bash${NC}"
    echo ""
    exit 1
fi

# Check Docker is running
if ! docker info &>/dev/null 2>&1; then
    error "Docker is installed but not running."
    echo -e "  ${YELLOW}Start Docker:${NC} sudo systemctl start docker"
    exit 1
fi

# Check Docker Compose
has_compose_plugin=false
has_compose_standalone=false

if docker compose version &>/dev/null 2>&1; then
    has_compose_plugin=true
fi

if command -v docker-compose &>/dev/null && docker-compose version &>/dev/null 2>&1; then
    has_compose_standalone=true
fi

if [[ "$has_compose_plugin" == false ]] && [[ "$has_compose_standalone" == false ]]; then
    warn "Docker Compose is not installed."
    echo ""
    
    # Try to auto-install the plugin on Ubuntu/Debian
    if command -v apt-get &>/dev/null; then
        echo -e "  ${CYAN}Install Docker Compose plugin now? [Y/n]${NC}"
        read -r confirm
        if [[ "${confirm,,}" != "n" ]]; then
            info "Installing docker-compose-plugin..."
            if apt-get install -y docker-compose-plugin 2>/dev/null; then
                success "Docker Compose plugin installed"
                has_compose_plugin=true
            else
                warn "Could not install via apt. Trying standalone binary..."
                # Fallback: install standalone binary
                COMPOSE_VERSION=$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')
                curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
                chmod +x /usr/local/bin/docker-compose
                
                if docker-compose version &>/dev/null; then
                    success "Docker Compose standalone installed"
                    has_compose_standalone=true
                else
                    error "Failed to install Docker Compose"
                    exit 1
                fi
            fi
        else
            error "Docker Compose is required to continue."
            echo -e "  ${YELLOW}Install manually:${NC} https://docs.docker.com/compose/install/"
            exit 1
        fi
    else
        error "Docker Compose is required."
        echo -e "  ${YELLOW}Install:${NC} https://docs.docker.com/compose/install/"
        exit 1
    fi
fi

# Show what we detected
echo ""
success "All requirements met:"
echo -e "  ✓ Docker $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
if [[ "$has_compose_plugin" == true ]]; then
    echo -e "  ✓ Docker Compose (plugin) $(docker compose version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)"
elif [[ "$has_compose_standalone" == true ]]; then
    echo -e "  ✓ Docker Compose (standalone) $(docker-compose --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)"
fi
echo -e "  ✓ Git $(git --version | awk '{print $3}')"
echo -e "  ✓ curl"
echo ""

# ── Download Launcher ────────────────────────────────────────────────────────


if [[ -d "$LAUNCHER_DIR/.git" ]]; then
    info "Launcher exists at $LAUNCHER_DIR, updating..."
    (cd "$LAUNCHER_DIR" && git pull --quiet) || true
    success "Launcher updated"
else
    info "Downloading BugTraceAI Launcher..."
    if git clone --depth 1 "$REPO_URL" "$LAUNCHER_DIR" 2>/dev/null; then
        success "Launcher downloaded"
    else
        info "Git clone failed, trying tarball..."
        tmpfile=$(mktemp)
        if curl -fsSL "https://github.com/BugTraceAI/BugTraceAI-Launcher/archive/refs/heads/master.tar.gz" -o "$tmpfile"; then
            mkdir -p "$LAUNCHER_DIR"
            tar xzf "$tmpfile" -C "$LAUNCHER_DIR" --strip-components=1
            rm -f "$tmpfile"
            success "Launcher downloaded (tarball)"
        else
            rm -f "$tmpfile"
            error "Failed to download BugTraceAI Launcher"
            exit 1
        fi
    fi
fi

chmod +x "$LAUNCHER_DIR/launcher.sh"

# ── Launch Wizard ────────────────────────────────────────────────────────────

if [[ -t 0 ]]; then
    # Already interactive
    info "Starting BugTraceAI setup wizard..."
    exec "$LAUNCHER_DIR/launcher.sh"
else
    # Piped/Redirected - Try to reconnect to TTY
    if [[ -c /dev/tty ]]; then
        info "Piped execution detected. Reconnecting to terminal..."
        exec "$LAUNCHER_DIR/launcher.sh" < /dev/tty
    else
        warn "No terminal detected. You might need to run the launcher manually:"
        echo -e "  ${BOLD}sudo $LAUNCHER_DIR/launcher.sh${NC}"
        exit 0
    fi
fi
