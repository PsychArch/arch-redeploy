#!/bin/bash

set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export LC_ALL=C

readonly CONFIG=/etc/arch-redeploy/config.json
readonly INSTALL_LOG=/arch-redeploy.log
readonly TARGET=/target
readonly RECOVERY_DIR=/target/arch-redeploy-recovery
readonly CURRENT_STAGE=/run/arch-redeploy-current-stage
readonly CANCEL_REQUEST=/run/arch-redeploy-cancel
readonly ERASE_STARTED=/run/arch-redeploy-erase-started
readonly BOUNDARY_LOCK=/run/arch-redeploy-boundary.lock
readonly ABORT_COUNTDOWN_SECONDS=60

# shellcheck source=installer/target.sh
source /usr/local/lib/arch-redeploy/target.sh
# shellcheck source=lib/stages.sh
source /usr/local/lib/arch-redeploy/stages.sh
# shellcheck source=lib/disk.sh
source /usr/local/lib/arch-redeploy/disk.sh

exec > >(tee -a "$INSTALL_LOG" /dev/console) 2>&1

failure_shell() {
    local line=$1 status=$2
    trap - ERR
    target_unmount_pseudo "$TARGET" 2>/dev/null || true
    if mountpoint -q "$TARGET/efi"; then umount "$TARGET/efi" 2>/dev/null || true; fi
    if mountpoint -q "$TARGET"; then umount "$TARGET" 2>/dev/null || true; fi
    echo
    echo "INSTALLER FAILED at line $line with status $status"
    echo "The installer will not reboot. Use the provider console or SSH and inspect $INSTALL_LOG."
    echo "Run /usr/local/lib/arch-redeploy/install.sh to retry."
    while true; do
        /bin/bash -l || true
    done
}
trap 'failure_shell "$LINENO" "$?"' ERR

set_installer_stage() {
    local stage=$1
    ra_stage_valid "$stage"
    printf '%s\n' "$stage" >"$CURRENT_STAGE"
    chmod 0600 "$CURRENT_STAGE"
    ra_render_timeline "$stage"
    echo
}

cancel_requested() { [[ -e $CANCEL_REQUEST ]]; }

return_to_source() {
    echo
    echo "Cancellation accepted before disk erasure."
    echo "Rebooting to the original source system; its rollback hook will remove owned boot changes."
    sync
    sleep 2
    reboot -f
    exit 0
}

honor_cancellation() {
    if cancel_requested; then
        return_to_source
    fi
    return 0
}

prewipe_abort_window() {
    local remaining reply=''
    echo "All recovery checks passed. This is the final opportunity to return to the source system."
    echo "Type 'cancel' here or run 'arch-redeploy cancel' over SSH within $ABORT_COUNTDOWN_SECONDS seconds."
    remaining=$ABORT_COUNTDOWN_SECONDS
    while ((remaining > 0)); do
        if read -r -t 0 reply && [[ ${reply,,} == cancel ]]; then
            : >"$CANCEL_REQUEST"
        fi
        honor_cancellation
        if ((remaining == 60 || remaining == 30 || remaining <= 10)); then
            printf 'Disk erasure begins in %d second(s).\n' "$remaining"
        fi
        sleep 1
        remaining=$((remaining - 1))
    done
    honor_cancellation
}

cross_erase_boundary() {
    local disk=$1
    exec 8>"$BOUNDARY_LOCK"
    flock 8
    honor_cancellation
    if ! disk_matches_manifest "$disk" || ! verify_original_partition_table "$disk"; then
        flock -u 8
        echo "The target disk changed during the final cancellation window; refusing erasure."
        return 1
    fi
    : >"$ERASE_STARTED"
    chmod 0600 "$ERASE_STARTED"
    flock -u 8
    wipefs -a -f "$disk"
    sync
}

target_root_label() {
    local compact
    compact=$(jq -r .install_id "$CONFIG")
    compact=${compact//-/}
    printf 'ra-%.12s' "$compact"
}

target_esp_label() {
    local compact
    compact=$(jq -r .install_id "$CONFIG")
    compact=${compact//-/}
    printf 'RA%.8s' "${compact^^}"
}

write_recovery_progress() {
    local stage=$1 temporary
    [[ -d $RECOVERY_DIR ]] || return 0
    ra_stage_valid "$stage"
    temporary="$RECOVERY_DIR/progress.json.new"
    jq -n --arg install_id "$(jq -r .install_id "$CONFIG")" --arg current "$stage" \
        --arg updated_at "$(date -u +%FT%TZ)" \
        '{install_id:$install_id,current:$current,updated_at:$updated_at}' >"$temporary"
    chmod 0600 "$temporary"
    mv -f "$temporary" "$RECOVERY_DIR/progress.json"
    sync "$RECOVERY_DIR/progress.json"
}

delete_efi_entries_by_label() {
    local label=$1 bootnum
    command -v efibootmgr >/dev/null || return 0
    while IFS= read -r bootnum; do
        [[ -n $bootnum ]] || continue
        efibootmgr --bootnum "$bootnum" --delete-bootnum 2>/dev/null || true
    done < <(efibootmgr 2>/dev/null |
        awk -v label="$label" '$1 ~ /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]\*?$/ && $2 == label {
            value=$1; sub(/^Boot/, "", value); sub(/\*$/, "", value); print value
        }')
}

final_boot_label() {
    local compact
    compact=$(jq -r .install_id "$CONFIG")
    compact=${compact//-/}
    printf 'Arch-%.8s' "$compact"
}

source_boot_label() {
    local compact
    compact=$(jq -r .install_id "$CONFIG")
    compact=${compact//-/}
    printf 'arch-redeploy-%.8s' "${compact,,}"
}

recovery_boot_label() {
    local compact
    compact=$(jq -r .install_id "$CONFIG")
    compact=${compact//-/}
    printf 'arch-redeploy-recovery-%.8s' "${compact,,}"
}

find_interface_by_mac() {
    local wanted=${1,,} iface
    for iface in /sys/class/net/*; do
        [[ $(cat "$iface/address" 2>/dev/null || true) == "$wanted" ]] && basename "$iface" && return 0
    done
    return 1
}

configure_live_family() {
    local family=$1 mode mac iface address gateway extra ipv6_ready=false
    mode=$(jq -r ".network.$family.mode" "$CONFIG")
    [[ $mode != none ]] || return 0
    mac=$(jq -r ".network.$family.mac" "$CONFIG")
    iface=$(find_interface_by_mac "$mac") || return 1
    ip link set "$iface" up || return 1
    if [[ $mode == dhcp && $family == ipv4 ]]; then
        udhcpc -q -n -t 5 -T 4 -i "$iface" -s /usr/local/lib/arch-redeploy/udhcpc.script || return 1
    elif [[ $mode == dhcp && $family == ipv6 ]]; then
        sysctl -q -w "net.ipv6.conf.$iface.accept_ra=2" || return 1
        for _ in $(seq 1 30); do
            if ip -6 address show dev "$iface" scope global | grep -q 'inet6 ' &&
                ip -6 route show default dev "$iface" | grep -q .; then
                ipv6_ready=true
                break
            fi
            sleep 1
        done
        $ipv6_ready || return 1
    else
        address=$(jq -r ".network.$family.address" "$CONFIG")
        gateway=$(jq -r ".network.$family.gateway" "$CONFIG")
        if [[ -n $address && $address != null ]]; then
            ip address replace "$address" dev "$iface" || return 1
        fi
        if [[ -n $gateway && $gateway != null ]]; then
            if [[ $family == ipv4 ]]; then
                ip route replace default via "$gateway" dev "$iface" onlink || return 1
            else
                ip -6 route replace default via "$gateway" dev "$iface" onlink || return 1
            fi
        elif [[ $family == ipv4 ]]; then
            ip route replace default dev "$iface" scope link || return 1
        else
            ip -6 route replace default dev "$iface" || return 1
        fi
    fi
    while IFS= read -r extra; do
        if [[ -n $extra ]]; then
            ip address replace "$extra" dev "$iface" || return 1
        fi
    done < <(jq -r ".network.$family.extra_addresses[]?" "$CONFIG")
}

configure_live_network() {
    local dns dns_count
    configure_live_family ipv4 || return 1
    configure_live_family ipv6 || return 1
    dns_count=$(jq '.network.dns | length' "$CONFIG")
    if ((dns_count > 0)); then
        : >/etc/resolv.conf
        while IFS= read -r dns; do
            [[ -n $dns ]] && printf 'nameserver %s\n' "$dns" >>/etc/resolv.conf
        done < <(jq -r '.network.dns[]?' "$CONFIG")
    fi
}

start_installer_ssh() {
    local port keys hash sshd_pid
    port=$(jq -r .admin.port "$CONFIG")
    keys=$(jq -r .admin.authorized_keys "$CONFIG")
    hash=$(jq -r .admin.password_hash "$CONFIG")
    ssh-keygen -A
    install -d -m 0700 /root/.ssh
    if [[ -n $keys ]]; then
        printf '%s\n' "$keys" >/root/.ssh/authorized_keys
        chmod 0600 /root/.ssh/authorized_keys
        usermod -p '!' root
    elif [[ -n $hash ]]; then
        usermod -p "$hash" root
    fi
    cat >/etc/ssh/sshd_config.d/10-arch-redeploy-installer.conf <<EOF
Port $port
PasswordAuthentication $([[ -n $keys ]] && echo no || echo yes)
PermitRootLogin yes
KbdInteractiveAuthentication no
EOF
    sshd -t
    if [[ -r /run/sshd.pid ]]; then
        sshd_pid=$(cat /run/sshd.pid)
        if [[ $sshd_pid =~ ^[0-9]+$ ]] && kill -0 "$sshd_pid" 2>/dev/null; then
            echo "Installer SSH is already listening on port $port"
            return 0
        fi
        rm -f /run/sshd.pid
    fi
    /usr/sbin/sshd
    echo "Installer SSH is listening on port $port"
}

validate_config() {
    jq -e '
        .protocol == "2" and
        (.install_id | type == "string" and test("^[0-9a-fA-F-]{36}$")) and
        (.disk.path | type == "string" and startswith("/dev/")) and
        (.disk.size | type == "number" and . >= 8589934592) and
        (.disk.partition_id | type == "string") and
        (.disk.partition_hash | type == "string" and test("^[0-9a-f]{64}$")) and
        (.boot.mode == "uefi" or .boot.mode == "bios") and
        (.admin.user | type == "string" and test("^[a-z_][a-z0-9_-]{0,31}$")) and
        (.admin.port | type == "number" and . >= 1 and . <= 65535) and
        (.payload.mode == "offline" or .payload.mode == "online") and
        (.mirrors.arch | type == "array" and length >= 1) and
        (if .payload.mode == "online" then (.mirrors.arch | length >= 2) else true end) and
        ([.network.ipv4.mode, .network.ipv6.mode] | all(. == "none" or . == "dhcp" or . == "static"))
    ' "$CONFIG" >/dev/null
}

disk_is_writable_whole() {
    local disk=$1 type read_only
    [[ -b $disk ]] || return 1
    type=$(lsblk -dnro TYPE "$disk") || return 1
    read_only=$(lsblk -dnro RO "$disk") || return 1
    [[ $type == disk && $read_only == 0 ]]
}

disk_matches_manifest() {
    local disk=$1 expected_size expected_serial expected_wwn expected_log_sec expected_phy_sec
    local current_size current_serial current_wwn current_log_sec current_phy_sec
    disk_is_writable_whole "$disk" || return 1
    expected_size=$(jq -r .disk.size "$CONFIG")
    expected_serial=$(jq -r '.disk.serial // ""' "$CONFIG")
    expected_wwn=$(jq -r '.disk.wwn // ""' "$CONFIG")
    expected_log_sec=$(jq -r '.disk["log-sec"] // ""' "$CONFIG")
    expected_phy_sec=$(jq -r '.disk["phy-sec"] // ""' "$CONFIG")
    current_size=$(lsblk -bdnro SIZE "$disk")
    current_serial=$(ra_disk_serial "$disk")
    current_wwn=$(lsblk -dnro WWN "$disk" | xargs)
    current_log_sec=$(lsblk -bdnro LOG-SEC "$disk")
    current_phy_sec=$(lsblk -bdnro PHY-SEC "$disk")
    [[ $current_size == "$expected_size" ]] || return 1
    [[ -z $expected_serial || $current_serial == "$expected_serial" ]] || return 1
    [[ -z $expected_wwn || $current_wwn == "$expected_wwn" ]] || return 1
    [[ -z $expected_log_sec || $current_log_sec == "$expected_log_sec" ]] || return 1
    [[ -z $expected_phy_sec || $current_phy_sec == "$expected_phy_sec" ]] || return 1
}

find_target_disk() {
    local candidate expected_path expected_serial expected_wwn
    local -a matches=()
    expected_path=$(jq -r .disk.path "$CONFIG")
    if [[ -b $expected_path ]] && disk_matches_manifest "$expected_path"; then
        printf '%s' "$expected_path"
        return
    fi
    expected_serial=$(jq -r '.disk.serial // ""' "$CONFIG")
    expected_wwn=$(jq -r '.disk.wwn // ""' "$CONFIG")
    [[ -n $expected_serial || -n $expected_wwn ]] || return 1
    while IFS= read -r candidate; do
        if disk_matches_manifest "$candidate"; then
            matches+=("$candidate")
        fi
    done < <(lsblk -dpnro NAME,TYPE | awk '$2 == "disk" {print $1}')
    ((${#matches[@]} == 1)) || return 1
    printf '%s' "${matches[0]}"
}

partition_name() {
    local disk=$1 number=$2
    [[ $disk =~ [0-9]$ ]] && printf '%sp%s' "$disk" "$number" || printf '%s%s' "$disk" "$number"
}

find_recovery_root() {
    local disk=$1 mode=$2 install_id part progress_id progress_stage
    install_id=$(jq -r .install_id "$CONFIG")
    part=$(target_root_partition "$disk" "$mode")
    [[ -b $part ]] || return 1
    mkdir -p "$TARGET"
    mount "$part" "$TARGET" 2>/dev/null || return 1
    if [[ -r $TARGET/arch-redeploy-recovery/install-id ]] &&
        [[ $(cat "$TARGET/arch-redeploy-recovery/install-id") == "$install_id" ]]; then
        if grep -qx recovery-installed "$TARGET/arch-redeploy-recovery/checkpoint" 2>/dev/null; then
            return 0
        fi
        if [[ -r $TARGET/arch-redeploy-recovery/progress.json ]]; then
            progress_id=$(jq -r '.install_id // empty' "$TARGET/arch-redeploy-recovery/progress.json")
            progress_stage=$(jq -r '.current // empty' "$TARGET/arch-redeploy-recovery/progress.json")
            if [[ $progress_id == "$install_id" ]] &&
                [[ $progress_stage == recovery || $progress_stage == install || $progress_stage == verify ]]; then
                return 0
            fi
        fi
    fi
    umount "$TARGET"
    return 1
}

find_owned_partial_root() {
    local disk=$1 mode=$2 part expected_label actual_label
    part=$(target_root_partition "$disk" "$mode")
    [[ -b $part ]] || return 1
    expected_label=$(target_root_label)
    actual_label=$(blkid -s LABEL -o value "$part" 2>/dev/null || true)
    [[ $actual_label == "$expected_label" ]] || return 1
    mkdir -p "$TARGET"
    mount "$part" "$TARGET" 2>/dev/null || return 1
    if [[ -e $TARGET/.arch-redeploy-install-id ]] &&
        [[ $(cat "$TARGET/.arch-redeploy-install-id") != "$(jq -r .install_id "$CONFIG")" ]]; then
        umount "$TARGET"
        return 1
    fi
    printf '%s\n' "$(jq -r .install_id "$CONFIG")" >"$TARGET/.arch-redeploy-install-id"
    chmod 0600 "$TARGET/.arch-redeploy-install-id"
    return 0
}

mount_owned_esp() {
    local disk=$1 esp_part expected_label actual_label
    esp_part=$(partition_name "$disk" 1)
    expected_label=$(target_esp_label)
    [[ -b $esp_part ]] || return 1
    mkdir -p "$TARGET/efi"
    if mount "$esp_part" "$TARGET/efi" 2>/dev/null; then
        actual_label=$(blkid -s LABEL -o value "$esp_part" 2>/dev/null || true)
        if [[ $actual_label == "$expected_label" ]]; then
            return 0
        fi
        umount "$TARGET/efi"
        echo "The partial EFI system partition has an unexpected label; refusing to claim it."
        return 1
    fi
    actual_label=$(blkid -s LABEL -o value "$esp_part" 2>/dev/null || true)
    if [[ -n $actual_label && $actual_label != "$expected_label" ]]; then
        echo "The partial EFI system partition is not owned by this install ID."
        return 1
    fi
    echo "Repairing the interrupted install-ID-owned EFI system partition."
    mkfs.fat -F 32 -n "$expected_label" "$esp_part"
    mount "$esp_part" "$TARGET/efi"
}

verify_original_partition_table() {
    local disk=$1 expected expected_id current current_id
    expected=$(jq -r .disk.partition_hash "$CONFIG")
    expected_id=$(jq -r .disk.partition_id "$CONFIG")
    current=$(ra_partition_table_hash "$disk") || return 1
    current_id=$(ra_partition_table_id "$disk") || return 1
    [[ $current == "$expected" && $current_id == "$expected_id" ]]
}

probe_arch_mirrors() {
    local mirror ok=0
    [[ $(jq -r .payload.mode "$CONFIG") == online ]] || return 0
    while IFS= read -r mirror; do
        honor_cancellation
        if curl -LfsS --connect-timeout 5 --max-time 15 --range 0-65535 \
            -o /dev/null "$mirror/core/os/x86_64/core.db"; then
            ((ok += 1))
        fi
    done < <(jq -r '.mirrors.arch[]' "$CONFIG")
    honor_cancellation
    ((ok >= 2))
}

verify_payload() {
    local mode expected archive
    mode=$(jq -r .payload.mode "$CONFIG")
    [[ $mode == offline ]] || return 0
    expected=$(jq -r .payload.rootfs_sha256 "$CONFIG")
    archive=/opt/arch-redeploy/rootfs.tar.zst
    [[ -r $archive ]] || archive="$RECOVERY_DIR/rootfs.tar.zst"
    [[ -r $archive ]] || return 1
    honor_cancellation
    [[ $(sha256sum "$archive" | awk '{print $1}') == "$expected" ]] || return 1
    honor_cancellation
}

target_root_partition() {
    local disk=$1 mode=$2
    if [[ $mode == uefi ]] || (( $(blockdev --getsize64 "$disk") > 2199023255552 )); then
        partition_name "$disk" 2
    else
        partition_name "$disk" 1
    fi
}

online_transaction_preflight() {
    local mode mirror name version suffix success required
    mode=$(jq -r .payload.mode "$CONFIG")
    [[ $mode == online ]] || return 0
    required=$(jq '.mirrors.arch | length' "$CONFIG")
    ((required >= 2)) || return 1
    while IFS=$'\t' read -r name version suffix; do
        honor_cancellation
        [[ $name =~ ^[a-zA-Z0-9@._+-]+$ && -n $version ]] || return 1
        [[ $suffix != /* && $suffix != *..* && $suffix == *.pkg.tar.* ]] || return 1
        success=0
        while IFS= read -r mirror; do
            if curl -LfsS --connect-timeout 5 --max-time 20 --range 0-4095 \
                -o /dev/null "$mirror/$suffix" &&
                curl -LfsS --connect-timeout 5 --max-time 20 --range 0-4095 \
                    -o /dev/null "$mirror/$suffix.sig"; then
                ((success += 1))
            fi
        done < <(jq -r '.mirrors.arch[]' "$CONFIG")
        honor_cancellation
        ((success >= 2)) || return 1
    done </etc/arch-redeploy/packages.lock
}

download_locked_package() {
    local suffix=$1 destination=$2 mirror
    while IFS= read -r mirror; do
        rm -f "$destination" "$destination.sig" "$destination.part" "$destination.sig.part"
        if curl -LfsS --retry 3 --retry-all-errors --connect-timeout 10 \
            --speed-limit 1024 --speed-time 60 --max-time 3600 \
            -o "$destination.part" "$mirror/$suffix" &&
            curl -LfsS --retry 3 --retry-all-errors --connect-timeout 10 \
                --speed-limit 128 --speed-time 60 --max-time 300 \
                -o "$destination.sig.part" "$mirror/$suffix.sig"; then
            mv "$destination.part" "$destination"
            mv "$destination.sig.part" "$destination.sig"
            if pacman-key --verify "$destination.sig" "$destination" >/dev/null 2>&1; then
                printf '%s' "$destination"
                return 0
            fi
        fi
    done < <(jq -r '.mirrors.arch[]' "$CONFIG")
    rm -f "$destination" "$destination.sig" "$destination.part" "$destination.sig.part"
    return 1
}

build_recovery_initramfs() {
    rm -f /run/recovery-initramfs.img
    (
        cd /
        find . -xdev \
            -path './proc' -prune -o \
            -path './sys' -prune -o \
            -path './dev' -prune -o \
            -path './run' -prune -o \
            -path './tmp' -prune -o \
            -path './target' -prune -o \
            -path './opt/arch-redeploy/rootfs.tar.zst' -prune -o \
            -print0 | cpio --null --quiet -o -H newc | gzip -1 >/run/recovery-initramfs.img
    )
    gzip -t /run/recovery-initramfs.img
}

create_partitions() {
    local disk=$1 mode=$2 root_part esp_part root_label esp_label install_id
    root_label=$(target_root_label)
    esp_label=$(target_esp_label)
    install_id=$(jq -r .install_id "$CONFIG")
    if [[ $mode == uefi ]]; then
        parted -s "$disk" -- mklabel gpt mkpart ESP fat32 1MiB 101MiB \
            mkpart arch-root ext4 101MiB 100% set 1 esp on
        partprobe "$disk"
        udevadm settle 2>/dev/null || sleep 2
        esp_part=$(partition_name "$disk" 1)
        root_part=$(partition_name "$disk" 2)
        mkfs.fat -F 32 -n "$esp_label" "$esp_part"
    elif (( $(blockdev --getsize64 "$disk") > 2199023255552 )); then
        parted -s "$disk" -- mklabel gpt mkpart bios-grub 1MiB 2MiB \
            mkpart arch-root ext4 2MiB 100% set 1 bios_grub on
        partprobe "$disk"
        udevadm settle 2>/dev/null || sleep 2
        root_part=$(partition_name "$disk" 2)
    else
        parted -s "$disk" -- mklabel msdos mkpart primary ext4 1MiB 100% set 1 boot on
        partprobe "$disk"
        udevadm settle 2>/dev/null || sleep 2
        root_part=$(partition_name "$disk" 1)
    fi
    mkfs.ext4 -F -L "$root_label" "$root_part"
    mount "$root_part" "$TARGET"
    printf '%s\n' "$install_id" >"$TARGET/.arch-redeploy-install-id"
    chmod 0600 "$TARGET/.arch-redeploy-install-id"
    if [[ $mode == uefi ]]; then
        mkdir -p "$TARGET/efi"
        mount "$esp_part" "$TARGET/efi"
    fi
}

install_recovery_boot() {
    local disk=$1 mode=$2 install_id root_label recovery_label
    install_id=$(jq -r .install_id "$CONFIG")
    root_label=$(target_root_label)
    install -d -m 0700 "$RECOVERY_DIR" "$RECOVERY_DIR/boot" "$RECOVERY_DIR/boot/grub"
    install -m 0600 /opt/arch-redeploy/vmlinuz "$RECOVERY_DIR/vmlinuz"
    install -m 0600 /run/recovery-initramfs.img "$RECOVERY_DIR/initramfs.img"
    printf '%s\n' "$install_id" >"$RECOVERY_DIR/install-id"
    chmod 0600 "$RECOVERY_DIR/install-id"
    if [[ -r /opt/arch-redeploy/rootfs.tar.zst ]]; then
        install -m 0600 /opt/arch-redeploy/rootfs.tar.zst "$RECOVERY_DIR/rootfs.tar.zst"
    fi
    cat >"$RECOVERY_DIR/boot/grub/grub.cfg" <<EOF
set timeout=3
set default=0
serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
terminal_input console serial
terminal_output console serial
menuentry 'Resume Arch reinstallation' {
    search --no-floppy --label --set=root $root_label
    linux /arch-redeploy-recovery/vmlinuz console=tty0 console=ttyS0,115200n8
    initrd /arch-redeploy-recovery/initramfs.img
}
EOF
    chmod 0600 "$RECOVERY_DIR/boot/grub/grub.cfg"
    if [[ $mode == uefi ]]; then
        recovery_label=$(recovery_boot_label)
        grub-install --target=x86_64-efi --efi-directory="$TARGET/efi" \
            --boot-directory="$RECOVERY_DIR/boot" --removable --no-nvram
        delete_efi_entries_by_label "$recovery_label"
        if ! grub-install --target=x86_64-efi --efi-directory="$TARGET/efi" \
            --boot-directory="$RECOVERY_DIR/boot" --bootloader-id="$recovery_label"; then
            echo "warning: recovery NVRAM registration failed; the removable UEFI fallback remains bootable"
        fi
        delete_efi_entries_by_label "$(source_boot_label)"
    else
        grub-install --target=i386-pc --boot-directory="$RECOVERY_DIR/boot" "$disk"
    fi
    printf 'recovery-installed\n' >"$RECOVERY_DIR/checkpoint"
    chmod 0600 "$RECOVERY_DIR/checkpoint"
    write_recovery_progress recovery
    sync
}

install_arch_root() {
    local mode name version suffix package_file package_identity cache
    local -a package_files=()
    mode=$(jq -r .payload.mode "$CONFIG")
    if [[ $mode == offline ]]; then
        local archive=/opt/arch-redeploy/rootfs.tar.zst
        [[ -r $archive ]] || archive="$RECOVERY_DIR/rootfs.tar.zst"
        tar --xattrs --acls --numeric-owner -I zstd -xpf "$archive" -C "$TARGET"
    else
        cache="$TARGET/var/cache/arch-redeploy"
        mkdir -p "$cache"
        while IFS=$'\t' read -r name version suffix; do
            [[ $name =~ ^[a-zA-Z0-9@._+-]+$ && -n $version ]] || return 1
            [[ $suffix != /* && $suffix != *..* && $suffix == *.pkg.tar.* ]] || return 1
            package_file="$cache/$(basename "$suffix")"
            package_file=$(download_locked_package "$suffix" "$package_file") || return 1
            package_identity=$(pacman -Qp --print-format $'%n\t%v' "$package_file") || return 1
            [[ $package_identity == "$name"$'\t'"$version" ]] || return 1
            package_files+=("$package_file")
        done </etc/arch-redeploy/packages.lock
        ((${#package_files[@]} > 0)) || return 1
        pacstrap -U "$TARGET" "${package_files[@]}"
        rm -rf "$cache"
    fi
}

write_fstab() {
    local disk=$1 mode=$2 root_part esp_part root_uuid esp_uuid
    if [[ $mode == uefi ]]; then
        root_part=$(partition_name "$disk" 2)
        esp_part=$(partition_name "$disk" 1)
    elif (( $(blockdev --getsize64 "$disk") > 2199023255552 )); then
        root_part=$(partition_name "$disk" 2)
    else
        root_part=$(partition_name "$disk" 1)
    fi
    root_uuid=$(blkid -s UUID -o value "$root_part")
    printf 'UUID=%s / ext4 defaults,noatime 0 1\n' "$root_uuid" >"$TARGET/etc/fstab"
    if [[ $mode == uefi ]]; then
        esp_uuid=$(blkid -s UUID -o value "$esp_part")
        printf 'UUID=%s /efi vfat umask=0077 0 2\n' "$esp_uuid" >>"$TARGET/etc/fstab"
    fi
}

install_final_boot() {
    local disk=$1 mode=$2 root_uuid boot_label
    target_mount_pseudo "$TARGET"
    root_uuid=$(findmnt -rn -o UUID "$TARGET")
    mkdir -p "$TARGET/boot/grub"
    cat >"$TARGET/etc/grub.d/41_arch_redeploy_recovery" <<EOF
#!/bin/sh
cat <<'GRUBEOF'
menuentry 'Arch redeploy recovery' {
    search --no-floppy --fs-uuid --set=root $root_uuid
    linux /arch-redeploy-recovery/vmlinuz console=tty0 console=ttyS0,115200n8
    initrd /arch-redeploy-recovery/initramfs.img
}
GRUBEOF
EOF
    chmod 0755 "$TARGET/etc/grub.d/41_arch_redeploy_recovery"
    sed -i \
        -e '/^GRUB_TIMEOUT=/d' \
        -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/d' \
        -e '/^GRUB_TERMINAL_INPUT=/d' \
        -e '/^GRUB_TERMINAL_OUTPUT=/d' \
        -e '/^GRUB_SERIAL_COMMAND=/d' \
        "$TARGET/etc/default/grub"
    cat >>"$TARGET/etc/default/grub" <<'EOF'
GRUB_TIMEOUT=3
GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200n8"
GRUB_TERMINAL_INPUT="console serial"
GRUB_TERMINAL_OUTPUT="console serial"
GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1"
EOF
    target_chroot "$TARGET" grub-mkconfig -o /boot/grub/grub.cfg
    target_chroot "$TARGET" grub-script-check /boot/grub/grub.cfg
    if [[ $mode == uefi ]]; then
        target_chroot "$TARGET" grub-install --target=x86_64-efi --efi-directory=/efi --removable --no-nvram
        boot_label=$(final_boot_label)
        delete_efi_entries_by_label "$boot_label"
        if ! target_chroot "$TARGET" grub-install --target=x86_64-efi --efi-directory=/efi \
            --bootloader-id="$boot_label"; then
            echo "warning: Arch NVRAM registration failed; the removable UEFI fallback remains bootable"
        fi
    else
        target_chroot "$TARGET" grub-install --target=i386-pc "$disk"
    fi
    target_unmount_pseudo "$TARGET"
}

validate_target() {
    [[ -r $TARGET/etc/arch-release ]]
    [[ -s $TARGET/boot/vmlinuz-linux ]]
    compgen -G "$TARGET/boot/initramfs-linux*.img" >/dev/null
    target_mount_pseudo "$TARGET"
    target_chroot "$TARGET" sshd -t
    target_chroot "$TARGET" systemctl -q is-enabled sshd.service
    target_chroot "$TARGET" systemctl -q is-enabled systemd-networkd.service
    target_unmount_pseudo "$TARGET"
    [[ -s $TARGET/boot/grub/grub.cfg ]]
}

main() {
    local disk mode payload_mode network_ready=false resuming=false partial=false repartition=false
    set_installer_stage revalidate
    validate_config
    if configure_live_network; then
        network_ready=true
    else
        echo "The captured network configuration could not be restored."
    fi
    start_installer_ssh
    disk=$(find_target_disk) || return 1
    mode=$(jq -r .boot.mode "$CONFIG")
    payload_mode=$(jq -r .payload.mode "$CONFIG")
    if find_recovery_root "$disk" "$mode"; then
        resuming=true
        : >"$ERASE_STARTED"
        echo "Found the persistent recovery checkpoint."
        if [[ $mode == uefi ]] && ! mountpoint -q "$TARGET/efi"; then
            mount_owned_esp "$disk"
        fi
    elif find_owned_partial_root "$disk" "$mode"; then
        partial=true
        : >"$ERASE_STARTED"
        echo "Found the matching partially created Arch layout."
        if [[ $mode == uefi ]] && ! mountpoint -q "$TARGET/efi"; then
            mount_owned_esp "$disk"
        fi
    elif [[ -e $ERASE_STARTED ]]; then
        partial=true
        repartition=true
        echo "Resuming the partition operation recorded by this running recovery environment."
    fi

    if ! $resuming && ! $partial; then
        honor_cancellation
    fi
    if ! $network_ready && { { ! $resuming && ! $partial; } || [[ $payload_mode == online ]]; }; then
        echo "A working captured network is required before crossing the destructive boundary."
        return 1
    fi
    if ! $network_ready; then
        echo "Continuing an offline recovery from the provider console; SSH may be unavailable."
    fi
    probe_arch_mirrors
    verify_payload
    online_transaction_preflight
    if ! $resuming && ! $partial; then
        honor_cancellation
    fi

    if $resuming; then
        echo "Resuming from the persistent recovery environment."
        set_installer_stage recovery
        build_recovery_initramfs
        install_recovery_boot "$disk" "$mode"
    elif $partial; then
        set_installer_stage recovery
        build_recovery_initramfs
        if $repartition; then
            create_partitions "$disk" "$mode"
        fi
        install_recovery_boot "$disk" "$mode"
    else
        build_recovery_initramfs
        verify_original_partition_table "$disk"
        honor_cancellation
        prewipe_abort_window
        cross_erase_boundary "$disk"
        set_installer_stage recovery
        create_partitions "$disk" "$mode"
        install_recovery_boot "$disk" "$mode"
    fi

    set_installer_stage install
    write_recovery_progress install
    install_arch_root
    write_fstab "$disk" "$mode"
    if ! target_mount_pseudo "$TARGET"; then
        target_unmount_pseudo "$TARGET"
        return 1
    fi
    if ! target_configure "$TARGET" "$CONFIG" ||
        ! target_chroot "$TARGET" mkinitcpio -P ||
        ! target_install_finalize_service "$TARGET"; then
        target_unmount_pseudo "$TARGET"
        return 1
    fi
    target_unmount_pseudo "$TARGET"
    set_installer_stage verify
    write_recovery_progress verify
    install_final_boot "$disk" "$mode"
    validate_target
    cp "$INSTALL_LOG" "$TARGET/var/log/arch-redeploy.log"
    sync
    echo "Arch installation completed successfully. Rebooting in 10 seconds."
    sleep 10
    reboot -f
}

main "$@"
