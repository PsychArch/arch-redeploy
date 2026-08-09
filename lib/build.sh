#!/usr/bin/env bash

[[ ${RA_BUILD_LOADED:-} == 1 ]] && return 0
RA_BUILD_LOADED=1

# shellcheck source=lib/common.sh
source "$RA_PROJECT_ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$RA_PROJECT_ROOT/lib/detect.sh"
# shellcheck source=lib/mirrors.sh
source "$RA_PROJECT_ROOT/lib/mirrors.sh"

readonly RA_RELEASE_KEY_FINGERPRINT="0482D84022F52DF1C4E7CD43293ACD0907D9495A"
RA_BUILDER_DEFAULT_CA_READY=0
RA_BUILDER_SSL_CERT_DIR=

ra_print_host_dependency_command() {
    local manager=$1
    case "$manager" in
        pacman)
            echo "  pacman -Syu --needed curl jq util-linux cpio gzip zstd gnupg tar iproute2 grub efibootmgr"
            ;;
        apt-get)
            echo "  apt-get update && apt-get install curl jq util-linux cpio gzip zstd gpg tar iproute2 grub-common grub-efi-amd64-bin efibootmgr"
            ;;
        dnf)
            echo "  dnf install curl jq util-linux cpio gzip zstd gnupg2 tar iproute grub2-tools-extra grub2-efi-x64-modules efibootmgr"
            ;;
        yum)
            echo "  yum install curl jq util-linux cpio gzip zstd gnupg2 tar iproute grub2-tools-extra grub2-efi-x64-modules efibootmgr"
            ;;
        zypper)
            echo "  zypper install curl jq util-linux cpio gzip zstd gpg2 tar iproute2 grub2 grub2-x86_64-efi efibootmgr"
            ;;
        apk)
            echo "  apk add bash coreutils curl jq util-linux util-linux-misc cpio gzip zstd gnupg tar iproute2 grub grub-efi efibootmgr"
            ;;
    esac
}

ra_ensure_host_dependencies() {
    local -a required=(curl jq lsblk sfdisk findmnt cpio gzip zstd gpg tar ip flock sha256sum numfmt du)
    local -a missing=()
    local command_name manager mode
    for command_name in "${required[@]}"; do
        if ! command -v "$command_name" >/dev/null; then
            missing+=("$command_name")
        fi
    done
    if command -v sfdisk >/dev/null && ! ra_sfdisk_json_supported; then
        missing+=("sfdisk with --json support")
    fi
    mode=$(ra_boot_mode)
    if [[ $mode == uefi ]]; then
        command -v efibootmgr >/dev/null || missing+=(efibootmgr)
        if ! command -v grub-mkstandalone >/dev/null &&
            ! command -v grub2-mkstandalone >/dev/null; then
            missing+=(grub-mkstandalone/grub2-mkstandalone)
        fi
    elif ! command -v grub-reboot >/dev/null && ! command -v grub2-reboot >/dev/null &&
        ! command -v extlinux >/dev/null; then
        missing+=(grub-reboot/grub2-reboot/extlinux)
    fi
    ((${#missing[@]} == 0)) && return 0
    manager=$(ra_package_manager || true)
    ra_error "missing preparation commands: ${missing[*]}"
    echo "Install preparation dependencies yourself, then rerun arch-redeploy."
    ra_print_host_dependency_command "$manager"
    return 1
}

ra_download() {
    local url=$1 destination=$2 attempt delay
    mkdir -p -- "$(dirname -- "$destination")"
    delay=${RA_DOWNLOAD_RETRY_DELAY_SECONDS:-2}
    [[ $delay =~ ^[0-9]+$ ]] || return 1
    for attempt in 1 2 3 4 5; do
        if curl -LfsS --connect-timeout 10 \
            --speed-limit 1024 --speed-time 60 --max-time 1800 \
            --output "$destination.part" "$url"; then
            mv -f "$destination.part" "$destination"
            return 0
        fi
        rm -f "$destination.part"
        ((attempt < 5)) || return 1
        sleep "$((delay * attempt))"
    done
    return 1
}

ra_verify_alpine_release() {
    local archive=$1 checksum=$2 signature=$3 gpg_home fingerprint expected
    expected=$(awk '{print $1}' "$checksum")
    [[ $(ra_sha256 "$archive") == "$expected" ]] || ra_die "Alpine minirootfs checksum mismatch"
    [[ $expected =~ ^[0-9a-fA-F]{64}$ ]] || ra_die "invalid Alpine checksum document"
    gpg_home=$(mktemp -d "$(dirname "$archive")/gpg.XXXXXX")
    chmod 0700 "$gpg_home"
    gpg --batch --homedir "$gpg_home" --import "$RA_PROJECT_ROOT/assets/alpine-release-key.asc" >/dev/null 2>&1
    fingerprint=$(gpg --batch --homedir "$gpg_home" --with-colons --fingerprint |
        awk -F: '$1 == "fpr" {print $10; exit}')
    [[ $fingerprint == "$RA_RELEASE_KEY_FINGERPRINT" ]] || ra_die "unexpected Alpine release-key fingerprint"
    if ! gpg --batch --homedir "$gpg_home" --verify "$signature" "$archive"; then
        rm -rf "$gpg_home"
        ra_die "Alpine minirootfs signature verification failed"
    fi
    rm -rf "$gpg_home"
}

ra_mount_builder_root() {
    local root=$1
    mkdir -p "$root/dev" "$root/proc" "$root/sys" "$root/run"
    mount --rbind /dev "$root/dev"
    mount --make-rslave "$root/dev"
    mount -t proc proc "$root/proc"
    mount --rbind /sys "$root/sys"
    mount --make-rslave "$root/sys"
    mount --rbind /run "$root/run"
    mount --make-rslave "$root/run"
}

ra_unmount_builder_root() {
    local root=$1 path
    for path in run sys proc dev; do
        if mountpoint -q "$root/$path"; then
            umount -R "$root/$path" 2>/dev/null || umount -R -l "$root/$path" 2>/dev/null || true
        fi
    done
}

ra_builder_chroot() {
    local root=$1 variable value
    local -a environment=(
        HOME=/root
        TERM=dumb
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        LC_ALL=C
    )
    shift
    for variable in \
        HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
        http_proxy https_proxy all_proxy no_proxy \
        SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE REQUESTS_CA_BUNDLE; do
        if [[ ${!variable+x} ]]; then
            value=${!variable}
            case "$variable" in
                SSL_CERT_FILE|CURL_CA_BUNDLE|REQUESTS_CA_BUNDLE)
                    if [[ $RA_BUILDER_DEFAULT_CA_READY == 1 && -n $value ]]; then
                        value=/etc/ssl/certs/ca-certificates.crt
                    fi
                    ;;
                SSL_CERT_DIR)
                    if [[ -n ${RA_BUILDER_SSL_CERT_DIR:-} && -n $value ]]; then
                        value=$RA_BUILDER_SSL_CERT_DIR
                    fi
                    ;;
            esac
            environment+=("$variable=$value")
        fi
    done
    chroot "$root" /usr/bin/env -i "${environment[@]}" "$@"
}

ra_stage_builder_ca_directories() {
    local root=$1 value=${SSL_CERT_DIR:-} directory source source_name
    local destination temporary chroot_value='' copied index=0
    local -a directories=()
    RA_BUILDER_SSL_CERT_DIR=
    [[ -n $value ]] || return 0
    [[ $value != :* && $value != *: && $value != *::* ]] || {
        ra_error "explicit CA directory list contains an empty path"
        return 1
    }
    IFS=: read -r -a directories <<<"$value"
    destination="$root/etc/arch-redeploy-host-ca.d"
    temporary=$(mktemp -d "$root/etc/arch-redeploy-host-ca.XXXXXX") || return 1
    chmod 0755 "$temporary" || {
        rm -rf -- "$temporary"
        return 1
    }
    for directory in "${directories[@]}"; do
        [[ $directory == /* && -d $directory && -r $directory ]] || {
            rm -rf -- "$temporary"
            ra_error "explicit CA directory is not a readable absolute directory: $directory"
            return 1
        }
        mkdir -m 0755 "$temporary/$index" || {
            rm -rf -- "$temporary"
            return 1
        }
        copied=false
        for source in "$directory"/*; do
            [[ -f $source && -r $source ]] || continue
            source_name=${source##*/}
            [[ $source_name =~ ^[0-9a-f]{8}\.([0-9]+|r[0-9]+)$ ]] || continue
            if ! cat "$source" >"$temporary/$index/$source_name" ||
                ! chmod 0644 "$temporary/$index/$source_name"; then
                rm -rf -- "$temporary"
                return 1
            fi
            copied=true
        done
        if ! $copied; then
            rm -rf -- "$temporary"
            ra_error "explicit CA directory contains no readable OpenSSL hash entries: $directory"
            return 1
        fi
        chroot_value+="${chroot_value:+:}/etc/arch-redeploy-host-ca.d/$index"
        ((index += 1))
    done
    rm -rf -- "$destination"
    mv "$temporary" "$destination" || {
        rm -rf -- "$temporary"
        return 1
    }
    RA_BUILDER_SSL_CERT_DIR=$chroot_value
}

ra_extend_builder_ca_trust() {
    local root=$1 variable source destination temporary hash
    local appended=false
    local -A seen=()
    ra_stage_builder_ca_directories "$root" || return 1
    destination="$root/etc/ssl/certs/ca-certificates.crt"
    [[ -s $destination ]] || {
        ra_error "builder default CA bundle is unavailable: $destination"
        return 1
    }
    temporary=$(mktemp "$root/etc/ssl/certs/ca-certificates.XXXXXX")
    if ! cat "$destination" >"$temporary"; then
        rm -f "$temporary"
        return 1
    fi
    for variable in SSL_CERT_FILE CURL_CA_BUNDLE REQUESTS_CA_BUNDLE; do
        source=${!variable:-}
        [[ -n $source && -z ${seen[$source]:-} ]] || continue
        seen[$source]=1
        [[ $source == /* && -f $source && -r $source ]] || {
            rm -f "$temporary"
            ra_error "explicit CA bundle is not a readable absolute file: $source"
            return 1
        }
        if ! grep -q '^-----BEGIN CERTIFICATE-----$' "$source" ||
            ! grep -q '^-----END CERTIFICATE-----$' "$source"; then
            rm -f "$temporary"
            ra_error "explicit CA bundle does not contain a PEM certificate: $source"
            return 1
        fi
        hash=$(ra_sha256 "$source") || {
            rm -f "$temporary"
            return 1
        }
        [[ -z ${seen[$hash]:-} ]] || continue
        seen[$hash]=1
        if ! {
            printf '\n'
            cat "$source"
            printf '\n'
        } >>"$temporary"; then
            rm -f "$temporary"
            return 1
        fi
        appended=true
    done
    if ! $appended; then
        rm -f "$temporary"
        return 0
    fi
    chmod 0644 "$temporary" || {
        rm -f "$temporary"
        return 1
    }
    mv -f "$temporary" "$destination"
    RA_BUILDER_DEFAULT_CA_READY=1
}

ra_proxy_environment_configured() {
    local variable
    for variable in \
        HTTP_PROXY HTTPS_PROXY ALL_PROXY \
        http_proxy https_proxy all_proxy; do
        [[ -z ${!variable:-} ]] || return 0
    done
    return 1
}

ra_custom_ca_environment_configured() {
    local variable
    for variable in \
        SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE REQUESTS_CA_BUNDLE; do
        [[ -z ${!variable:-} ]] || return 0
    done
    return 1
}

ra_online_fallback_environment_safe() {
    ! ra_proxy_environment_configured &&
        ! ra_custom_ca_environment_configured
}

ra_target_packages_json() {
    local admin boot_mode virtual
    admin=$(jq -r .admin.user "$RA_STATE_FILE")
    boot_mode=$(jq -r .boot.mode "$RA_STATE_FILE")
    virtual=$(jq -r .host.virtual "$RA_STATE_FILE")
    {
        printf '%s\n' archlinux-keyring base linux grub openssh e2fsprogs
        [[ $admin == root ]] || printf '%s\n' sudo
        [[ $boot_mode == uefi ]] && printf '%s\n' efibootmgr dosfstools
        if [[ $virtual != true ]]; then
            printf '%s\n' linux-firmware
            case "$(awk -F: '/vendor_id/ {gsub(/ /, "", $2); print $2; exit}' /proc/cpuinfo)" in
                GenuineIntel) printf '%s\n' intel-ucode ;;
                AuthenticAMD) printf '%s\n' amd-ucode ;;
            esac
        fi
    } | sort -u | ra_json_array_from_lines
}

ra_prepare_pacman() {
    local root=$1 first_mirror
    install -d -m 0755 "$root/etc/pacman.d"
    ra_write_pacman_mirrorlist "$(jq -c .mirrors.arch "$RA_STATE_FILE")" "$root/etc/pacman.d/mirrorlist"
    cat >"$root/etc/pacman.conf" <<'EOF'
[options]
Architecture = auto
ParallelDownloads = 5
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Required

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
EOF
    ra_builder_chroot "$root" pacman-key --init
    ra_builder_chroot "$root" pacman-key --populate archlinux
    ra_builder_chroot "$root" pacman -Sy --noconfirm
    ra_builder_chroot "$root" mkdir -p /tmp/pacman-preflight
    ra_builder_chroot "$root" pacman -Swdd --noconfirm --cachedir /tmp/pacman-preflight archlinux-keyring
    ra_builder_chroot "$root" rm -rf /tmp/pacman-preflight
    first_mirror=$(jq -r '.mirrors.arch[0]' "$RA_STATE_FILE")
    printf '%s' "$first_mirror" >"$root/etc/arch-redeploy-first-mirror"
}

ra_write_package_lock() {
    local root=$1 packages_json=$2 first_mirror name version url suffix lock
    lock="$root/etc/arch-redeploy/packages.lock"
    mkdir -p "$(dirname "$lock")"
    first_mirror=$(jq -r '.mirrors.arch[0]' "$RA_STATE_FILE")
    : >"$lock"
    mapfile -t packages < <(jq -r '.[]' <<<"$packages_json")
    while IFS=$'\t' read -r name version url; do
        [[ $url == "$first_mirror/"* ]] || ra_die "pacman returned an unexpected mirror URL: $url"
        suffix=${url#"$first_mirror/"}
        printf '%s\t%s\t%s\n' "$name" "$version" "$suffix" >>"$lock"
    done < <(ra_builder_chroot "$root" pacman -Sp --noconfirm \
        --print-format $'%n\t%v\t%l' "${packages[@]}")
    [[ -s $lock ]] || ra_die "could not resolve the Arch package transaction"
}

ra_preflight_locked_transaction() {
    local lock=$1 mirrors_json=$2 name version suffix mirror successes
    [[ -s $lock ]] || return 1
    ra_online_mirror_count_valid "$mirrors_json" || return 1
    while IFS=$'\t' read -r name version suffix; do
        [[ $name =~ ^[a-zA-Z0-9@._+-]+$ && -n $version ]] || return 1
        [[ $suffix != /* && $suffix != *..* && $suffix == *.pkg.tar.* ]] || return 1
        successes=0
        while IFS= read -r mirror; do
            if ra_probe_url "$mirror/$suffix" >/dev/null &&
                ra_probe_url "$mirror/$suffix.sig" >/dev/null; then
                ((successes += 1))
                ((successes >= 2)) && break
            fi
        done < <(jq -r '.[]' <<<"$mirrors_json")
        if ((successes < 2)); then
            ra_error "locked package or signature is not available from two mirrors: $name $version"
            return 1
        fi
    done <"$lock"
}

ra_require_online_fallback() {
    local lock=$1 mirrors_json
    ra_online_fallback_environment_safe ||
        ra_die "online-after-wipe mode cannot preserve proxy or custom CA settings; use an offline payload or rerun with default public HTTPS trust"
    mirrors_json=$(jq -c .mirrors.arch "$RA_STATE_FILE")
    ra_online_mirror_count_valid "$mirrors_json" ||
        ra_die "online mode requires at least two prevalidated Arch mirrors"
    ra_info "checking every locked package and signature on two Arch mirrors"
    ra_preflight_locked_transaction "$lock" "$mirrors_json" ||
        ra_die "the exact online transaction is not safely available from two mirrors"
}

ra_build_alpine_root() {
    local work=$1
    local root="$work/alpine" downloads="$work/downloads" mirror archive checksum signature kernel_package
    local -a firmware_packages=()
    mirror=$(jq -r .mirrors.alpine "$RA_STATE_FILE")
    archive="$downloads/alpine-minirootfs-$RA_ALPINE_VERSION-$RA_ARCH.tar.gz"
    checksum="$archive.sha256"
    signature="$archive.asc"
    ra_info "downloading and verifying Alpine $RA_ALPINE_VERSION minirootfs"
    ra_download "$mirror/$RA_ALPINE_BRANCH/releases/$RA_ARCH/$(basename "$archive")" "$archive"
    ra_download "$mirror/$RA_ALPINE_BRANCH/releases/$RA_ARCH/$(basename "$checksum")" "$checksum"
    ra_download "$mirror/$RA_ALPINE_BRANCH/releases/$RA_ARCH/$(basename "$signature")" "$signature"
    ra_verify_alpine_release "$archive" "$checksum" "$signature"

    mkdir -p "$root"
    tar -xzf "$archive" -C "$root"
    printf 'disable_trigger=1\n' >"$root/etc/update-grub.conf"
    printf '%s/%s/main\n%s/%s/community\n' "$mirror" "$RA_ALPINE_BRANCH" "$mirror" "$RA_ALPINE_BRANCH" \
        >"$root/etc/apk/repositories"
    cp -L /etc/resolv.conf "$root/etc/resolv.conf"
    ra_extend_builder_ca_trust "$root"
    ra_mount_builder_root "$root"
    kernel_package=$(jq -r 'if .host.virtual then "linux-virt" else "linux-lts" end' "$RA_STATE_FILE")
    [[ $(jq -r .host.virtual "$RA_STATE_FILE") == true ]] || firmware_packages=(linux-firmware)
    ra_info "assembling the self-contained Alpine installer"
    ra_builder_chroot "$root" apk update
    ra_builder_chroot "$root" apk add --no-cache \
        bash ca-certificates curl jq openssh-server iproute2 \
        util-linux util-linux-misc parted e2fsprogs e2fsprogs-extra dosfstools \
        grub grub-bios grub-efi efibootmgr arch-install-scripts archlinux-keyring \
        pacman zstd tar gzip cpio coreutils findutils grep gawk sed shadow sudo \
        "$kernel_package" "${firmware_packages[@]}"
    ra_builder_chroot "$root" update-ca-certificates
    ra_extend_builder_ca_trust "$root"
    ra_prepare_pacman "$root"
    printf '%s' "$kernel_package" >"$root/etc/arch-redeploy-kernel-package"
}

ra_configure_arch_build_root() {
    local root=$1
    # shellcheck source=installer/target.sh
    source "$RA_PROJECT_ROOT/installer/target.sh"
    if ! target_mount_pseudo "$root"; then
        target_unmount_pseudo "$root"
        return 1
    fi
    if ! target_configure "$root" "$RA_STATE_FILE" ||
        ! target_chroot "$root" mkinitcpio -P; then
        target_unmount_pseudo "$root"
        return 1
    fi
    target_unmount_pseudo "$root"
}

ra_build_arch_payload() {
    local work=$1 alpine_root=$2 packages_json=$3 archive=$4
    local arch_root="$work/arch-root"
    mapfile -t packages < <(jq -r '.[]' <<<"$packages_json")
    mkdir -p "$arch_root" "$alpine_root/target"
    mount --bind "$arch_root" "$alpine_root/target" || return 1
    ra_info "building and validating the complete Arch root payload"
    if ! ra_builder_chroot "$alpine_root" pacstrap /target "${packages[@]}"; then
        umount "$alpine_root/target" || true
        return 1
    fi
    umount "$alpine_root/target" || return 1
    ra_configure_arch_build_root "$arch_root" || return 1
    gpgconf --homedir "$arch_root/etc/pacman.d/gnupg" --kill all 2>/dev/null || true
    find "$arch_root/etc/pacman.d/gnupg" -type s -delete 2>/dev/null || true
    rm -rf "${arch_root:?}/var/cache/pacman/pkg"/*
    tar --xattrs --acls --numeric-owner --one-file-system -I 'zstd -T0 -8' \
        -cpf "$archive" -C "$arch_root" . || return 1
    zstd -q -t "$archive" || return 1
    tar -I zstd -tf "$archive" ./etc/arch-release ./boot/vmlinuz-linux >/dev/null || return 1
    du -sb "$arch_root" | awk '{print $1}' >"$archive.unpacked-bytes" || return 1
    rm -rf "$arch_root"
}

ra_install_installer_sources() {
    local root=$1
    install -Dm0755 "$RA_PROJECT_ROOT/installer/init" "$root/init"
    install -Dm0755 "$RA_PROJECT_ROOT/installer/install.sh" \
        "$root/usr/local/lib/arch-redeploy/install.sh"
    install -Dm0755 "$RA_PROJECT_ROOT/installer/target.sh" \
        "$root/usr/local/lib/arch-redeploy/target.sh"
    install -Dm0755 "$RA_PROJECT_ROOT/installer/finalize.sh" \
        "$root/usr/local/lib/arch-redeploy/finalize.sh"
    install -Dm0755 "$RA_PROJECT_ROOT/installer/control.sh" \
        "$root/usr/local/bin/arch-redeploy"
    install -Dm0644 "$RA_PROJECT_ROOT/lib/stages.sh" \
        "$root/usr/local/lib/arch-redeploy/stages.sh"
    install -Dm0644 "$RA_PROJECT_ROOT/lib/disk.sh" \
        "$root/usr/local/lib/arch-redeploy/disk.sh"
    install -Dm0755 "$RA_PROJECT_ROOT/installer/udhcpc.script" \
        "$root/usr/local/lib/arch-redeploy/udhcpc.script"
    install -Dm0600 "$RA_STATE_FILE" "$root/etc/arch-redeploy/config.json"
}

ra_pack_initramfs() {
    local root=$1 output=$2 payload=${3:-} kernel kernel_package
    kernel_package=$(cat "$root/etc/arch-redeploy-kernel-package")
    kernel=$(find "$root/boot" -maxdepth 1 -type f -name "vmlinuz-*" | head -n1)
    [[ -s $kernel ]] || ra_die "Alpine kernel was not installed"
    cp "$kernel" "$output.kernel"
    install -Dm0644 "$kernel" "$root/opt/arch-redeploy/vmlinuz"
    if [[ -n $payload ]]; then
        install -Dm0600 "$payload" "$root/opt/arch-redeploy/rootfs.tar.zst"
    else
        rm -f "$root/opt/arch-redeploy/rootfs.tar.zst"
    fi
    ra_install_installer_sources "$root"
    ra_builder_chroot "$root" gpgconf --homedir /etc/pacman.d/gnupg --kill all 2>/dev/null || true
    find "$root/etc/pacman.d/gnupg" -type s -delete 2>/dev/null || true
    rm -rf "${root:?}/boot"/* "$root/usr/share/doc" "$root/usr/share/info" "$root/usr/share/man"
    rm -rf "$root/var/cache/apk"/* "$root/tmp"/* "$root/var/log"/*
    (
        cd "$root"
        find . -xdev -print0 | cpio --null --quiet -o -H newc | gzip -1 >"$output"
    )
    gzip -t "$output"
    printf '%s' "$kernel_package" >"$output.kernel-package"
    rm -f "$root/opt/arch-redeploy/rootfs.tar.zst"
}

ra_finalize_prepared_artifacts() {
    local artifacts="$RA_STATE_DIR/artifacts" manifest="$RA_STATE_DIR/artifacts/complete.json"
    local kernel="$RA_STATE_DIR/artifacts/vmlinuz" initramfs="$RA_STATE_DIR/artifacts/initramfs.img"
    local prepared_at state
    [[ -s $manifest && -s $kernel && -s $initramfs ]] || return 1
    jq -e --arg install_id "$(ra_state_get .install_id)" '
        .install_id == $install_id and
        (.kernel_sha256 | test("^[0-9a-f]{64}$")) and
        (.initramfs_sha256 | test("^[0-9a-f]{64}$"))
    ' "$manifest" >/dev/null || return 1
    [[ $(ra_sha256 "$kernel") == "$(jq -r .kernel_sha256 "$manifest")" ]] || return 1
    [[ $(ra_sha256 "$initramfs") == "$(jq -r .initramfs_sha256 "$manifest")" ]] || return 1
    [[ $(ra_bytes "$kernel") == "$(jq -r .kernel_bytes "$manifest")" ]] || return 1
    [[ $(ra_bytes "$initramfs") == "$(jq -r .initramfs_bytes "$manifest")" ]] || return 1
    state=$(ra_state_get .state)
    [[ $state == prepared ]] && return 0
    ra_state_transition_allowed "$state" prepared || return 1
    prepared_at=$(jq -r .prepared_at "$manifest")
    # shellcheck disable=SC2016
    ra_state_update '.state = "prepared" | .artifacts = {
        kernel:"artifacts/vmlinuz",
        kernel_sha256:$kernel_sha,
        kernel_bytes:$kernel_bytes,
        initramfs:"artifacts/initramfs.img",
        initramfs_sha256:$initramfs_sha,
        initramfs_bytes:$initramfs_bytes
    } | .prepared_at = $prepared_at' \
        --arg kernel_sha "$(jq -r .kernel_sha256 "$manifest")" \
        --argjson kernel_bytes "$(jq -r .kernel_bytes "$manifest")" \
        --arg initramfs_sha "$(jq -r .initramfs_sha256 "$manifest")" \
        --argjson initramfs_bytes "$(jq -r .initramfs_bytes "$manifest")" \
        --arg prepared_at "$prepared_at"
}

ra_cleanup_stale_builds() {
    local build_root="$RA_STATE_DIR/tmp" work
    [[ -d $build_root ]] || return 0
    for work in "$build_root"/build.*; do
        [[ -d $work ]] || continue
        [[ $work == "$RA_STATE_DIR/tmp/build."* ]] || return 1
        ra_cleanup_mounts "$work/alpine"
        ra_unmount_builder_root "$work/alpine"
        if findmnt -rn -o TARGET |
            awk -v root="$work" '$0 == root || index($0, root "/") == 1 {found=1} END {exit !found}'; then
            ra_error "could not unmount stale build workspace: $work"
            return 1
        fi
        rm -rf -- "$work"
    done
}

RA_BUILD_CLEANUP_WORK=
RA_BUILD_CLEANUP_ALPINE_ROOT=

ra_run_build_cleanup() {
    local work=${RA_BUILD_CLEANUP_WORK:-}
    local alpine_root=${RA_BUILD_CLEANUP_ALPINE_ROOT:-}
    [[ -n $work && $work == "$RA_STATE_DIR/tmp/build."* &&
        $alpine_root == "$work/alpine" ]] || return 0
    ra_unmount_builder_root "$alpine_root"
    rm -rf -- "$work"
}

ra_arm_build_cleanup() {
    local work=$1 alpine_root=$2
    [[ $work == "$RA_STATE_DIR/tmp/build."* && $alpine_root == "$work/alpine" ]] || return 1
    RA_BUILD_CLEANUP_WORK=$work
    RA_BUILD_CLEANUP_ALPINE_ROOT=$alpine_root
    trap 'ra_run_build_cleanup' EXIT
}

ra_disarm_build_cleanup() {
    trap - EXIT
    RA_BUILD_CLEANUP_WORK=
    RA_BUILD_CLEANUP_ALPINE_ROOT=
}

ra_build_installer() {
    local work artifacts alpine_root packages_json payload_archive initramfs memory_bytes payload_mode=online
    local required_bytes free_bytes disk_required_bytes
    ra_cleanup_stale_builds || ra_die "could not reclaim an interrupted installer build"
    work=$(ra_tempdir build)
    artifacts="$RA_STATE_DIR/artifacts"
    mkdir -p "$artifacts"
    chmod 0700 "$artifacts"
    rm -f "$artifacts/vmlinuz" "$artifacts/initramfs.img" "$artifacts/kernel-package" \
        "$artifacts/complete.json"
    alpine_root="$work/alpine"
    payload_archive="$work/arch-root.tar.zst"
    initramfs="$work/initramfs.img"
    packages_json=$(ra_target_packages_json)
    # shellcheck disable=SC2016
    ra_state_update '.payload = {mode:"undecided", packages:$packages}' \
        --argjson packages "$packages_json"

    ra_arm_build_cleanup "$work" "$alpine_root"
    ra_build_alpine_root "$work"
    ra_write_package_lock "$alpine_root" "$packages_json"

    free_bytes=$(df -PB1 "$RA_STATE_DIR" | awk 'NR == 2 {print $4}')
    if ((free_bytes >= 4294967296)); then
        if ra_build_arch_payload "$work" "$alpine_root" "$packages_json" "$payload_archive"; then
            payload_mode=offline
            # shellcheck disable=SC2016
            ra_state_update '.payload.mode = "offline" | .payload.rootfs_sha256 = $sha |
                .payload.rootfs_bytes = $bytes | .payload.rootfs_unpacked_bytes = $unpacked' \
                --arg sha "$(ra_sha256 "$payload_archive")" --argjson bytes "$(ra_bytes "$payload_archive")" \
                --argjson unpacked "$(cat "$payload_archive.unpacked-bytes")"
        else
            ra_warn "the complete offline Arch payload could not be built"
        fi
    else
        ra_warn "less than 4 GiB staging space is available; skipping the offline-root build"
    fi

    if [[ $payload_mode == offline ]]; then
        ra_pack_initramfs "$alpine_root" "$initramfs" "$payload_archive"
        memory_bytes=$(awk '/MemTotal:/ {print $2 * 1024}' /proc/meminfo)
        required_bytes=$(ra_boot_memory_required "$(ra_bytes "$initramfs")" "$(ra_bytes "$initramfs.kernel")")
        if ((memory_bytes < required_bytes)) ||
            ! ra_boot_capacity_fits "$initramfs.kernel" "$initramfs"; then
            if ((memory_bytes < required_bytes)); then
                ra_warn "offline payload needs $(ra_human_bytes "$required_bytes") RAM; this host has $(ra_human_bytes "$memory_bytes")"
            fi
            if ! ra_boot_capacity_fits "$initramfs.kernel" "$initramfs"; then
                ra_warn "offline payload needs $(ra_human_bytes "$(ra_boot_capacity_required "$initramfs.kernel" "$initramfs")") free on the boot filesystem"
            fi
            ra_require_online_fallback "$alpine_root/etc/arch-redeploy/packages.lock"
            if ra_confirm "Use the explicitly riskier mirror-locked online mode?"; then
                payload_mode=online
                ra_state_update 'del(.payload.rootfs_sha256, .payload.rootfs_bytes, .payload.rootfs_unpacked_bytes) |
                    .payload.mode = "online"'
                ra_pack_initramfs "$alpine_root" "$initramfs"
            else
                ra_die "preparation cancelled because the offline payload does not fit in RAM"
            fi
        fi
    else
        ra_require_online_fallback "$alpine_root/etc/arch-redeploy/packages.lock"
        ra_warn "using mirror-locked online mode; package downloads will continue after disk erasure"
        ra_confirm "Accept online-after-wipe mode?" || ra_die "preparation cancelled"
        ra_state_update '.payload.mode = "online"'
        ra_pack_initramfs "$alpine_root" "$initramfs"
    fi

    if [[ $payload_mode == online ]]; then
        ra_online_mirror_count_valid "$(jq -c .mirrors.arch "$RA_STATE_FILE")" ||
            ra_die "online mode requires at least two prevalidated Arch mirrors"
    fi

    memory_bytes=$(awk '/MemTotal:/ {print $2 * 1024}' /proc/meminfo)
    required_bytes=$(ra_boot_memory_required "$(ra_bytes "$initramfs")" "$(ra_bytes "$initramfs.kernel")")
    ((memory_bytes >= required_bytes)) ||
        ra_die "the installer needs $(ra_human_bytes "$required_bytes") RAM; this host has $(ra_human_bytes "$memory_bytes")"
    # shellcheck disable=SC2016
    ra_state_update '.payload.boot_memory_required = $bytes' --argjson bytes "$required_bytes"
    if [[ $payload_mode == offline ]]; then
        disk_required_bytes=$(($(jq -r .payload.rootfs_unpacked_bytes "$RA_STATE_FILE") +
            $(ra_bytes "$initramfs") + $(ra_bytes "$initramfs.kernel") + 1024 * 1024 * 1024))
    else
        disk_required_bytes=$((8 * 1024 * 1024 * 1024))
    fi
    (( $(ra_state_get .disk.size) >= disk_required_bytes )) ||
        ra_die "the selected disk needs $(ra_human_bytes "$disk_required_bytes") for this prepared payload"
    # shellcheck disable=SC2016
    ra_state_update '.payload.disk_bytes_required = $bytes' --argjson bytes "$disk_required_bytes"
    ra_verify_boot_capacity "$initramfs.kernel" "$initramfs"

    ra_unmount_builder_root "$alpine_root"
    mv -f "$initramfs" "$artifacts/initramfs.img"
    mv -f "$initramfs.kernel" "$artifacts/vmlinuz"
    mv -f "$initramfs.kernel-package" "$artifacts/kernel-package"
    jq -n --arg install_id "$(ra_state_get .install_id)" \
        --arg kernel_sha "$(ra_sha256 "$artifacts/vmlinuz")" \
        --argjson kernel_bytes "$(ra_bytes "$artifacts/vmlinuz")" \
        --arg initramfs_sha "$(ra_sha256 "$artifacts/initramfs.img")" \
        --argjson initramfs_bytes "$(ra_bytes "$artifacts/initramfs.img")" \
        --arg prepared_at "$(date -u +%FT%TZ)" '{
          install_id:$install_id,
          kernel_sha256:$kernel_sha,
          kernel_bytes:$kernel_bytes,
          initramfs_sha256:$initramfs_sha,
          initramfs_bytes:$initramfs_bytes,
          prepared_at:$prepared_at
        }' | ra_atomic_json "$artifacts/complete.json"
    ra_finalize_prepared_artifacts ||
        ra_die "could not commit the verified preparation artifacts"
    rm -rf "$work"
    ra_disarm_build_cleanup
}
