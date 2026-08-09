#!/usr/bin/env bash

set -Eeuo pipefail

RUNTIME_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROLLBACK_STATE_DIR=$(cd -- "$RUNTIME_ROOT/.." && pwd)
[[ $ROLLBACK_STATE_DIR == /var/lib/arch-redeploy ]] || {
    echo "refusing an unexpected arch-redeploy rollback path: $ROLLBACK_STATE_DIR" >&2
    exit 1
}

export RA_PROJECT_ROOT=$RUNTIME_ROOT
export ARCH_REDEPLOY_STATE_DIR=$ROLLBACK_STATE_DIR
if [[ -r $ROLLBACK_STATE_DIR/state.json ]]; then
    rollback_boot_dir=$(jq -r '.runtime.boot_dir // "/boot/arch-redeploy"' \
        "$ROLLBACK_STATE_DIR/state.json")
    export ARCH_REDEPLOY_BOOT_DIR=$rollback_boot_dir
fi

# shellcheck source=lib/common.sh
source "$RUNTIME_ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$RUNTIME_ROOT/lib/detect.sh"
# shellcheck source=lib/boot.sh
source "$RUNTIME_ROOT/lib/boot.sh"

ra_acquire_lock
echo "arch-redeploy: the source system booted; restoring its original boot state"
ra_unschedule_boot
ra_remove_source_return_hook
rm -rf "$ROLLBACK_STATE_DIR"
echo "arch-redeploy: source rollback completed"
