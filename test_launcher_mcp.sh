#!/usr/bin/env bash
# Regression checks for the standard (non-AI) installer's optional agents.
set -eo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$test_dir/launcher.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# API/Web ports are selected by the launcher and written into generated env
# files. Keep this contract visible in the regression suite so a future change
# cannot silently reintroduce fixed service ports in the integration.
grep -Fq 'MCP_PORT=${BTAI_MCP_PORT}' "$test_dir/launcher.sh" || fail "API MCP port is not sourced from launcher selection"
grep -Fq 'API_PORT=${BTAI_PORT}' "$test_dir/launcher.sh" || fail "API REST port is not sourced from launcher selection"
grep -Fq 'BTAI_API_PORT=${BTAI_PORT}' "$test_dir/launcher.sh" || fail "WEB API proxy port is not sourced from launcher selection"
if grep -Eq 'MCP_HOST_PORT=|API_HOST_PORT=|patch_web_btai_proxy' "$test_dir/launcher.sh"; then
    fail "launcher contains a legacy fixed-port patch path"
fi

assert_array() {
    local expected_name=$1
    shift
    local -a expected=("$@")
    local -a actual=("${WEB_MCP_PROFILE_ARGS[@]}")
    [[ ${#actual[@]} -eq ${#expected[@]} ]] || fail "$expected_name has wrong length"
    local index
    for index in "${!expected[@]}"; do
        [[ "${actual[$index]}" == "${expected[$index]}" ]] || fail "$expected_name differs at $index"
    done
}

# Full installs run the core MCP from the CLI compose project; only recon and
# Kali are WEB profiles.  That prevents two core-MCP containers from racing.
INSTALL_WEB=true
INSTALL_CLI=true
MCP_CLI_ENABLED=true
MCP_RECON_ENABLED=true
MCP_KALI_ENABLED=true
resolve_web_mcp_profiles
assert_array "full-install profiles" --profile recon --profile kali

# WEB-only installs need all three WEB-owned profiles explicitly.
INSTALL_CLI=false
resolve_web_mcp_profiles
assert_array "web-only profiles" --profile cli --profile recon --profile kali

# The launcher must never persist a non-empty Compose profile selection. An
# empty one-shot override inside _web_compose is intentional: it neutralizes
# stale values read from a legacy .env.docker.
if grep -Eq '^[[:space:]]*(export[[:space:]]+)?COMPOSE_PROFILES=[^[:space:]]+' "$test_dir/launcher.sh"; then
    fail "launcher persists COMPOSE_PROFILES"
fi

scratch_dir="$(mktemp -d)"
trap 'rm -rf -- "$scratch_dir"' EXIT

# Exercise the actual env generation with arbitrary selected ports. This is
# stronger than checking source text: Compose-facing files must receive the
# values chosen by the launcher, not the wizard's proposal defaults.
port_fixture="$scratch_dir/port-wiring"
INSTALL_DIR="$port_fixture"
WEB_DIR="$port_fixture/BugTraceAI-WEB"
BTAI_DIR="$port_fixture/BugTraceAI-API"
mkdir -p "$WEB_DIR" "$BTAI_DIR"
INSTALL_WEB=true
INSTALL_BTAI=true
INSTALL_CLI=false
MCP_CLI_ENABLED=false
MCP_RECON_ENABLED=false
WEB_PORT=39169
CLI_PORT=39104
BTAI_PORT=39105
BTAI_MCP_PORT=39104
LLM_PROVIDER=openrouter
API_KEY_ENV_VAR=OPENROUTER_API_KEY
API_KEY=fixture-key
generate_env >/dev/null
grep -Fq 'FRONTEND_PORT=39169' "$WEB_DIR/.env.docker" || fail "WEB frontend port was not generated"
grep -Fq 'BTAI_API_PORT=39105' "$WEB_DIR/.env.docker" || fail "WEB API port was not generated"
grep -Fq 'CLI_API_PORT=39104' "$WEB_DIR/.env.docker" || fail "WEB CLI API port was not generated"
grep -Fq 'BTAI_SHARED_NETWORK=bugtraceai-platform' "$WEB_DIR/.env.docker" || fail "WEB/API shared network was not generated"
grep -Fq 'MCP_PORT=39104' "$BTAI_DIR/.env" || fail "API MCP port was not generated"
grep -Fq 'API_PORT=39105' "$BTAI_DIR/.env" || fail "API REST port was not generated"
grep -Fq 'BTAI_SHARED_NETWORK=bugtraceai-platform' "$BTAI_DIR/.env" || fail "API shared network was not generated"

fixture="$scratch_dir/kali-compose.yml"
cp "$test_dir/testdata/kali-compose-inline.yml" "$fixture"
ensure_kali_startup_command "$fixture"

grep -Fq 'command:' "$fixture" || fail "Kali command is absent"
grep -Fq 'if [ $$attempt -eq 3 ]; then' "$fixture" || fail "Kali retry variable is not Compose-escaped"
grep -Fq 'Required Kali tools are unavailable.' "$fixture" || fail "Kali tool verification is absent"
grep -Fq "exec tail -f /dev/null" "$fixture" || fail "Kali toolbox does not stay running"
if grep -Fq 'command: ["bash", "-c", "old startup command"]' "$fixture"; then
    fail "old inline Kali command survived"
fi

# Public WEB compose names recon `reconftw-mcp:local` with no build. The launcher
# must add a local build context so Compose does not try to pull that tag.
public_recon="$scratch_dir/public-recon.yml"
cp "$test_dir/testdata/public-recon-image-only.yml" "$public_recon"
ensure_recon_local_build "$public_recon"
grep -Fq 'context: ../reconftw-mcp' "$public_recon" || fail "public recon compose did not get a local build context"
grep -Fq 'pull_policy: build' "$public_recon" || fail "public recon compose did not pin pull_policy: build"
ensure_recon_local_build "$public_recon"
pull_count="$(grep -c 'pull_policy: build' "$public_recon")"
[[ "$pull_count" -eq 1 ]] || fail "ensure_recon_local_build is not idempotent ($pull_count pull_policy lines)"

private_recon="$scratch_dir/private-recon.yml"
cat > "$private_recon" <<'EOF'
services:
  reconftw-mcp:
    build:
      context: ../reconftw-mcp
      dockerfile: Dockerfile
    container_name: reconftw-mcp
    profiles:
      - recon
EOF
ensure_recon_local_build "$private_recon"
build_count="$(grep -c 'context: ../reconftw-mcp' "$private_recon")"
[[ "$build_count" -eq 1 ]] || fail "existing recon build context was duplicated"
grep -Fq 'pull_policy: build' "$private_recon" || fail "private recon compose did not get pull_policy"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose -f "$fixture" config --quiet

    # Even if a caller exports COMPOSE_PROFILES, the base helper must leave
    # optional profiles disabled until explicit --profile flags are supplied.
    cp "$fixture" "$scratch_dir/docker-compose.yml"
    WEB_DIR="$scratch_dir"
    CLI_DIR="$scratch_dir/no-cli"
    RECON_PORT=41002
    MCP_PORT=41001
    printf 'COMPOSE_PROFILES=recon,kali\n' > "$scratch_dir/.env.docker"
    patch_compose
    if grep -Fq 'COMPOSE_PROFILES=' "$scratch_dir/.env.docker"; then
        fail "legacy COMPOSE_PROFILES was not removed"
    fi
    # Simulate a pre-existing installation that has not run update yet: the
    # helper must neutralize a legacy profile value even when --env-file reads
    # it itself (not merely when it is inherited from the caller environment).
    printf 'COMPOSE_PROFILES=recon,kali\n' >> "$scratch_dir/.env.docker"
    COMPOSE_CMD='docker compose'
    base_services="$(COMPOSE_PROFILES='recon,kali' _web_compose config --services)"
    grep -Fxq 'kali-mcp' <<< "$base_services" && fail "base WEB startup activated Kali profile"
    grep -Fxq 'reconftw-mcp' <<< "$base_services" && fail "base WEB startup activated recon profile"

    selected_services="$(_web_compose --profile recon --profile kali config --services)"
    grep -Fxq 'kali-mcp' <<< "$selected_services" || fail "explicit Kali profile was not selected"
    grep -Fxq 'reconftw-mcp' <<< "$selected_services" || fail "explicit recon profile was not selected"
fi

# A prior interrupted installation can have launcher state but no sibling
# reconftw-mcp source directory. The launcher must restore that context before
# Compose sees the `../reconftw-mcp` build path. Mock git to keep this test
# hermetic and to prove no network access is needed for the regression suite.
WEB_DIR="$scratch_dir/BugTraceAI-WEB"
RECON_DIR="$scratch_dir/reconftw-mcp"
mkdir -p "$WEB_DIR"
clone_calls=0
git() {
    if [[ "$1" == "clone" ]]; then
        clone_calls=$((clone_calls + 1))
        mkdir -p "${!#}"
        : > "${!#}/Dockerfile"
        return 0
    fi
    command git "$@"
}
ensure_recon_source >/dev/null || fail "missing recon source was not restored"
[[ "$clone_calls" -eq 1 ]] || fail "missing recon source did not trigger exactly one restore"
recon_source_ready || fail "restored recon source is not a valid Compose context"

# Do not destroy an existing incomplete directory: that may be user data.
RECON_DIR="$scratch_dir/partial-reconftw-mcp"
mkdir -p "$RECON_DIR"
if ensure_recon_source >/dev/null 2>&1; then
    fail "incomplete recon source was accepted"
fi
[[ "$clone_calls" -eq 1 ]] || fail "incomplete recon source was overwritten"

# Kali is a toolbox image rather than an HTTP/SSE MCP server.  Do not emit a
# fake endpoint for it in a client configuration.
INSTALL_DIR="$scratch_dir"
MCP_PORT=41001
RECON_PORT=41002
MCP_CLI_ENABLED=true
MCP_RECON_ENABLED=true
MCP_KALI_ENABLED=true
generate_mcp_config >/dev/null
config_file="$scratch_dir/mcp-config.json"
grep -Fq '"bugtraceai"' "$config_file" || fail "core MCP endpoint missing"
grep -Fq '"reconftw"' "$config_file" || fail "recon MCP endpoint missing"
if grep -Fq '"kali"' "$config_file"; then
    fail "Kali toolbox was emitted as an MCP endpoint"
fi

# Installer event log is opt-in when this file is sourced. A real run calls
# _init_install_log from main() and writes next to launcher.sh.
log_file="$scratch_dir/install.log"
BUGTRACEAI_INSTALL_LOG="$log_file"
INSTALL_LOG_FILE=""
_init_install_log
info "hello-event-log"
[[ -f "$log_file" ]] || fail "install log was not created"
grep -q 'hello-event-log' "$log_file" || fail "install log missing event"
grep -q '===== BugTraceAI Launcher' "$log_file" || fail "install log missing session header"
unset BUGTRACEAI_INSTALL_LOG
INSTALL_LOG_FILE=""

# Linux Docker Engine bootstrap prefers Docker's official script when curl exists.
if [[ "$(uname -s)" != "Darwin" ]]; then
    method="$(_linux_docker_install_method)"
    [[ -n "$method" ]] || fail "Linux Docker install method was empty"
    if command -v curl >/dev/null 2>&1; then
        [[ "$method" == "get.docker.com" ]] || fail "expected get.docker.com when curl exists, got $method"
    fi
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        ensure_linux_docker_engine >/dev/null || fail "ensure_linux_docker_engine should no-op when Docker already works"
    fi
fi

printf 'Launcher MCP regression checks passed.\n'
