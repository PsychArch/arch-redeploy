#!/usr/bin/env bash

set -Eeuo pipefail

smoke_error() {
    local status=$1
    printf 'builder smoke failed near line %s: %s (status %s)\n' \
        "${BASH_LINENO[0]}" "$BASH_COMMAND" "$status" >&2
}
# shellcheck disable=SC2016 # trap-time status must be expanded when ERR fires.
trap 'smoke_error "$?"' ERR

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SMOKE_ROOT=${ARCH_REDEPLOY_SMOKE_ROOT:-/tmp/arch-redeploy-builder-smoke}

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
    printf 'run this isolated smoke test as root inside a disposable container\n' >&2
    exit 1
}
[[ $(dirname -- "$SMOKE_ROOT") == /tmp && $(basename -- "$SMOKE_ROOT") == arch-redeploy-* && $SMOKE_ROOT != *..* ]] || {
    printf 'unsafe smoke-test directory: %s\n' "$SMOKE_ROOT" >&2
    exit 1
}

export RA_PROJECT_ROOT=$PROJECT_ROOT
export ARCH_REDEPLOY_STATE_DIR="$SMOKE_ROOT/state"
export ARCH_REDEPLOY_BOOT_DIR="$SMOKE_ROOT/boot"

# shellcheck source=lib/common.sh
source "$PROJECT_ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$PROJECT_ROOT/lib/detect.sh"
# shellcheck source=lib/mirrors.sh
source "$PROJECT_ROOT/lib/mirrors.sh"
# shellcheck source=lib/build.sh
source "$PROJECT_ROOT/lib/build.sh"

rm -rf "$SMOKE_ROOT"
mkdir -p "$RA_STATE_DIR"
chmod 0700 "$RA_STATE_DIR"
jq -n '
  {
    protocol:"2",
    state:"preparing",
    host:{virtual:true},
    boot:{mode:"bios"},
    identity:{hostname:"builder-smoke", timezone:"UTC"},
    admin:{user:"root", port:22, authorized_keys:"", password_hash:"!"},
    network:{ipv4:{mode:"none"}, ipv6:{mode:"none"}, dns:[]},
    mirrors:{
      alpine:"https://dl-cdn.alpinelinux.org/alpine",
      arch:["https://fastly.mirror.pkgbuild.com", "https://geo.mirror.pkgbuild.com"]
    },
    payload:{mode:"undecided", packages:[]}
  }
' | ra_atomic_json "$RA_STATE_FILE"

work="$SMOKE_ROOT/work"
mkdir -p "$work"
cleanup() {
    if declare -F target_unmount_pseudo >/dev/null; then
        target_unmount_pseudo "$work/arch-root" 2>/dev/null || true
    fi
    ra_unmount_builder_root "$work/alpine"
    rm -rf "$SMOKE_ROOT"
}
trap cleanup EXIT

packages_json=$(ra_target_packages_json)
ra_build_alpine_root "$work"
ra_write_package_lock "$work/alpine" "$packages_json"
test -s "$work/alpine/etc/arch-redeploy/packages.lock"
pacman-key --gpgdir "$work/alpine/etc/pacman.d/gnupg" --list-keys >/dev/null

if [[ ${RA_SMOKE_FULL:-0} == 1 ]]; then
    ra_build_arch_payload "$work" "$work/alpine" "$packages_json" "$work/rootfs.tar.zst"
    zstd -q -t "$work/rootfs.tar.zst"
fi

printf 'builder smoke test passed (%s)\n' "$([[ ${RA_SMOKE_FULL:-0} == 1 ]] && echo full || echo bootstrap)"
