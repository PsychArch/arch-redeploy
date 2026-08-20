#!/usr/bin/env bash

[[ ${RA_COMMON_LOADED:-} == 1 ]] && return 0
RA_COMMON_LOADED=1

set -Eeuo pipefail

# shellcheck disable=SC2034
readonly RA_VERSION="0.2.0"
# shellcheck disable=SC2034
readonly RA_PROTOCOL_VERSION="2"
# shellcheck disable=SC2034
readonly RA_ALPINE_BRANCH="v3.24"
# shellcheck disable=SC2034
readonly RA_ALPINE_VERSION="3.24.1"
# shellcheck disable=SC2034
readonly RA_ARCH="x86_64"

RA_PROJECT_ROOT=${RA_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
RA_STATE_DIR=${ARCH_REDEPLOY_STATE_DIR:-/var/lib/arch-redeploy}
RA_STATE_FILE="$RA_STATE_DIR/state.json"
RA_LOCK_FILE=${ARCH_REDEPLOY_LOCK_FILE:-/run/lock/arch-redeploy.lock}
# shellcheck disable=SC2034
RA_BOOT_DIR=${ARCH_REDEPLOY_BOOT_DIR:-/boot/arch-redeploy}

ra_validate_runtime_paths() {
    local path
    for path in "$RA_STATE_DIR" "$RA_BOOT_DIR"; do
        [[ $path == /* && $path != / ]] || ra_die "unsafe project path: $path"
        case "$path" in
            /boot|/dev|/etc|/home|/proc|/root|/run|/sys|/tmp|/usr|/var)
                ra_die "refusing to use protected directory: $path"
                ;;
        esac
        [[ ! -L $path ]] || ra_die "project directories may not be symbolic links: $path"
    done
    [[ $(basename -- "$RA_STATE_DIR") == arch-redeploy || $RA_STATE_DIR == /tmp/arch-redeploy-*/state ]] ||
        ra_die "state directory must end in /arch-redeploy (temporary smoke paths are the only exception)"
    [[ $(basename -- "$RA_BOOT_DIR") == arch-redeploy || $RA_BOOT_DIR == /tmp/arch-redeploy-*/boot ]] ||
        ra_die "boot-artifact directory must end in /arch-redeploy (temporary smoke paths are the only exception)"
}

ra_color() {
    local code=$1
    shift
    if [[ -t 2 && -z ${NO_COLOR:-} ]]; then
        printf '\033[%sm%s\033[0m\n' "$code" "$*" >&2
    else
        printf '%s\n' "$*" >&2
    fi
}

ra_info() { ra_color 32 "==> $*"; }
ra_warn() { ra_color 33 "warning: $*"; }
ra_error() { ra_color 31 "error: $*"; }
ra_die() {
    ra_error "$*"
    exit 1
}

ra_require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || ra_die "run this command as root"
}

ra_require_commands() {
    local missing=() command_name
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    ((${#missing[@]} == 0)) || ra_die "missing required commands: ${missing[*]}"
}

ra_confirm() {
    local prompt=$1 reply
    read -r -p "$prompt [y/N] " reply
    [[ $reply == [Yy] || $reply == [Yy][Ee][Ss] ]]
}

ra_prompt_default() {
    local prompt=$1 default=$2 reply
    read -r -p "$prompt [$default]: " reply
    printf '%s' "${reply:-$default}"
}

ra_sha256() {
    sha256sum -- "$1" | awk '{print $1}'
}

ra_bytes() {
    stat -c '%s' -- "$1"
}

ra_human_bytes() {
    numfmt --to=iec-i --suffix=B "$1"
}

ra_boot_memory_required() {
    local initramfs_bytes=$1 kernel_bytes=$2 payload_bytes=${3:-0}
    printf '%s' "$((payload_bytes + 2 * (initramfs_bytes + kernel_bytes) + 384 * 1024 * 1024))"
}

ra_online_mirror_count_valid() {
    local mirrors_json=$1
    [[ $(jq 'length' <<<"$mirrors_json") -ge 2 ]]
}

ra_state_transition_allowed() {
    local current=$1 next=$2
    case "$current:$next" in
        preparing:prepared|prepared:scheduled) return 0 ;;
        *) return 1 ;;
    esac
}

ra_atomic_json() {
    local destination=$1 temporary
    mkdir -p -- "$(dirname -- "$destination")"
    temporary=$(mktemp "${destination}.XXXXXX")
    if ! cat >"$temporary" || ! jq -e . "$temporary" >/dev/null; then
        rm -f "$temporary"
        return 1
    fi
    chmod 0600 "$temporary" || { rm -f "$temporary"; return 1; }
    mv -f -- "$temporary" "$destination"
}

ra_state_exists() { [[ -f $RA_STATE_FILE ]]; }

ra_state_get() {
    jq -er "$1" "$RA_STATE_FILE"
}

ra_state_update() {
    local filter=$1 temporary
    shift
    temporary=$(mktemp "$RA_STATE_DIR/state.XXXXXX")
    if ! jq "$filter" "$@" "$RA_STATE_FILE" >"$temporary" ||
        ! jq -e . "$temporary" >/dev/null; then
        rm -f "$temporary"
        return 1
    fi
    chmod 0600 "$temporary" || { rm -f "$temporary"; return 1; }
    mv -f -- "$temporary" "$RA_STATE_FILE"
}

ra_acquire_lock() {
    ra_validate_runtime_paths
    [[ $RA_LOCK_FILE == /* && $RA_LOCK_FILE != / ]] ||
        ra_die "unsafe operation lock path: $RA_LOCK_FILE"
    mkdir -p "$(dirname "$RA_LOCK_FILE")"
    [[ ! -L $RA_LOCK_FILE ]] || ra_die "operation lock may not be a symbolic link"
    exec 9>"$RA_LOCK_FILE"
    flock -n 9 || ra_die "another arch-redeploy operation is running"
}

ra_tempdir() {
    mkdir -p "$RA_STATE_DIR/tmp"
    chmod 0700 "$RA_STATE_DIR/tmp"
    mktemp -d "$RA_STATE_DIR/tmp/$1.XXXXXX"
}

ra_cleanup_mounts() {
    local root=${1:-}
    [[ -n $root ]] || return 0
    if mountpoint -q "$root/target"; then umount -R "$root/target" || true; fi
    if mountpoint -q "$root/dev"; then umount -R "$root/dev" || true; fi
    if mountpoint -q "$root/proc"; then umount -R "$root/proc" || true; fi
    if mountpoint -q "$root/sys"; then umount -R "$root/sys" || true; fi
}

ra_json_array_from_lines() {
    jq -Rsc 'split("\n") | map(select(length > 0))'
}
