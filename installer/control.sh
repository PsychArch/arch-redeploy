#!/bin/bash

set -Eeuo pipefail

readonly CURRENT_STAGE=${ARCH_REDEPLOY_CURRENT_STAGE:-/run/arch-redeploy-current-stage}
readonly CANCEL_REQUEST=${ARCH_REDEPLOY_CANCEL_REQUEST:-/run/arch-redeploy-cancel}
readonly ERASE_STARTED=${ARCH_REDEPLOY_ERASE_STARTED:-/run/arch-redeploy-erase-started}
readonly BOUNDARY_LOCK=${ARCH_REDEPLOY_BOUNDARY_LOCK:-/run/arch-redeploy-boundary.lock}
readonly STAGES_LIBRARY=${ARCH_REDEPLOY_STAGES_LIBRARY:-/usr/local/lib/arch-redeploy/stages.sh}

# shellcheck source=lib/stages.sh
source "$STAGES_LIBRARY"

usage() {
    cat <<'EOF'
Usage: arch-redeploy COMMAND

Commands available in the recovery environment:
  status    Show the redeploy timeline
  cancel    Return to the source system if disk erasure has not begun
  help      Show this help
EOF
}

case ${1:-status} in
    status)
        current=$(cat "$CURRENT_STAGE" 2>/dev/null || echo revalidate)
        ra_render_timeline "$current"
        ;;
    cancel)
        exec 9>"$BOUNDARY_LOCK"
        flock 9
        if [[ -e $ERASE_STARTED ]]; then
            echo "The source disk has already been erased; cancellation cannot restore it." >&2
            echo "Use the recovery shell to diagnose the failure and resume installation." >&2
            exit 1
        fi
        : >"$CANCEL_REQUEST"
        chmod 0600 "$CANCEL_REQUEST"
        echo "Cancellation requested. Recovery will reboot to the untouched source system."
        ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
