#!/bin/bash

[[ ${RA_TARGET_LOADED:-} == 1 ]] && return 0
RA_TARGET_LOADED=1

set -Eeuo pipefail

readonly RA_KEY_ONLY_PASSWORD_HASH=x

target_chroot() {
    local root=$1
    shift
    chroot "$root" /usr/bin/env -i \
        HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin \
        LANG=C.UTF-8 "$@"
}

target_mount_pseudo() {
    local root=$1
    mkdir -p "$root/dev" "$root/proc" "$root/sys" "$root/run" || return 1
    if ! mountpoint -q "$root/dev"; then
        mount --rbind /dev "$root/dev" || return 1
    fi
    mount --make-rslave "$root/dev" || return 1
    if ! mountpoint -q "$root/proc"; then
        mount -t proc proc "$root/proc" || return 1
    fi
    if ! mountpoint -q "$root/sys"; then
        mount --rbind /sys "$root/sys" || return 1
    fi
    mount --make-rslave "$root/sys" || return 1
    if ! mountpoint -q "$root/run"; then
        mount --rbind /run "$root/run" || return 1
    fi
    mount --make-rslave "$root/run" || return 1
}

target_unmount_pseudo() {
    local root=$1 path
    for path in run sys proc dev; do
        if mountpoint -q "$root/$path"; then
            umount -R "$root/$path" 2>/dev/null || umount -R -l "$root/$path" 2>/dev/null || true
        fi
    done
}

target_write_network() {
    local root=$1 config=$2 family mode mac address gateway file dns extra route
    local -A files=()
    local -A dhcp4=()
    local -A dhcp6=()
    local -A routes=()
    mkdir -p "$root/etc/systemd/network" || return 1
    rm -f "$root/etc/systemd/network"/*-arch-redeploy.network || return 1

    for family in ipv4 ipv6; do
        mode=$(jq -r ".network.$family.mode" "$config") || return 1
        [[ $mode != none ]] || continue
        mac=$(jq -r ".network.$family.mac" "$config") || return 1
        [[ -n $mac && $mac != null ]] || continue
        if [[ -z ${files[$mac]:-} ]]; then
            file="$root/etc/systemd/network/$((10 + ${#files[@]}))-arch-redeploy.network"
            files[$mac]=$file
            printf '[Match]\nMACAddress=%s\n\n[Network]\n' "$mac" >"$file" || return 1
        else
            file=${files[$mac]}
        fi
        case "$family:$mode" in
            ipv4:dhcp) dhcp4[$mac]=yes ;;
            ipv6:dhcp) dhcp6[$mac]=yes ;;
            *:static)
                address=$(jq -r ".network.$family.address" "$config") || return 1
                gateway=$(jq -r ".network.$family.gateway" "$config") || return 1
                if [[ -n $address && $address != null ]]; then
                    printf 'Address=%s\n' "$address" >>"$file" || return 1
                fi
                if [[ -n $gateway && $gateway != null ]]; then
                    printf -v route '\n[Route]\nGateway=%s\nGatewayOnLink=yes\n' "$gateway"
                elif [[ $family == ipv4 ]]; then
                    printf -v route '\n[Route]\nDestination=0.0.0.0/0\nScope=link\n'
                else
                    printf -v route '\n[Route]\nDestination=::/0\n'
                fi
                routes[$mac]+=$route
                ;;
        esac
        while IFS= read -r extra; do
            if [[ -n $extra ]]; then
                printf 'Address=%s\n' "$extra" >>"$file" || return 1
            fi
        done < <(jq -r ".network.$family.extra_addresses[]?" "$config")
    done

    for mac in "${!files[@]}"; do
        file=${files[$mac]}
        if [[ ${dhcp4[$mac]:-no} == yes && ${dhcp6[$mac]:-no} == yes ]]; then
            sed -i '/^\[Network\]$/a DHCP=yes' "$file" || return 1
        elif [[ ${dhcp4[$mac]:-no} == yes ]]; then
            sed -i '/^\[Network\]$/a DHCP=ipv4' "$file" || return 1
        elif [[ ${dhcp6[$mac]:-no} == yes ]]; then
            sed -i '/^\[Network\]$/a DHCP=ipv6\nIPv6AcceptRA=yes' "$file" || return 1
        fi
        while IFS= read -r dns; do
            if [[ -n $dns ]]; then
                sed -i "/^\[Network\]$/a DNS=$dns" "$file" || return 1
            fi
        done < <(jq -r '.network.dns[]?' "$config")
        printf '%s' "${routes[$mac]:-}" >>"$file" || return 1
        chmod 0644 "$file" || return 1
    done

    ln -snf /run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
}

target_configure() {
    local root=$1 config=$2 user port keys password_hash home
    local hostname timezone
    hostname=$(jq -r .identity.hostname "$config") || return 1
    timezone=$(jq -r .identity.timezone "$config") || return 1
    user=$(jq -r .admin.user "$config") || return 1
    port=$(jq -r .admin.port "$config") || return 1
    keys=$(jq -r .admin.authorized_keys "$config") || return 1
    password_hash=$(jq -r .admin.password_hash "$config") || return 1

    printf '%s\n' "$hostname" >"$root/etc/hostname" || return 1
    cat >"$root/etc/hosts" <<EOF
127.0.0.1 localhost
::1 localhost
127.0.1.1 $hostname ${hostname%%.*}
EOF
    printf 'LANG=C.UTF-8\n' >"$root/etc/locale.conf" || return 1
    [[ -e $root/usr/share/zoneinfo/$timezone ]] || timezone=UTC
    ln -snf "/usr/share/zoneinfo/$timezone" "$root/etc/localtime" || return 1
    : >"$root/etc/machine-id" || return 1

    if [[ $user != root ]]; then
        if ! grep -q "^$user:" "$root/etc/passwd"; then
            target_chroot "$root" useradd -m "$user" || return 1
        fi
        target_chroot "$root" usermod -a -G wheel "$user" || return 1
        install -d -m 0750 "$root/etc/sudoers.d" || return 1
        printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$user" >"$root/etc/sudoers.d/90-arch-redeploy-admin" || return 1
        chmod 0440 "$root/etc/sudoers.d/90-arch-redeploy-admin" || return 1
    fi
    home=$(awk -F: -v user="$user" '$1 == user {print $6}' "$root/etc/passwd")
    [[ -n $home ]] || home=/root
    install -d -m 0700 "$root$home/.ssh" || return 1
    if [[ -n $keys ]]; then
        printf '%s\n' "$keys" >"$root$home/.ssh/authorized_keys" || return 1
        chmod 0600 "$root$home/.ssh/authorized_keys" || return 1
        chown -R "$(awk -F: -v user="$user" '$1 == user {print $3":"$4}' "$root/etc/passwd")" "$root$home/.ssh" || return 1
        target_chroot "$root" usermod -p "$RA_KEY_ONLY_PASSWORD_HASH" "$user" || return 1
    elif [[ -n $password_hash ]]; then
        rm -f "$root$home/.ssh/authorized_keys" || return 1
        target_chroot "$root" usermod -p "$password_hash" "$user" || return 1
    fi

    install -d -m 0755 "$root/etc/ssh/sshd_config.d" || return 1
    cat >"$root/etc/ssh/sshd_config.d/10-arch-redeploy.conf" <<EOF
Port $port
PasswordAuthentication $([[ -n $keys ]] && echo no || echo yes)
KbdInteractiveAuthentication no
PermitRootLogin $([[ $user == root ]] && echo yes || echo prohibit-password)
EOF

    target_write_network "$root" "$config" || return 1
    target_chroot "$root" systemctl enable sshd.service systemd-networkd.service systemd-resolved.service || return 1
    target_chroot "$root" ssh-keygen -A || return 1
    target_chroot "$root" sshd -t
}

target_install_finalize_service() {
    local root=$1
    install -Dm0755 /usr/local/lib/arch-redeploy/finalize.sh \
        "$root/usr/local/lib/arch-redeploy/finalize.sh" || return 1
    install -Dm0644 /usr/local/lib/arch-redeploy/stages.sh \
        "$root/usr/local/lib/arch-redeploy/stages.sh" || return 1
    cat >"$root/etc/systemd/system/arch-redeploy-finalize.service" <<'EOF'
[Unit]
Description=Remove the temporary Arch redeploy recovery environment after a healthy first boot
After=network-online.target sshd.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/arch-redeploy/finalize.sh

[Install]
WantedBy=multi-user.target
EOF
    target_chroot "$root" systemctl enable arch-redeploy-finalize.service
}
