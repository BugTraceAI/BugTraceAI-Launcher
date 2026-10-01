#!/usr/bin/env bash
# Regression checks for deployment-directory recovery during reinstall.
set -eo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$test_dir/launcher.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

scratch_dir="$(mktemp -d)"
trap 'rm -rf -- "$scratch_dir"' EXIT

# The full deployment must enter the recreated target before its first clone.
# This is what makes a reinstall safe when the command was invoked from the
# directory that has just been replaced.
INSTALL_DIR="$scratch_dir/bugtraceai"
clone_repos() {
    [[ "$(pwd -P)" == "$INSTALL_DIR" ]] || fail "deployment did not enter recreated install directory before cloning"
}
generate_env() { :; }
patch_compose() { :; }
start_services() { :; }
health_checks() { :; }
save_state() { :; }
show_success() { :; }

# Reproduce a launcher started from the directory the reinstall replaces.
# Without deploy's `cd "$INSTALL_DIR"`, Git would inherit this deleted CWD.
mkdir -p "$INSTALL_DIR"
(
    cd "$INSTALL_DIR"
    rmdir "$INSTALL_DIR"
    deploy
)
[[ -d "$INSTALL_DIR" ]] || fail "deployment did not create install directory"

printf 'Launcher install-directory regression checks passed.\n'
