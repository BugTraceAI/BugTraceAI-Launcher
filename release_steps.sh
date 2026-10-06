#!/usr/bin/env bash
# Internal source-patch adapter. Runtime lifecycle is owned by release_runtime.py.
set -eo pipefail
release_launcher="$1"
release_action="$2"
release_state="$3"
release_cli="$4"
release_web="$5"
release_api="$6"
release_key="${7:-}"
source "$release_launcher"
STATE_FILE="$release_state"
load_state || exit 1
CLI_DIR="$release_cli" WEB_DIR="$release_web" BTAI_DIR="$release_api"
RECON_DIR="$(dirname "$release_web")/reconftw-mcp"

case "$release_action" in
    patch)
        patch_btai_compose || exit 1
        patch_compose || exit 1 ;;
    validate)
        case "$release_key" in
            cli) _restore_cli_compose_patch_for_update || exit 1 ;;
            web)
                _restore_web_compose_patches_for_update || exit 1
                _restore_web_npm_patch_for_update || exit 1 ;;
            api)
                if ! git -C "$BTAI_DIR" diff --quiet -- docker-compose.yml; then
                    release_prediction="$(mktemp -d)"
                    git -C "$BTAI_DIR" show HEAD:docker-compose.yml > "$release_prediction/docker-compose.yml"
                    release_original="$BTAI_DIR"
                    BTAI_DIR="$release_prediction"
                    patch_btai_compose || exit 1
                    BTAI_DIR="$release_original"
                    if ! cmp -s "$release_prediction/docker-compose.yml" "$BTAI_DIR/docker-compose.yml"; then
                        rm -rf "$release_prediction"
                        error 'API Compose contains edits beyond the Launcher patch; local edits were preserved.'
                        exit 1
                    fi
                    rm -rf "$release_prediction"
                    git -C "$BTAI_DIR" show HEAD:docker-compose.yml > "$BTAI_DIR/docker-compose.yml"
                fi ;;
            *) exit 2 ;;
        esac ;;
    verify) health_checks ;;
    *) exit 2 ;;
esac
