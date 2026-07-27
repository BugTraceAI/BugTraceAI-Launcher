#!/usr/bin/env bash
#
# BugTraceAI one-liner bootstrap installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/BugTraceAI/BugTraceAI-Launcher/main/install.sh | bash
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

REPO_URL="https://github.com/BugTraceAI/BugTraceAI-Launcher.git"

info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

is_macos() {
    local kernel
    kernel="$(uname -s 2>/dev/null || true)"
    [[ "$kernel" == "Darwin" ]] && return 0
    command -v sw_vers >/dev/null 2>&1
}

IS_MACOS=false
if is_macos; then
    IS_MACOS=true
fi

resolve_home() {
    local user="$1"
    local home=""
    if command -v getent >/dev/null 2>&1; then
        home="$(getent passwd "$user" | cut -d: -f6)"
    fi
    if [[ -z "$home" ]] && $IS_MACOS && command -v dscl >/dev/null 2>&1; then
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
    error "Could not resolve HOME for '$TARGET_USER'. Set BUGTRACEAI_LAUNCHER_DIR or run without sudo."
    exit 1
fi

LAUNCHER_DIR="${BUGTRACEAI_LAUNCHER_DIR:-$TARGET_HOME/bugtraceai-launcher}"

if [[ "$IS_MACOS" == true && $EUID -eq 0 ]]; then
    error "On macOS, do not run this installer with sudo/root. Run as your normal user."
    exit 1
fi

run_privileged() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

run_as_target() {
    if [[ $EUID -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
        sudo -u "$TARGET_USER" "$@"
    else
        "$@"
    fi
}

exec_as_target() {
    if [[ $EUID -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
        exec sudo -u "$TARGET_USER" "$@"
    else
        exec "$@"
    fi
}

detect_brew() {
    if command -v brew >/dev/null 2>&1; then
        command -v brew
        return 0
    fi
    if [[ -x /opt/homebrew/bin/brew ]]; then
        echo "/opt/homebrew/bin/brew"
        return 0
    fi
    if [[ -x /usr/local/bin/brew ]]; then
        echo "/usr/local/bin/brew"
        return 0
    fi
    return 1
}

ensure_homebrew() {
    local brew_bin
    if brew_bin="$(detect_brew)"; then
        echo "$brew_bin"
        return 0
    fi

    warn "Homebrew is required to auto-install dependencies on macOS."
    read -rp "$(echo -e "${YELLOW}Install Homebrew now? [Y/n]: ${NC}")" confirm
    if [[ "${confirm:-}" =~ ^[Nn]$ ]]; then
        return 1
    fi

    run_as_target env NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    brew_bin="$(detect_brew)" || return 1
    echo "$brew_bin"
}

ensure_basic_tools() {
    local missing=()
    local cmd
    for cmd in git curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    warn "Missing required tools: ${missing[*]}"

    if $IS_MACOS; then
        local brew_bin
        brew_bin="$(ensure_homebrew)" || {
            error "Cannot continue without: ${missing[*]}"
            return 1
        }
        info "Installing tools with Homebrew..."
        run_as_target "$brew_bin" install "${missing[@]}"
        return 0
    fi

    # Pick the first available package manager (Debian/Ubuntu, Fedora/RHEL,
    # Arch, openSUSE). Falls back to a manual-install message otherwise.
    if command -v apt-get >/dev/null 2>&1; then
        info "Installing tools with apt-get..."
        run_privileged apt-get update -qq
        run_privileged apt-get install -y "${missing[@]}"
        return 0
    elif command -v dnf >/dev/null 2>&1; then
        info "Installing tools with dnf..."
        run_privileged dnf install -y "${missing[@]}"
        return 0
    elif command -v yum >/dev/null 2>&1; then
        info "Installing tools with yum..."
        run_privileged yum install -y "${missing[@]}"
        return 0
    elif command -v pacman >/dev/null 2>&1; then
        info "Installing tools with pacman..."
        # -Syu (not -Sy) to avoid Arch's partial-upgrade breakage.
        run_privileged pacman -Syu --noconfirm "${missing[@]}"
        return 0
    elif command -v zypper >/dev/null 2>&1; then
        info "Installing tools with zypper..."
        run_privileged zypper install -y "${missing[@]}"
        return 0
    fi

    error "Please install manually: ${missing[*]}"
    return 1
}

install_or_update_launcher() {
    if [[ -d "$LAUNCHER_DIR/.git" ]]; then
        info "Launcher already exists at $LAUNCHER_DIR, updating..."
        if run_as_target git -C "$LAUNCHER_DIR" fetch --depth 1 origin main --quiet && \
           run_as_target git -C "$LAUNCHER_DIR" reset --hard FETCH_HEAD --quiet; then
            return 0
        fi

        warn "Could not refresh launcher repo automatically; using existing checkout."
        return 0
    fi

    info "Cloning BugTraceAI Launcher into $LAUNCHER_DIR..."
    run_as_target mkdir -p "$(dirname "$LAUNCHER_DIR")"
    run_as_target git clone --depth 1 "$REPO_URL" "$LAUNCHER_DIR"
}

fix_permissions_if_needed() {
    if [[ $EUID -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
        chown -R "$TARGET_USER" "$LAUNCHER_DIR"
    fi
}

launch_wizard() {
    chmod +x "$LAUNCHER_DIR/launcher.sh"

    local use_ai="N"

    if command -v python3 >/dev/null 2>&1 && [[ -f "$LAUNCHER_DIR/ai_installer.py" ]]; then
        chmod +x "$LAUNCHER_DIR/ai_installer.py"

        echo ""
        echo -e "${YELLOW}${BOLD}Try the AI Setup & Repair Assistant (Experimental — installs & troubleshoots)? [y/N]${NC}"
        if [[ -t 0 ]]; then
            read -rp ">> " use_ai
        elif [[ -c /dev/tty ]]; then
            read -rp ">> " use_ai </dev/tty
        else
            warn "No interactive TTY available; using standard installer."
            use_ai="N"
        fi
    else
        info "Python3 or AI installer not found; using standard installer..."
    fi

    if [[ "${use_ai:-}" =~ ^[Yy]$ ]]; then
        info "Starting AI Setup & Repair Assistant (DeepSeek V3 · Haiku 4.5 fallback)..."
        exec_as_target python3 "$LAUNCHER_DIR/ai_installer.py"
    else
        info "Starting BugTraceAI standard setup wizard..."
        exec_as_target env BUGTRACEAI_SKIP_AI_PROMPT=1 "$LAUNCHER_DIR/launcher.sh"
    fi
}

echo ""
echo -e "${CYAN}${BOLD}BugTraceAI Bootstrap Installer${NC}"
echo ""

ensure_basic_tools
install_or_update_launcher
fix_permissions_if_needed

echo ""
success "Launcher is ready at: $LAUNCHER_DIR"
echo -e "  ${DIM}The launcher will handle Docker/Colima runtime setup and dependency checks.${NC}"
echo ""

launch_wizard
