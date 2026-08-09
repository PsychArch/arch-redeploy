#!/usr/bin/env bash

[[ ${RA_MIRRORS_LOADED:-} == 1 ]] && return 0
RA_MIRRORS_LOADED=1

# shellcheck source=lib/common.sh
source "$RA_PROJECT_ROOT/lib/common.sh"

readonly -a RA_ALPINE_MIRRORS=(
    "global|https://dl-cdn.alpinelinux.org/alpine"
    "china|https://mirror.nju.edu.cn/alpine"
    "china|https://mirrors.tuna.tsinghua.edu.cn/alpine"
    "china|https://mirrors.ustc.edu.cn/alpine"
)

readonly -a RA_ARCH_MIRRORS=(
    "global|https://geo.mirror.pkgbuild.com"
    "global|https://fastly.mirror.pkgbuild.com"
    "china|https://mirror.nju.edu.cn/archlinux"
    "china|https://mirrors.tuna.tsinghua.edu.cn/archlinux"
    "china|https://mirrors.ustc.edu.cn/archlinux"
)

ra_probe_url() {
    local url=$1 output elapsed http_code
    output=$(curl -LfsS --connect-timeout 10 --max-time 30 --range 0-65535 \
        -o /dev/null -w '%{time_total}\t%{http_code}' "$url" 2>/dev/null) || return 1
    IFS=$'\t' read -r elapsed http_code <<<"$output"
    [[ $http_code == 200 || $http_code == 206 ]] || return 1
    printf '%s' "$elapsed"
}

ra_probe_required_mirror_content() {
    local ecosystem=$1 base=$2 release_path archive elapsed
    case "$ecosystem" in
        alpine)
            release_path="$RA_ALPINE_BRANCH/releases/$RA_ARCH"
            archive="alpine-minirootfs-$RA_ALPINE_VERSION-$RA_ARCH.tar.gz"
            elapsed=$(ra_probe_url "$base/$release_path/$archive") || return 1
            ra_probe_url "$base/$release_path/$archive.sha256" >/dev/null || return 1
            ra_probe_url "$base/$release_path/$archive.asc" >/dev/null || return 1
            printf '%s' "$elapsed"
            ;;
        arch)
            ra_probe_url "$base/core/os/$RA_ARCH/core.db"
            ;;
        *) return 1 ;;
    esac
}

ra_probe_mirror_set() {
    local ecosystem=$1 entry region base elapsed
    local -a entries
    case "$ecosystem" in
        alpine) entries=("${RA_ALPINE_MIRRORS[@]}") ;;
        arch) entries=("${RA_ARCH_MIRRORS[@]}") ;;
        *) return 1 ;;
    esac
    for entry in "${entries[@]}"; do
        IFS='|' read -r region base <<<"$entry"
        if elapsed=$(ra_probe_required_mirror_content "$ecosystem" "$base"); then
            printf '%s\t%s\t%s\n' "$elapsed" "$region" "$base"
        else
            printf 'unreachable\t%s\t%s\n' "$region" "$base" >&2
        fi
    done | sort -n
}

ra_choose_mirrors() {
    local alpine_results arch_results alpine_default arch_defaults answer mirror
    ra_info "probing Alpine mirrors in China and worldwide"
    alpine_results=$(ra_probe_mirror_set alpine)
    [[ -n $alpine_results ]] || ra_die "no Alpine release mirror passed the required-path probe"
    printf '%s\n' "$alpine_results" |
        awk -F '\t' '{printf "  %-8s %-8s %s\n", $1 "s", $2, $3}' >&2

    ra_info "probing Arch mirrors in China and worldwide"
    arch_results=$(ra_probe_mirror_set arch)
    [[ -n $arch_results ]] || ra_die "no Arch package mirror passed the required-path probe"
    printf '%s\n' "$arch_results" |
        awk -F '\t' '{printf "  %-8s %-8s %s\n", $1 "s", $2, $3}' >&2

    alpine_default=$(awk -F '\t' 'NR == 1 {print $3}' <<<"$alpine_results")
    arch_defaults=$(awk -F '\t' 'NR <= 3 {print $3}' <<<"$arch_results" | ra_json_array_from_lines)
    ra_confirm "Use the ranked mirror selection shown above?" || {
        read -r -p "Alpine mirror base URL [$alpine_default]: " answer
        alpine_default=${answer:-$alpine_default}
        alpine_default=${alpine_default%/}
        ra_validate_mirror_base alpine "$alpine_default" ||
            ra_die "the selected Alpine mirror did not pass its required-path probe"
        read -r -p "Arch mirror base URLs, comma-separated: " answer
        [[ -n $answer ]] || ra_die "at least one Arch mirror is required"
        arch_defaults=$(tr ',' '\n' <<<"$answer" |
            sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s:/*$::; /^[[:space:]]*$/d' |
            sort -u | ra_json_array_from_lines)
        while IFS= read -r mirror; do
            ra_validate_mirror_base arch "$mirror" ||
                ra_die "Arch mirror did not pass its required-path probe: $mirror"
        done < <(jq -r '.[]' <<<"$arch_defaults")
    }

    jq -n --arg alpine "$alpine_default" --argjson arch "$arch_defaults" \
        '{alpine:$alpine, arch:$arch}'
}

ra_validate_mirror_base() {
    local ecosystem=$1 base=$2 attempt
    [[ $base == https://* && $base != *[[:space:]]* ]] || return 1
    for attempt in 1 2 3; do
        if ra_probe_required_mirror_content "$ecosystem" "$base" >/dev/null; then
            return 0
        fi
        ((attempt < 3)) || return 1
        sleep "$attempt"
    done
    return 1
}

ra_write_pacman_mirrorlist() {
    local mirrors_json=$1 destination=$2 mirror
    : >"$destination"
    while IFS= read -r mirror; do
        # The pacman variables are intentionally written literally.
        # shellcheck disable=SC2016
        printf 'Server = %s/$repo/os/$arch\n' "$mirror" >>"$destination"
    done < <(jq -r '.[]' <<<"$mirrors_json")
}
