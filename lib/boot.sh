#!/usr/bin/env bash

[[ ${RA_BOOT_LOADED:-} == 1 ]] && return 0
RA_BOOT_LOADED=1

# shellcheck source=lib/common.sh
source "$RA_PROJECT_ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$RA_PROJECT_ROOT/lib/detect.sh"

readonly RA_GRUB_ENTRY="Arch redeploy recovery"
readonly RA_BOOT_START="# BEGIN ARCH-REDEPLOY"
readonly RA_BOOT_END="# END ARCH-REDEPLOY"
readonly RA_UEFI_GRUB_MODULES="part_gpt part_msdos fat ext2 xfs btrfs lvm diskfilter normal linux search search_fs_uuid all_video serial"
readonly RA_UEFI_LOADER_MARGIN_BYTES=$((1024 * 1024))

ra_verify_artifacts() {
    local kernel initramfs rootfs
    kernel="$RA_STATE_DIR/$(ra_state_get .artifacts.kernel)"
    initramfs="$RA_STATE_DIR/$(ra_state_get .artifacts.initramfs)"
    [[ -s $kernel && -s $initramfs ]] || ra_die "prepared boot artifacts are missing"
    [[ $(ra_sha256 "$kernel") == "$(ra_state_get .artifacts.kernel_sha256)" ]] ||
        ra_die "prepared kernel checksum mismatch"
    [[ $(ra_sha256 "$initramfs") == "$(ra_state_get .artifacts.initramfs_sha256)" ]] ||
        ra_die "prepared initramfs checksum mismatch"
    if [[ $(jq -r '.payload.mode // "online"' "$RA_STATE_FILE") == offline ]]; then
        rootfs="$RA_STATE_DIR/$(ra_state_get .artifacts.rootfs)"
        [[ -s $rootfs ]] || ra_die "prepared offline payload is missing"
        [[ $(ra_sha256 "$rootfs") == "$(ra_state_get .artifacts.rootfs_sha256)" ]] ||
            ra_die "prepared offline payload checksum mismatch"
    fi
}

ra_verify_boot_capacity() {
    local kernel=$1 initramfs=$2 payload=${3:-} required
    required=$(ra_boot_capacity_required "$kernel" "$initramfs" "$payload")
    ra_boot_capacity_fits "$kernel" "$initramfs" "$payload" ||
        ra_die "the boot filesystem needs $(ra_human_bytes "$required") free for prepared artifacts"
}

ra_boot_capacity_required() {
    local kernel=$1 initramfs=$2 payload=${3:-} payload_bytes=0
    [[ -z $payload ]] || payload_bytes=$(ra_bytes "$payload")
    printf '%s' "$(($(ra_bytes "$kernel") + $(ra_bytes "$initramfs") + payload_bytes + 16 * 1024 * 1024))"
}

ra_boot_capacity_fits() {
    local kernel=$1 initramfs=$2 payload=${3:-} parent available required
    parent=$(dirname "$RA_BOOT_DIR")
    available=$(df -PB1 "$parent" | awk 'NR == 2 {print $4}')
    required=$(ra_boot_capacity_required "$kernel" "$initramfs" "$payload")
    ((available >= required))
}

ra_source_return_hook_kind() {
    local forced=${ARCH_REDEPLOY_INIT_KIND:-}
    local systemd_runtime=${ARCH_REDEPLOY_SYSTEMD_RUNTIME_DIR:-/run/systemd/system}
    local openrc_run=${ARCH_REDEPLOY_OPENRC_RUN:-/sbin/openrc-run}
    case "$forced" in
        systemd)
            if [[ ! -d $systemd_runtime ]] || ! command -v systemctl >/dev/null; then
                return 1
            fi
            printf '%s' systemd
            ;;
        openrc)
            if [[ ! -x $openrc_run ]] || ! command -v rc-update >/dev/null; then
                return 1
            fi
            printf '%s' openrc
            ;;
        '')
            if [[ -d $systemd_runtime ]] && command -v systemctl >/dev/null; then
                printf '%s' systemd
            elif [[ -x $openrc_run ]] && command -v rc-update >/dev/null; then
                printf '%s' openrc
            else
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
}

ra_preflight_source_return_hook() {
    ra_source_return_hook_kind >/dev/null ||
        ra_die "source rollback requires a running systemd or OpenRC init system"
}

ra_grub_cfg_supports_one_shot() {
    local config=$1 fs_type=${2:-} require_external=0
    [[ -r $config && -n $fs_type ]] || return 1
    [[ $fs_type == btrfs ]] && require_external=1
    awk -v require_external="$require_external" '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line == "" || line ~ /^#/) {
                next
            }
            sub(/[[:space:]]+#.*/, "", line)

            compact = line
            gsub(/[[:space:]{}"]/, "", compact)
            gsub("\047", "", compact)

            if (line ~ /(^|[;[:space:]])load_env([;[:space:]]|$)/) {
                external_load = line ~ /(^|[;[:space:]])load_env[[:space:]]+-f[[:space:]]+/ &&
                    line ~ /(^|[^[:alnum:]_])env_block([^[:alnum:]_]|$)/
                if (external_load) {
                    if (loaded) {
                        external_loaded = 1
                    }
                } else {
                    loaded = 1
                }
                next
            }
            if (loaded && (!require_external || external_loaded) && !tested &&
                line ~ /^(if|elif)([[:space:]]|\[)/ &&
                line ~ /(^|[^[:alnum:]_])next_entry([^[:alnum:]_]|$)/) {
                tested = 1
                next
            }
            if (tested && !consumed &&
                compact ~ /^setdefault=\$next_entry;?$/) {
                consumed = 1
                next
            }
            if (consumed && !cleared &&
                compact ~ /^setnext_entry=;?$/) {
                cleared = 1
                next
            }
            if (cleared &&
                line ~ /(^|[;[:space:]])save_env([;[:space:]]|$)/ &&
                line ~ /(^|[;[:space:]])next_entry([;[:space:]]|$)/) {
                saved = 1
                if (line ~ /(^|[;[:space:]])save_env[[:space:]]+-f[[:space:]]+/ &&
                    line ~ /(^|[^[:alnum:]_])env_block([^[:alnum:]_]|$)/) {
                    external_saved = 1
                }
            }
        }
        END {
            exit !(loaded && tested && consumed && cleared && saved &&
                (!require_external || external_saved))
        }
    ' "$config"
}

ra_bios_boot_source_supported() {
    local source=$1 types
    types=$(lsblk -srno TYPE "$source" 2>/dev/null) || return 1
    [[ -n $types ]] || return 1
    ! grep -Eq '^(crypt|lvm|mpath|raid)' <<<"$types"
}

ra_bios_grub_one_shot_capable() {
    local config=$1 fs_type=${2:-} edit_command environment
    [[ -r $config && -n $fs_type ]] || return 1
    ra_grub_command reboot >/dev/null || return 1
    edit_command=$(ra_grub_command editenv) || return 1
    [[ -n $edit_command ]] || return 1
    environment=$("$edit_command" - list 2>/dev/null) || return 1
    if [[ $fs_type == btrfs ]]; then
        grep -Eq '^env_block=[0-9]+\+[1-9][0-9]*$' <<<"$environment" || return 1
    fi
    ra_grub_cfg_supports_one_shot "$config" "$fs_type"
}

ra_uefi_loader_required_bytes() {
    local standalone_command=$1 binary config bytes
    binary=$(mktemp "${TMPDIR:-/tmp}/arch-redeploy-efi.XXXXXX")
    config=$(mktemp "${TMPDIR:-/tmp}/arch-redeploy-grub.XXXXXX")
    printf '%s\n' 'set timeout=0' >"$config"
    if ! "$standalone_command" -O x86_64-efi \
        --modules="$RA_UEFI_GRUB_MODULES" \
        --fonts= --locales= --themes= \
        -o "$binary" "boot/grub/grub.cfg=$config" >/dev/null 2>&1; then
        rm -f "$binary" "$config"
        return 1
    fi
    bytes=$(stat -c '%s' "$binary") || {
        rm -f "$binary" "$config"
        return 1
    }
    rm -f "$binary" "$config"
    printf '%s' "$((bytes + RA_UEFI_LOADER_MARGIN_BYTES))"
}

ra_preflight_boot_scheduler() {
    local mode cfg boot_source fs_type standalone_command esp_info esp_mount available required
    mode=$(ra_boot_mode)
    fs_type=$(findmnt -T /boot -rn -o FSTYPE)
    case "$fs_type" in
        btrfs|ext2|ext3|ext4|vfat|xfs) ;;
        *) ra_die "the current /boot filesystem is not supported by the one-shot loader: $fs_type" ;;
    esac
    boot_source=$(findmnt -T /boot -rn -o SOURCE)
    boot_source=${boot_source%%\[*}
    if lsblk -srno TYPE "$boot_source" 2>/dev/null | grep -Eq '^crypt'; then
        ra_die "one-shot boot from an encrypted /boot filesystem is not supported"
    fi
    if [[ $mode == uefi ]]; then
        standalone_command=$(ra_grub_command mkstandalone || true)
        [[ -n $standalone_command ]] || ra_die "grub-mkstandalone or grub2-mkstandalone is required"
        ra_require_commands efibootmgr
        efibootmgr --help 2>&1 | grep -q -- '--create-only' ||
            ra_die "efibootmgr with --create-only support is required for one-shot UEFI boot"
        esp_info=$(ra_find_esp) || ra_die "the EFI system partition is no longer mounted"
        IFS=$'\t' read -r esp_mount _ <<<"$esp_info"
        required=$(ra_uefi_loader_required_bytes "$standalone_command") ||
            ra_die "could not measure the temporary UEFI loader"
        available=$(df -PB1 "$esp_mount" | awk 'NR == 2 {print $4}')
        [[ $available =~ ^[0-9]+$ ]] ||
            ra_die "could not measure free space on the EFI system partition"
        ((available >= required)) ||
            ra_die "the EFI system partition needs $(ra_human_bytes "$required") free for the temporary one-shot loader"
        if lsblk -srno TYPE "$boot_source" 2>/dev/null | grep -Eq '^(mpath|raid)'; then
            ra_die "UEFI one-shot boot from multipath or RAID-backed /boot is not supported"
        fi
    else
        ra_bios_boot_source_supported "$boot_source" ||
            ra_die "BIOS one-shot boot from encrypted, LVM, multipath, or RAID-backed /boot is not supported"
        cfg=$(ra_find_grub_cfg)
        if [[ -n $cfg ]] && ra_bios_grub_one_shot_capable "$cfg" "$fs_type"; then
            return 0
        fi
        cfg=$(find /boot -maxdepth 3 -type f -name extlinux.conf -print -quit 2>/dev/null)
        [[ -n $cfg ]] && command -v extlinux >/dev/null && return 0
        ra_die "BIOS preparation requires extlinux or an active GRUB config with working grub-reboot, grub-editenv, and one-shot next_entry handling"
    fi
}

ra_grub_path() {
    local path=$1 mount_target relative subvolume
    if command -v grub-mkrelpath >/dev/null; then
        grub-mkrelpath "$path"
        return
    fi
    mount_target=$(findmnt -T "$path" -rn -o TARGET)
    relative=${path#"$mount_target"}
    [[ $relative == /* ]] || relative=/$relative
    if [[ $(findmnt -T "$path" -rn -o FSTYPE) == btrfs ]] && command -v btrfs >/dev/null; then
        subvolume=$(btrfs subvolume show "$mount_target" | awk 'NR == 1 {print $NF}')
        [[ $subvolume == / ]] || relative="/$subvolume$relative"
    fi
    printf '%s' "$relative"
}

ra_stage_boot_files() {
    local kernel initramfs rootfs='' install_id pending destination
    kernel="$RA_STATE_DIR/$(ra_state_get .artifacts.kernel)"
    initramfs="$RA_STATE_DIR/$(ra_state_get .artifacts.initramfs)"
    if [[ $(jq -r '.payload.mode // "online"' "$RA_STATE_FILE") == offline ]]; then
        rootfs="$RA_STATE_DIR/$(ra_state_get .artifacts.rootfs)"
    fi
    install_id=$(ra_state_get .install_id)
    pending="${RA_BOOT_DIR}.pending-$install_id"
    ra_verify_boot_capacity "$kernel" "$initramfs" "$rootfs"
    if [[ -e $RA_BOOT_DIR ]]; then
        if [[ -d $RA_BOOT_DIR && ! -e $RA_BOOT_DIR/install-id ]] &&
            [[ -z $(find "$RA_BOOT_DIR" -mindepth 1 -print -quit) ]]; then
            rmdir "$RA_BOOT_DIR"
        fi
    fi
    if [[ -e $RA_BOOT_DIR ]]; then
        [[ -f $RA_BOOT_DIR/install-id ]] ||
            ra_die "refusing to replace an unowned boot-artifact directory: $RA_BOOT_DIR"
        [[ $(cat "$RA_BOOT_DIR/install-id") == "$install_id" ]] ||
            ra_die "boot-artifact directory belongs to another redeploy operation"
        destination=$RA_BOOT_DIR
    else
        [[ $pending == "${RA_BOOT_DIR}.pending-$install_id" ]] ||
            ra_die "refusing an unsafe boot-artifact staging path"
        rm -rf -- "$pending"
        mkdir -p "$pending"
        destination=$pending
    fi
    chmod 0700 "$destination"
    printf '%s\n' "$install_id" >"$destination/install-id"
    chmod 0600 "$destination/install-id"
    install -m 0600 "$kernel" "$destination/vmlinuz"
    install -m 0600 "$initramfs" "$destination/initramfs.img"
    if [[ -n $rootfs ]]; then
        install -m 0600 "$rootfs" "$destination/rootfs.tar.zst"
    else
        rm -f "$destination/rootfs.tar.zst"
    fi
    sync "$destination"
    if [[ $destination == "$pending" ]]; then
        mv -- "$pending" "$RA_BOOT_DIR"
        sync "$(dirname "$RA_BOOT_DIR")"
    fi
}

ra_payload_kernel_args() {
    local payload_file mount_target fs_root uuid fs_type relative payload_path
    [[ $(jq -r '.payload.mode // "online"' "$RA_STATE_FILE") == offline ]] || return 0
    payload_file="$RA_BOOT_DIR/rootfs.tar.zst"
    [[ -s $payload_file ]] || return 1
    mount_target=$(findmnt -T "$payload_file" -rn -o TARGET) || return 1
    fs_root=$(findmnt -T "$payload_file" -rn -o FSROOT) || return 1
    uuid=$(findmnt -T "$payload_file" -rn -o UUID) || return 1
    fs_type=$(findmnt -T "$payload_file" -rn -o FSTYPE) || return 1
    [[ -n $mount_target && -n $fs_root && $uuid =~ ^[A-Za-z0-9-]+$ ]] || return 1
    [[ $fs_type =~ ^(btrfs|ext2|ext3|ext4|vfat|xfs)$ ]] || return 1
    relative=${payload_file#"$mount_target"}
    [[ $relative == /* ]] || relative=/$relative
    payload_path="${fs_root%/}$relative"
    [[ $payload_path == /* && $payload_path != *..* &&
        $payload_path =~ ^[/A-Za-z0-9@._+-]+$ ]] || return 1
    printf ' arch_redeploy_payload_uuid=%s arch_redeploy_payload_fstype=%s arch_redeploy_payload_path=%s' \
        "$uuid" "$fs_type" "$payload_path"
}

ra_file_sha256() {
    if [[ -f $1 ]]; then
        ra_sha256 "$1"
    fi
}

ra_snapshot_boot_file() {
    local source=$1 destination=$2
    mkdir -p "$(dirname "$destination")"
    cp -a --reflink=auto "$source" "$destination"
}

ra_restore_scheduled_config() {
    local config=$1 backup=${2:-} original_sha=${3:-} scheduled_sha=${4:-} current_sha
    [[ -f $config ]] || return 0
    current_sha=$(ra_file_sha256 "$config")
    if [[ -n $original_sha && $current_sha == "$original_sha" ]]; then
        return 0
    fi
    if [[ -f $backup && -n $scheduled_sha && $current_sha == "$scheduled_sha" ]]; then
        cp -a --reflink=auto "$backup" "$config"
        sync "$config"
        return 0
    fi
    if grep -qF "$RA_BOOT_START" "$config"; then
        ra_warn "boot configuration changed after scheduling; removing only the owned menu block"
        ra_remove_marked_entry "$config"
        sync "$config"
    else
        ra_warn "boot configuration drifted; leaving the external changes untouched: $config"
    fi
}

ra_grub_next_entry() {
    local edit_command
    edit_command=$(ra_grub_command editenv || true)
    [[ -n $edit_command ]] || return 0
    "$edit_command" - list 2>/dev/null |
        sed -n 's/^next_entry=//p' | head -n1
}

ra_restore_grub_next_entry() {
    local original=${1:-} edit_command current
    edit_command=$(ra_grub_command editenv || true)
    [[ -n $edit_command ]] || return 0
    current=$(ra_grub_next_entry)
    if [[ -n $current && $current != "$RA_GRUB_ENTRY" ]]; then
        if [[ $current != "$original" ]]; then
            ra_warn "GRUB next_entry changed after scheduling; leaving the external selection untouched"
        fi
        return 0
    fi
    if [[ -n $original ]]; then
        "$edit_command" - set "next_entry=$original" 2>/dev/null || true
    else
        "$edit_command" - unset next_entry 2>/dev/null || true
    fi
}

ra_restore_extlinux_adv() {
    local adv=$1 backup=$2 original_sha=${3:-} scheduled_sha=${4:-} config=$5 current_sha
    if [[ ! -f $adv ]]; then
        return 0
    fi
    current_sha=$(ra_file_sha256 "$adv")
    [[ -n $original_sha && $current_sha == "$original_sha" ]] && return 0
    if [[ -f $backup && -n $scheduled_sha && $current_sha == "$scheduled_sha" ]]; then
        cp -a --reflink=auto "$backup" "$adv"
        sync "$adv"
        return 0
    fi
    ra_warn "extlinux ADV state changed after scheduling; clearing only the one-shot selector"
    extlinux --clear-once "$(dirname "$config")" 2>/dev/null || true
}

ra_current_bootnext() {
    efibootmgr 2>/dev/null | awk '/^BootNext:/ {print $2; exit}' || true
}

ra_restore_bootnext() {
    local original=${1:-} ours=${2:-} current
    current=$(ra_current_bootnext)
    if [[ -n $current && ( -z $ours || ${current,,} != "${ours,,}" ) ]]; then
        if [[ ${current,,} != "${original,,}" ]]; then
            ra_warn "BootNext changed after scheduling; leaving the external selection untouched"
        fi
        return 0
    fi
    if [[ -n $original ]]; then
        efibootmgr --bootnext "$original" 2>/dev/null || true
    elif [[ -n $ours && ${current,,} == "${ours,,}" ]]; then
        efibootmgr --delete-bootnext 2>/dev/null || true
    fi
}

ra_install_source_return_hook() {
    local runtime="$RA_STATE_DIR/runtime" kind unit unit_dir init_script init_dir
    install -d -m 0700 "$runtime/lib" || return 1
    install -m 0755 "$RA_PROJECT_ROOT/scripts/source-rollback.sh" "$runtime/source-rollback" || return 1
    install -m 0644 "$RA_PROJECT_ROOT/lib/common.sh" "$runtime/lib/common.sh" || return 1
    install -m 0644 "$RA_PROJECT_ROOT/lib/disk.sh" "$runtime/lib/disk.sh" || return 1
    install -m 0644 "$RA_PROJECT_ROOT/lib/detect.sh" "$runtime/lib/detect.sh" || return 1
    install -m 0644 "$RA_PROJECT_ROOT/lib/boot.sh" "$runtime/lib/boot.sh" || return 1
    # shellcheck disable=SC2016
    ra_state_update '.runtime.boot_dir = $boot_dir' --arg boot_dir "$RA_BOOT_DIR" || return 1

    if [[ ${ARCH_REDEPLOY_INIT_KIND:-} == systemd ]] || {
        [[ -z ${ARCH_REDEPLOY_INIT_KIND:-} && -d /run/systemd/system ]] &&
            command -v systemctl >/dev/null
    }; then
        kind=systemd
        unit_dir=${ARCH_REDEPLOY_SYSTEMD_UNIT_DIR:-/etc/systemd/system}
        unit="$unit_dir/arch-redeploy-return.service"
        if [[ -e $unit ]]; then
            ra_error "return-cleanup unit already exists: $unit"
            return 1
        fi
        # shellcheck disable=SC2016
        ra_state_update '.return_hook = {kind:"systemd-pending", path:$path}' --arg path "$unit" || return 1
        if ! cat >"$unit" <<EOF
[Unit]
Description=Restore source boot state after an aborted Arch redeploy
After=local-fs.target
Before=sshd.service
ConditionPathExists=$RA_STATE_FILE

[Service]
Type=oneshot
ExecStart=$runtime/source-rollback

[Install]
WantedBy=multi-user.target
EOF
        then
            return 1
        fi
        chmod 0644 "$unit" || return 1
        systemctl daemon-reload || return 1
        systemctl enable arch-redeploy-return.service || return 1
    elif [[ ${ARCH_REDEPLOY_INIT_KIND:-} == openrc ]] || {
        [[ -z ${ARCH_REDEPLOY_INIT_KIND:-} ]] && command -v rc-update >/dev/null
    }; then
        kind=openrc
        init_dir=${ARCH_REDEPLOY_OPENRC_INIT_DIR:-/etc/init.d}
        init_script="$init_dir/arch-redeploy-return"
        if [[ -e $init_script ]]; then
            ra_error "return-cleanup service already exists: $init_script"
            return 1
        fi
        # shellcheck disable=SC2016
        ra_state_update '.return_hook = {kind:"openrc-pending", path:$path}' --arg path "$init_script" || return 1
        if ! cat >"$init_script" <<EOF
#!/sbin/openrc-run
description="Restore source boot state after an aborted Arch redeploy"

depend() {
    need localmount
}

start() {
    ebegin "Restoring arch-redeploy source boot state"
    $runtime/source-rollback
    eend \$?
}
EOF
        then
            return 1
        fi
        chmod 0755 "$init_script" || return 1
        rc-update add arch-redeploy-return default || return 1
    else
        rm -rf "$runtime"
        ra_state_update 'del(.return_hook, .runtime)'
        ra_error "source rollback requires systemd or OpenRC"
        return 1
    fi
    # shellcheck disable=SC2016
    ra_state_update '.return_hook.kind = $kind' --arg kind "$kind" || return 1
}

ra_remove_source_return_hook() {
    local kind path
    ra_state_exists || return 0
    kind=$(jq -r '.return_hook.kind // "none"' "$RA_STATE_FILE")
    path=$(jq -r '.return_hook.path // empty' "$RA_STATE_FILE")
    case $kind in
        systemd|systemd-pending)
            systemctl disable arch-redeploy-return.service 2>/dev/null || true
            [[ -n $path ]] && rm -f "$path"
            systemctl daemon-reload 2>/dev/null || true
            ;;
        openrc|openrc-pending)
            rc-update del arch-redeploy-return default 2>/dev/null || true
            [[ -n $path ]] && rm -f "$path"
            ;;
    esac
    ra_state_update 'del(.return_hook, .runtime)' 2>/dev/null || true
}

ra_write_grub_entry() {
    local destination=$1 fs_uuid kernel_path initramfs_path payload_args
    fs_uuid=$(findmnt -T "$RA_BOOT_DIR" -rn -o UUID)
    [[ -n $fs_uuid ]] || return 1
    kernel_path=$(ra_grub_path "$RA_BOOT_DIR/vmlinuz") || return 1
    initramfs_path=$(ra_grub_path "$RA_BOOT_DIR/initramfs.img") || return 1
    payload_args=$(ra_payload_kernel_args) || return 1
    cat >"$destination" <<EOF
$RA_BOOT_START
set timeout=3
menuentry '$RA_GRUB_ENTRY' --unrestricted {
    insmod all_video
    search --no-floppy --fs-uuid --set=root $fs_uuid
    set btrfs_relative_path=n
    linux $kernel_path console=tty0 console=ttyS0,115200n8$payload_args
    initrd $initramfs_path
}
$RA_BOOT_END
EOF
}

ra_source_efi_label() {
    local compact
    compact=$(jq -r '.install_id // empty' "$RA_STATE_FILE")
    compact=${compact//-/}
    [[ $compact =~ ^[0-9A-Za-z]+$ ]] || return 1
    printf 'arch-redeploy-%.8s' "${compact,,}"
}

ra_efi_bootnums_by_label() {
    local label
    label=$(ra_source_efi_label)
    efibootmgr 2>/dev/null |
        awk -v label="$label" '$1 ~ /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]\*?$/ && $2 == label {
            value=$1; sub(/^Boot/, "", value); sub(/\*$/, "", value); print value
        }'
}

ra_clear_our_bootnext() {
    local bootnum=$1 current
    current=$(ra_current_bootnext)
    if [[ ${current,,} == "${bootnum,,}" ]]; then
        efibootmgr --delete-bootnext 2>/dev/null || true
    fi
}

ra_cleanup_uefi_schedule() {
    local efi_dir=$1 bootnum=${2:-} original_bootnext
    original_bootnext=$(jq -r '.schedule.original_bootnext // empty' "$RA_STATE_FILE" 2>/dev/null || true)
    if [[ -n $bootnum ]]; then
        ra_clear_our_bootnext "$bootnum"
        efibootmgr --bootnum "$bootnum" --delete-bootnum 2>/dev/null || true
    else
        while IFS= read -r bootnum; do
            [[ -n $bootnum ]] || continue
            ra_clear_our_bootnext "$bootnum"
            efibootmgr --bootnum "$bootnum" --delete-bootnum 2>/dev/null || true
        done < <(ra_efi_bootnums_by_label)
    fi
    ra_remove_owned_efi_dir "$efi_dir"
    ra_restore_bootnext "$original_bootnext" "$bootnum"
    if ra_state_exists; then
        ra_state_update 'del(.schedule)' 2>/dev/null || true
    fi
}

ra_remove_owned_efi_dir() {
    local efi_dir=$1 install_id
    [[ -e $efi_dir ]] || return 0
    install_id=$(jq -r '.install_id // empty' "$RA_STATE_FILE" 2>/dev/null || true)
    if [[ $efi_dir == */EFI/arch-redeploy && -n $install_id &&
        -f $efi_dir/install-id ]] && [[ $(cat "$efi_dir/install-id") == "$install_id" ]]; then
        rm -rf "$efi_dir"
    elif [[ -d $efi_dir && -z $(find "$efi_dir" -mindepth 1 -print -quit) ]]; then
        rmdir "$efi_dir"
    else
        ra_warn "leaving an unowned EFI directory untouched: $efi_dir"
    fi
}

ra_schedule_uefi() {
    local esp_info esp_mount esp_source esp_disk esp_part config efi_dir bootnum original_bootnext label
    local standalone_command
    esp_info=$(ra_find_esp) || ra_die "the EFI system partition is no longer mounted"
    IFS=$'\t' read -r esp_mount esp_source <<<"$esp_info"
    esp_disk=/dev/$(lsblk -ndo PKNAME "$esp_source")
    esp_part=$(lsblk -dnro PARTN "$esp_source")
    [[ -b $esp_disk && $esp_part =~ ^[0-9]+$ ]] || ra_die "cannot resolve EFI system partition identity"
    efi_dir="$esp_mount/EFI/arch-redeploy"
    label=$(ra_source_efi_label) || return 1
    standalone_command=$(ra_grub_command mkstandalone) || return 1
    [[ ! -e $efi_dir ]] || {
        ra_error "stale UEFI loader directory already exists: $efi_dir"
        return 1
    }
    [[ -z $(ra_efi_bootnums_by_label) ]] || {
        ra_error "a UEFI boot entry named $label already exists"
        return 1
    }
    config=$(mktemp "$RA_STATE_DIR/grub-efi.XXXXXX")
    original_bootnext=$(ra_current_bootnext)
    # shellcheck disable=SC2016
    ra_state_update '.schedule = {
        kind:"uefi-pending",
        efi_dir:$efi_dir,
        original_bootnext:$original_bootnext
    }' --arg efi_dir "$efi_dir" --arg original_bootnext "$original_bootnext" || {
        rm -f "$config"
        return 1
    }
    if ! mkdir -p "$efi_dir"; then
        rm -f "$config"
        ra_cleanup_uefi_schedule "$efi_dir"
        return 1
    fi
    printf '%s\n' "$(ra_state_get .install_id)" >"$efi_dir/install-id"
    chmod 0600 "$efi_dir/install-id"
    if ! ra_write_grub_entry "$config"; then
        rm -f "$config"
        ra_cleanup_uefi_schedule "$efi_dir"
        return 1
    fi
    if ! "$standalone_command" -O x86_64-efi \
        --modules="$RA_UEFI_GRUB_MODULES" \
        --fonts= --locales= --themes= \
        -o "$efi_dir/grubx64.efi" "boot/grub/grub.cfg=$config"; then
        rm -f "$config"
        ra_cleanup_uefi_schedule "$efi_dir"
        return 1
    fi
    rm -f "$config"
    if ! sync "$efi_dir"; then
        ra_cleanup_uefi_schedule "$efi_dir"
        return 1
    fi
    if ! efibootmgr --create-only --disk "$esp_disk" --part "$esp_part" \
        --label "$label" --loader '\EFI\arch-redeploy\grubx64.efi'; then
        ra_cleanup_uefi_schedule "$efi_dir"
        return 1
    fi
    bootnum=$(ra_efi_bootnums_by_label)
    if [[ ! $bootnum =~ ^[0-9A-Fa-f]{4}$ ]]; then
        ra_cleanup_uefi_schedule "$efi_dir"
        return 1
    fi
    if ! efibootmgr --bootnext "$bootnum"; then
        ra_cleanup_uefi_schedule "$efi_dir" "$bootnum"
        return 1
    fi
    # shellcheck disable=SC2016
    if ! ra_state_update '.schedule = {
        kind:"uefi",
        efi_dir:$efi_dir,
        bootnum:$bootnum,
        original_bootnext:$original_bootnext
    }' --arg efi_dir "$efi_dir" --arg bootnum "$bootnum" \
        --arg original_bootnext "$original_bootnext"; then
        ra_cleanup_uefi_schedule "$efi_dir" "$bootnum"
        return 1
    fi
}

ra_find_grub_cfg() {
    local candidate
    for candidate in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
        [[ -f $candidate ]] && { printf '%s' "$candidate"; return 0; }
    done
    find /boot -maxdepth 3 -type f -name grub.cfg -print -quit 2>/dev/null
}

ra_grub_command() {
    local name=$1
    command -v "grub-$name" 2>/dev/null ||
        command -v "grub2-$name" 2>/dev/null
}

ra_clear_grub_next_entry() {
    local edit_command
    edit_command=$(ra_grub_command editenv || true)
    if [[ -n $edit_command ]]; then
        "$edit_command" - unset next_entry 2>/dev/null || true
    fi
}

ra_schedule_bios_grub() {
    local cfg fs_type entry reboot_command rollback_dir backup original_sha scheduled_sha original_next
    cfg=$(ra_find_grub_cfg)
    [[ -n $cfg ]] || return 1
    fs_type=$(findmnt -T "$cfg" -rn -o FSTYPE) || return 1
    [[ -n $fs_type ]] || return 1
    ra_bios_grub_one_shot_capable "$cfg" "$fs_type" || return 1
    grep -qF "$RA_BOOT_START" "$cfg" && return 1
    rollback_dir="$RA_STATE_DIR/rollback"
    backup="$rollback_dir/grub.cfg"
    ra_snapshot_boot_file "$cfg" "$backup" || return 1
    original_sha=$(ra_file_sha256 "$cfg")
    original_next=$(ra_grub_next_entry)
    entry=$(mktemp "$RA_STATE_DIR/grub-entry.XXXXXX")
    if ! ra_write_grub_entry "$entry"; then rm -f "$entry"; return 1; fi
    # shellcheck disable=SC2016
    if ! ra_state_update '.schedule = {
        kind:"bios-grub-pending",
        config:$config,
        config_backup:$backup,
        original_sha256:$original_sha,
        original_next_entry:$original_next
    }' --arg config "$cfg" --arg backup "$backup" --arg original_sha "$original_sha" \
        --arg original_next "$original_next"; then
        rm -f "$entry"
        return 1
    fi
    if ! cat "$entry" >>"$cfg"; then
        rm -f "$entry"
        ra_restore_scheduled_config "$cfg" "$backup" "$original_sha"
        ra_state_update 'del(.schedule)' || true
        return 1
    fi
    rm -f "$entry"
    scheduled_sha=$(ra_file_sha256 "$cfg")
    # shellcheck disable=SC2016
    ra_state_update '.schedule.scheduled_sha256 = $sha' --arg sha "$scheduled_sha" || {
        ra_restore_scheduled_config "$cfg" "$backup" "$original_sha" "$scheduled_sha"
        ra_state_update 'del(.schedule)' || true
        return 1
    }
    if ! sync "$cfg"; then
        ra_restore_scheduled_config "$cfg" "$backup" "$original_sha" "$scheduled_sha"
        ra_state_update 'del(.schedule)' || true
        return 1
    fi
    reboot_command=$(ra_grub_command reboot) || {
        ra_restore_scheduled_config "$cfg" "$backup" "$original_sha" "$scheduled_sha"
        ra_state_update 'del(.schedule)' || true
        return 1
    }
    if ! "$reboot_command" "$RA_GRUB_ENTRY"; then
        ra_restore_grub_next_entry "$original_next"
        ra_restore_scheduled_config "$cfg" "$backup" "$original_sha" "$scheduled_sha"
        ra_state_update 'del(.schedule)' || true
        return 1
    fi
    if ! sync; then
        ra_restore_grub_next_entry "$original_next"
        ra_restore_scheduled_config "$cfg" "$backup" "$original_sha" "$scheduled_sha"
        ra_state_update 'del(.schedule)' || true
        return 1
    fi
    if ! ra_state_update '.schedule.kind = "bios-grub"'; then
        ra_restore_grub_next_entry "$original_next"
        ra_restore_scheduled_config "$cfg" "$backup" "$original_sha" "$scheduled_sha"
        ra_state_update 'del(.schedule)' || true
        return 1
    fi
}

ra_schedule_bios_extlinux() {
    local cfg extlinux_dir kernel_path initramfs_path payload_args adv rollback_dir config_backup adv_backup
    local original_sha scheduled_sha original_adv_sha scheduled_adv_sha
    cfg=$(find /boot -maxdepth 3 -type f -name extlinux.conf -print -quit 2>/dev/null)
    [[ -n $cfg ]] || return 1
    grep -qF "$RA_BOOT_START" "$cfg" && return 1
    command -v extlinux >/dev/null || ra_die "extlinux is required to schedule this host"
    extlinux_dir=$(dirname "$cfg")
    adv="$extlinux_dir/ldlinux.sys"
    [[ -f $adv ]] || return 1
    rollback_dir="$RA_STATE_DIR/rollback"
    config_backup="$rollback_dir/extlinux.conf"
    adv_backup="$rollback_dir/ldlinux.sys"
    ra_snapshot_boot_file "$cfg" "$config_backup" || return 1
    ra_snapshot_boot_file "$adv" "$adv_backup" || return 1
    original_sha=$(ra_file_sha256 "$cfg")
    original_adv_sha=$(ra_file_sha256 "$adv")
    kernel_path=$(ra_grub_path "$RA_BOOT_DIR/vmlinuz") || return 1
    initramfs_path=$(ra_grub_path "$RA_BOOT_DIR/initramfs.img") || return 1
    payload_args=$(ra_payload_kernel_args) || return 1
    # shellcheck disable=SC2016
    ra_state_update '.schedule = {
        kind:"bios-extlinux-pending",
        config:$config,
        config_backup:$config_backup,
        original_sha256:$original_sha,
        adv:$adv,
        adv_backup:$adv_backup,
        original_adv_sha256:$original_adv_sha
    }' --arg config "$cfg" --arg config_backup "$config_backup" \
        --arg original_sha "$original_sha" --arg adv "$adv" --arg adv_backup "$adv_backup" \
        --arg original_adv_sha "$original_adv_sha" || return 1
    if ! cat >>"$cfg" <<EOF
$RA_BOOT_START
LABEL arch-redeploy
  MENU LABEL $RA_GRUB_ENTRY
  LINUX $kernel_path
  INITRD $initramfs_path
  APPEND console=tty0 console=ttyS0,115200n8$payload_args
$RA_BOOT_END
EOF
    then
        ra_restore_scheduled_config "$cfg" "$config_backup" "$original_sha"
        ra_state_update 'del(.schedule)' || true
        return 1
    fi
    scheduled_sha=$(ra_file_sha256 "$cfg")
    # shellcheck disable=SC2016
    ra_state_update '.schedule.scheduled_sha256 = $sha' --arg sha "$scheduled_sha" || {
        ra_restore_scheduled_config "$cfg" "$config_backup" "$original_sha" "$scheduled_sha"
        ra_state_update 'del(.schedule)' || true
        return 1
    }
    if ! sync "$cfg"; then
        ra_restore_scheduled_config "$cfg" "$config_backup" "$original_sha" "$scheduled_sha"
        ra_state_update 'del(.schedule)' || true
        return 1
    fi
    if ! extlinux --once=arch-redeploy "$extlinux_dir"; then
        cp -a --reflink=auto "$adv_backup" "$adv"
        ra_restore_scheduled_config "$cfg" "$config_backup" "$original_sha" "$scheduled_sha"
        ra_state_update 'del(.schedule)' || true
        return 1
    fi
    if ! sync; then
        cp -a --reflink=auto "$adv_backup" "$adv"
        ra_restore_scheduled_config "$cfg" "$config_backup" "$original_sha" "$scheduled_sha"
        ra_state_update 'del(.schedule)' || true
        return 1
    fi
    scheduled_adv_sha=$(ra_file_sha256 "$adv")
    # shellcheck disable=SC2016
    if ! ra_state_update '.schedule.kind = "bios-extlinux" |
        .schedule.scheduled_adv_sha256 = $sha' --arg sha "$scheduled_adv_sha"; then
        cp -a --reflink=auto "$adv_backup" "$adv"
        ra_restore_scheduled_config "$cfg" "$config_backup" "$original_sha" "$scheduled_sha"
        ra_state_update 'del(.schedule)' || true
        return 1
    fi
}

ra_schedule_boot() {
    local mode
    ra_state_transition_allowed "$(ra_state_get .state)" scheduled ||
        ra_die "only prepared state can be scheduled"
    [[ $(jq -r '.schedule.kind // "none"' "$RA_STATE_FILE") == none ]] ||
        ra_die "an incomplete schedule record exists; run cancel before retrying"
    mode=$(ra_state_get .boot.mode)
    ra_stage_boot_files
    if ! ra_install_source_return_hook; then
        ra_remove_source_return_hook
        ra_remove_owned_boot_dir
        ra_die "could not install a reversible source-return cleanup hook"
    fi
    if [[ $mode == uefi ]]; then
        if ! ra_schedule_uefi; then
            ra_remove_source_return_hook
            ra_remove_owned_boot_dir
            ra_die "could not create a transactional one-shot UEFI boot entry"
        fi
    elif ! ra_schedule_bios_grub && ! ra_schedule_bios_extlinux; then
        ra_remove_source_return_hook
        ra_remove_owned_boot_dir
        ra_die "BIOS scheduling requires an existing GRUB or extlinux installation"
    fi
    # shellcheck disable=SC2016
    if ! ra_state_update '.state = "scheduled" | .scheduled_at = $time |
        .progress.completed.review = $time | .progress.current = "armed" |
        .progress.started_at = $time | .progress.updated_at = $time' \
        --arg time "$(date -u +%FT%TZ)"; then
        ra_unschedule_boot
        ra_remove_source_return_hook
        ra_die "could not record the scheduled state; the boot entry was disarmed"
    fi
}

ra_remove_owned_boot_dir() {
    local install_id pending
    install_id=$(jq -r '.install_id // empty' "$RA_STATE_FILE" 2>/dev/null || true)
    pending="${RA_BOOT_DIR}.pending-$install_id"
    if [[ -n $install_id && $pending == "${RA_BOOT_DIR}.pending-$install_id" &&
        -e $pending ]]; then
        rm -rf -- "$pending"
    fi
    [[ -e $RA_BOOT_DIR ]] || return 0
    if [[ -n $install_id && -f $RA_BOOT_DIR/install-id ]] &&
        [[ $(cat "$RA_BOOT_DIR/install-id") == "$install_id" ]]; then
        rm -rf "$RA_BOOT_DIR"
    elif [[ -d $RA_BOOT_DIR && -z $(find "$RA_BOOT_DIR" -mindepth 1 -print -quit) ]]; then
        rmdir "$RA_BOOT_DIR"
    else
        ra_warn "leaving an unowned boot-artifact directory untouched: $RA_BOOT_DIR"
    fi
}

ra_schedule_is_armed() {
    local kind bootnum config current adv scheduled_adv_sha
    ra_state_exists || return 1
    kind=$(jq -r '.schedule.kind // "none"' "$RA_STATE_FILE")
    case $kind in
        uefi)
            bootnum=$(jq -r '.schedule.bootnum // empty' "$RA_STATE_FILE")
            current=$(ra_current_bootnext)
            [[ -n $bootnum && ${current,,} == "${bootnum,,}" ]]
            ;;
        bios-grub)
            [[ $(ra_grub_next_entry) == "$RA_GRUB_ENTRY" ]]
            ;;
        bios-extlinux)
            config=$(jq -r '.schedule.config // empty' "$RA_STATE_FILE")
            adv=$(jq -r '.schedule.adv // empty' "$RA_STATE_FILE")
            scheduled_adv_sha=$(jq -r '.schedule.scheduled_adv_sha256 // empty' "$RA_STATE_FILE")
            [[ -f $config ]] && grep -qF "$RA_BOOT_START" "$config" &&
                [[ -f $RA_BOOT_DIR/install-id ]] && [[ -f $adv ]] &&
                [[ -n $scheduled_adv_sha ]] &&
                [[ $(ra_file_sha256 "$adv") == "$scheduled_adv_sha" ]]
            ;;
        *) return 1 ;;
    esac
}

ra_remove_marked_entry() {
    local file=$1 temporary
    [[ -f $file ]] || return 0
    temporary=$(mktemp "${file}.XXXXXX")
    awk -v start="$RA_BOOT_START" -v end="$RA_BOOT_END" '
        $0 == start {skip=1; next}
        $0 == end {skip=0; next}
        !skip {print}
    ' "$file" >"$temporary"
    cat "$temporary" >"$file"
    rm -f "$temporary"
}

ra_unschedule_boot() {
    local kind config efi_dir bootnum original_bootnext backup original_sha scheduled_sha
    local original_next adv adv_backup original_adv_sha scheduled_adv_sha
    ra_state_exists || return 0
    kind=$(jq -r '.schedule.kind // "none"' "$RA_STATE_FILE")
    case "$kind" in
        uefi|uefi-pending)
            efi_dir=$(jq -r .schedule.efi_dir "$RA_STATE_FILE")
            bootnum=$(jq -r '.schedule.bootnum // empty' "$RA_STATE_FILE")
            original_bootnext=$(jq -r '.schedule.original_bootnext // empty' "$RA_STATE_FILE")
            if [[ -n $bootnum ]]; then
                ra_clear_our_bootnext "$bootnum"
                efibootmgr --bootnum "$bootnum" --delete-bootnum 2>/dev/null || true
            else
                while IFS= read -r bootnum; do
                    [[ -n $bootnum ]] || continue
                    ra_clear_our_bootnext "$bootnum"
                    efibootmgr --bootnum "$bootnum" --delete-bootnum 2>/dev/null || true
                done < <(ra_efi_bootnums_by_label)
            fi
            ra_remove_owned_efi_dir "$efi_dir"
            ra_restore_bootnext "$original_bootnext" "$bootnum"
            ;;
        bios-grub|bios-grub-pending)
            config=$(jq -r .schedule.config "$RA_STATE_FILE")
            backup=$(jq -r '.schedule.config_backup // empty' "$RA_STATE_FILE")
            original_sha=$(jq -r '.schedule.original_sha256 // empty' "$RA_STATE_FILE")
            scheduled_sha=$(jq -r '.schedule.scheduled_sha256 // empty' "$RA_STATE_FILE")
            original_next=$(jq -r '.schedule.original_next_entry // empty' "$RA_STATE_FILE")
            ra_restore_scheduled_config "$config" "$backup" "$original_sha" "$scheduled_sha"
            ra_restore_grub_next_entry "$original_next"
            ;;
        bios-extlinux|bios-extlinux-pending)
            config=$(jq -r .schedule.config "$RA_STATE_FILE")
            backup=$(jq -r '.schedule.config_backup // empty' "$RA_STATE_FILE")
            original_sha=$(jq -r '.schedule.original_sha256 // empty' "$RA_STATE_FILE")
            scheduled_sha=$(jq -r '.schedule.scheduled_sha256 // empty' "$RA_STATE_FILE")
            adv=$(jq -r '.schedule.adv // empty' "$RA_STATE_FILE")
            adv_backup=$(jq -r '.schedule.adv_backup // empty' "$RA_STATE_FILE")
            original_adv_sha=$(jq -r '.schedule.original_adv_sha256 // empty' "$RA_STATE_FILE")
            scheduled_adv_sha=$(jq -r '.schedule.scheduled_adv_sha256 // empty' "$RA_STATE_FILE")
            ra_restore_scheduled_config "$config" "$backup" "$original_sha" "$scheduled_sha"
            if [[ -n $adv ]]; then
                ra_restore_extlinux_adv "$adv" "$adv_backup" "$original_adv_sha" \
                    "$scheduled_adv_sha" "$config"
            else
                extlinux --clear-once "$(dirname "$config")" 2>/dev/null || true
            fi
            ;;
    esac
    ra_remove_owned_boot_dir
    ra_state_update 'del(.schedule)' 2>/dev/null || true
}
