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

# WEB installs with extras still run the core MCP from the CLI Compose project;
# WEB owns only recon and Kali profiles.
INSTALL_CLI=false
resolve_web_mcp_profiles
assert_array "web-only profiles" --profile recon --profile kali

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
BTAI_MCP_PORT=39106
LLM_PROVIDER=openrouter
API_KEY_ENV_VAR=OPENROUTER_API_KEY
API_KEY=fixture-key
generate_env >/dev/null
grep -Fq 'FRONTEND_PORT=39169' "$WEB_DIR/.env.docker" || fail "WEB frontend port was not generated"
grep -Fq 'BTAI_API_PORT=39105' "$WEB_DIR/.env.docker" || fail "WEB API port was not generated"
grep -Fq 'CLI_API_PORT=39104' "$WEB_DIR/.env.docker" || fail "WEB CLI API port was not generated"
grep -Fq 'BTAI_SHARED_NETWORK=bugtraceai-platform' "$WEB_DIR/.env.docker" || fail "WEB/API shared network was not generated"
grep -Fq 'MCP_PORT=39106' "$BTAI_DIR/.env" || fail "API MCP port was not generated"
grep -Fq 'API_PORT=39105' "$BTAI_DIR/.env" || fail "API REST port was not generated"
grep -Fq 'BTAI_SHARED_NETWORK=bugtraceai-platform' "$BTAI_DIR/.env" || fail "API shared network was not generated"

# WEB+API without a local CLI still satisfies the public Compose contract with
# a numeric placeholder. The optional CLI proxy is made lazy so nginx does not
# fail during configuration just because no CLI container was selected.
web_only_dir="$scratch_dir/web-only"
WEB_DIR="$web_only_dir/BugTraceAI-WEB"
BTAI_DIR="$web_only_dir/BugTraceAI-API"
mkdir -p "$WEB_DIR" "$BTAI_DIR"
cat > "$WEB_DIR/nginx.conf" <<'EOF'
http {
    resolver 127.0.0.11;
    location ^~ /cli-api/ {
        proxy_pass http://bugtrace-cli-api:${CLI_API_PORT}/;
    }
}
EOF
INSTALL_WEB=true
INSTALL_BTAI=true
INSTALL_CLI=false
MCP_CLI_ENABLED=false
WEB_PORT=39169
CLI_PORT=""
BTAI_PORT=39105
BTAI_MCP_PORT=39106
generate_env >/dev/null
grep -Fq 'CLI_API_PORT=8000' "$WEB_DIR/.env.docker" || fail "WEB-only CLI placeholder was not generated"
patch_optional_web_cli_proxy
grep -Fq 'set $cli_api_host bugtrace-cli-api;' "$WEB_DIR/nginx.conf" || fail "WEB-only CLI proxy was not made lazy"

# A bare curl timeout is not proof that an SSE listener answered.
curl() { return 28; }
if wait_for_url http://127.0.0.1:1/sse "unresponsive SSE" 1 sse >/dev/null 2>&1; then
    fail "unresponsive SSE timeout was accepted as healthy"
fi
unset -f curl

# API ports are selected before the other MCP ports. They must reserve their
# values so a later prompt cannot accept a duplicate host binding.
port_available "$BTAI_PORT" && fail "BugTraceAI-API REST port was not reserved"
port_available "$BTAI_MCP_PORT" && fail "BugTraceAI-API MCP port was not reserved"

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

# ARM hosts exercise the boundary case where the recon service is immediately
# followed by the root-level volumes/networks mappings. The injected service
# keys must stay inside reconftw-mcp; otherwise Compose reports the same
# go-yaml block-mapping error seen during a real WEB startup.
arm_web_dir="$scratch_dir/arm-web"
mkdir -p "$arm_web_dir"
cat > "$arm_web_dir/docker-compose.yml" <<'EOF'
services:
  reconftw-mcp:
    image: reconftw-mcp:local
    container_name: reconftw-mcp
    profiles:
      - recon
    command: ["mcp", "--sse"]
    environment:
      - MCP_PORT=8002
    healthcheck:
      test: ["CMD", "true"]
      retries: 3
      start_period: 60s
    networks:
      - bugtraceai-network
volumes:
  reconftw-output:
networks:
  bugtraceai-network:
EOF
INSTALL_WEB=true
WEB_DIR="$arm_web_dir"
INSTALL_CLI=false
MCP_CLI_ENABLED=false
MCP_RECON_ENABLED=true
MCP_KALI_ENABLED=false
RECON_PORT=41002
MCP_PORT=41001
(
    uname() { printf 'arm64\n'; }
    patch_compose
)
grep -Fq '    platform: linux/amd64' "$arm_web_dir/docker-compose.yml" || fail "ARM recon platform was not kept inside the service"
grep -Fq '    pull_policy: build' "$arm_web_dir/docker-compose.yml" || fail "ARM recon pull policy was not kept inside the service"
volumes_line="$(grep -n '^volumes:$' "$arm_web_dir/docker-compose.yml" | head -1 | cut -d: -f1)"
if [[ -n "$volumes_line" ]] && tail -n +"$volumes_line" "$arm_web_dir/docker-compose.yml" | grep -q 'platform:'; then
    fail "ARM recon patch leaked service keys into volumes"
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose -f "$fixture" config --quiet
    docker compose -f "$arm_web_dir/docker-compose.yml" config --quiet

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
grep -Fq '"bugtraceai-api"' "$config_file" || fail "BugTraceAI-API MCP endpoint missing"
grep -Fq 'http://localhost:39106/mcp' "$config_file" || fail "BugTraceAI-API MCP endpoint has wrong URL"
grep -Fq '"reconftw"' "$config_file" || fail "recon MCP endpoint missing"
if grep -Fq '"kali"' "$config_file"; then
    fail "Kali toolbox was emitted as an MCP endpoint"
fi

# Full mode starts the standalone API first. CLI cleanup may remove old CLI
# names, but must not remove the API container it has just started.
service_fixture="$scratch_dir/service-startup"
mkdir -p "$service_fixture/BugTraceAI-API" "$service_fixture/BugTraceAI-CLI"
: > "$service_fixture/BugTraceAI-API/docker-compose.yml"
: > "$service_fixture/BugTraceAI-CLI/docker-compose.yml"
BTAI_DIR="$service_fixture/BugTraceAI-API"
CLI_DIR="$service_fixture/BugTraceAI-CLI"
INSTALL_DIR="$service_fixture"
INSTALL_WEB=false
INSTALL_CLI=true
INSTALL_BTAI=true
MCP_CLI_ENABLED=true
MCP_RECON_ENABLED=false
MCP_KALI_ENABLED=false
api_started=false
docker() {
    if [[ "$1" == "rm" && "$api_started" == true && " $* " == *" bugtrace-api "* ]]; then
        fail "CLI startup removed the standalone BugTraceAI-API container"
    fi
    return 0
}
_build_with_progress() {
    [[ "$1" == "BugTraceAI-API" ]] && api_started=true
    return 0
}
start_services >/dev/null
unset -f docker _build_with_progress

# A failed health check must stop the deployment before state/success are
# written. This reproduces the old false-success path with no Docker calls.
failure_fixture="$scratch_dir/health-failure"
INSTALL_DIR="$failure_fixture"
STATE_FILE="$failure_fixture/.launcher-state"
INSTALL_BTAI=true
INSTALL_WEB=false
INSTALL_CLI=false
BTAI_PORT=39105
BTAI_MCP_PORT=39106
clone_repos() { :; }
generate_env() { :; }
patch_compose() { :; }
start_services() { :; }
wait_for_url() { return 1; }
show_success() { fail "success banner was shown after failed health checks"; }
if deploy >/dev/null 2>&1; then
    fail "deployment returned success after failed health checks"
fi
[[ ! -e "$STATE_FILE" ]] || fail "state was saved after failed health checks"
unset -f clone_repos generate_env patch_compose start_services wait_for_url show_success
cd "$test_dir"

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
