#!/usr/bin/env bash

[[ ${RA_DETECT_LOADED:-} == 1 ]] && return 0
RA_DETECT_LOADED=1

# shellcheck source=lib/common.sh
source "$RA_PROJECT_ROOT/lib/common.sh"
# shellcheck source=lib/disk.sh
source "$RA_PROJECT_ROOT/lib/disk.sh"

ra_package_manager() {
    local id='' like=''
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        id=${ID:-}
        like=${ID_LIKE:-}
    fi
    case " $id $like " in
        *' alpine '*) command -v apk >/dev/null && echo apk ;;
        *' arch '*) command -v pacman >/dev/null && echo pacman ;;
        *' debian '*|*' ubuntu '*) command -v apt-get >/dev/null && echo apt-get ;;
        *' fedora '*|*' rhel '*|*' centos '*)
            if command -v dnf >/dev/null; then
                echo dnf
            elif command -v yum >/dev/null; then
                echo yum
            fi
            ;;
        *' suse '*|*' opensuse '*) command -v zypper >/dev/null && echo zypper ;;
    esac
}

ra_is_container() {
    local kind
    if command -v systemd-detect-virt >/dev/null; then
        kind=$(systemd-detect-virt --container 2>/dev/null || true)
        [[ -n $kind && $kind != none ]]
        return
    fi
    [[ -e /.dockerenv || -e /run/.containerenv ]] ||
        grep -Eq '(docker|lxc|containerd|kubepods)' /proc/1/cgroup 2>/dev/null
}

ra_is_virtual_machine() {
    local kind product_name=''
    if command -v systemd-detect-virt >/dev/null; then
        kind=$(systemd-detect-virt --vm 2>/dev/null || true)
        [[ -n $kind && $kind != none ]]
        return
    fi
    [[ -r /sys/class/dmi/id/product_name ]] && read -r product_name </sys/class/dmi/id/product_name
    [[ $product_name =~ (KVM|QEMU|Virtual|VMware|HVM|Hyper-V|Bochs|Parallels) ]]
}

ra_secure_boot_enabled() {
    local variable
    for variable in /sys/firmware/efi/efivars/SecureBoot-*; do
        [[ -r $variable ]] || continue
        [[ $(od -An -t u1 -j 4 -N 1 "$variable" | tr -d ' ') == 1 ]] && return 0
    done
    return 1
}

ra_boot_mode() {
    [[ -d /sys/firmware/efi ]] && echo uefi || echo bios
}

ra_root_disks() {
    local source
    source=$(findmnt -rn -o SOURCE /) || return 1
    source=${source%%\[*}
    lsblk -srnpo NAME,TYPE "$source" | awk '$2 == "disk" {print $1}' | sort -u
}

ra_list_disks() {
    lsblk -Jbdo NAME,PATH,SIZE,MODEL,SERIAL,WWN,RO,RM,TYPE |
        jq -c '.blockdevices[] | select(.type == "disk") | select(.ro == false)'
}

ra_is_block_device() {
    [[ -b $1 ]]
}

ra_select_target_disk() {
    local root_disks default_disk selection disk_path resolved_default
    root_disks=$(ra_root_disks || true)
    default_disk=$(printf '%s\n' "$root_disks" | head -n1)

    [[ -n $default_disk ]] || ra_die "could not resolve the source root disk"
    resolved_default=$(readlink -f "$default_disk")
    selection=$(ra_list_disks | jq -c --arg path "$resolved_default" 'select(.path == $path)' | sed -n '1p')
    [[ -n $selection ]] || ra_die "the source root disk is not an eligible writable whole disk"
    ra_info "source root disk selected as the redeploy target"
    jq -r '"  \(.path)  \(.size | tostring) bytes  \(.model // "unknown")  serial=\(.serial // "unknown")"' \
        <<<"$selection" >&2
    disk_path=$(ra_prompt_default "Confirm target disk (all data will be erased after reboot)" "$resolved_default")
    ra_is_block_device "$disk_path" || ra_die "not a block device: $disk_path"
    lsblk -dnro TYPE "$disk_path" | grep -qx disk || ra_die "not a whole disk: $disk_path"
    disk_path=$(readlink -f "$disk_path")
    [[ $disk_path == "$resolved_default" ]] ||
        ra_die "v1 only reinstalls the single disk backing the current root filesystem: $resolved_default"
    printf '%s' "$disk_path"
}

ra_disk_identity() {
    local disk=$1 partition_id partition_hash disk_json serial
    disk_json=$(lsblk -Jbdo NAME,PATH,SIZE,MODEL,SERIAL,WWN,RO,RM,LOG-SEC,PHY-SEC,TYPE "$disk" |
        jq -c '.blockdevices[0]')
    [[ $disk_json != null ]] || return 1
    serial=$(ra_disk_serial "$disk") || return 1
    partition_id=$(ra_partition_table_id "$disk") || return 1
    partition_hash=$(ra_partition_table_hash "$disk") || return 1
    jq -n \
        --argjson disk "$disk_json" \
        --arg serial "$serial" \
        --arg partition_id "$partition_id" \
        --arg partition_hash "$partition_hash" \
        '$disk + {
          serial: (if $serial == "" then null else $serial end),
          partition_id: $partition_id,
          partition_hash: $partition_hash
        }'
}

ra_validate_disk_identity() {
    local expected_json=$1 path current
    path=$(jq -r .path <<<"$expected_json")
    [[ -b $path ]] || return 1
    current=$(ra_disk_identity "$path") || return 1
    ra_disk_identity_matches "$expected_json" "$current"
}

ra_disk_identity_matches() {
    local expected_json=$1 current_json=$2
    jq -e --argjson current "$current_json" '
        (.size == $current.size) and
        ((.wwn // "") == ($current.wwn // "")) and
        ((.serial // "") == ($current.serial // "")) and
        ((.["log-sec"] // "") == ($current["log-sec"] // "")) and
        ((.["phy-sec"] // "") == ($current["phy-sec"] // "")) and
        (.partition_id == $current.partition_id) and
        (.partition_hash == $current.partition_hash)
    ' <<<"$expected_json" >/dev/null
}

ra_detect_timezone() {
    local timezone=
    timezone=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    if [[ -z $timezone && -r /etc/timezone ]]; then
        read -r timezone </etc/timezone
    fi
    if [[ -z $timezone && -L /etc/localtime ]]; then
        timezone=$(readlink -f /etc/localtime)
        timezone=${timezone#*/usr/share/zoneinfo/}
    fi
    printf '%s' "${timezone:-UTC}"
}

ra_detect_admin() {
    local user home port='' key_file keys password_hash
    user=${SUDO_USER:-${DOAS_USER:-root}}
    getent passwd "$user" >/dev/null || user=root
    home=$(getent passwd "$user" | cut -d: -f6)
    if command -v sshd >/dev/null; then
        port=$(sshd -T 2>/dev/null |
            awk '$1 == "port" {print $2; exit}' || true)
    fi
    port=${port:-22}
    key_file="$home/.ssh/authorized_keys"
    keys=
    if [[ -r $key_file ]]; then
        keys=$(awk '$0 !~ /^[[:space:]]*#/ &&
            $0 ~ /(^|[[:space:]])(ssh-(ed25519|rsa)(-cert-v01@openssh.com)?|ecdsa-sha2-nistp(256|384|521)(-cert-v01@openssh.com)?|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]/ {
                print
            }' "$key_file")
    fi
    password_hash=$(getent shadow "$user" 2>/dev/null | cut -d: -f2 || true)
    jq -n --arg user "$user" --arg port "$port" --arg keys "$keys" --arg password_hash "$password_hash" '
        {user: $user, port: ($port | tonumber), authorized_keys: $keys, password_hash: $password_hash}'
}

ra_review_admin() {
    local admin_json=$1 user port keys password_hash reply
    user=$(jq -r .user <<<"$admin_json")
    port=$(jq -r .port <<<"$admin_json")
    keys=$(jq -r .authorized_keys <<<"$admin_json")
    password_hash=$(jq -r .password_hash <<<"$admin_json")

    user=$(ra_prompt_default "Target administrative user" "$user")
    [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || ra_die "invalid administrative user name"
    port=$(ra_prompt_default "SSH port" "$port")
    if ! [[ $port =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
        ra_die "invalid SSH port"
    fi

    if [[ -z $keys ]]; then
        ra_warn "no usable authorized key was found for $user"
        read -r -p "Paste an SSH public key, or leave blank to reuse the current password hash: " reply
        if [[ -n $reply ]]; then
            [[ $reply =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]] ]] ||
                ra_die "invalid SSH public key"
            keys=$reply
            password_hash='!'
        elif [[ -z $password_hash || $password_hash == '!'* || $password_hash == '*'* ]]; then
            ra_die "no SSH key or usable password hash is available"
        fi
    else
        ra_info "preserving $(grep -c . <<<"$keys") authorized SSH key(s); target password login will be disabled"
        password_hash='!'
    fi

    jq -n --arg user "$user" --argjson port "$port" --arg keys "$keys" --arg password_hash "$password_hash" '
        {user: $user, port: $port, authorized_keys: $keys, password_hash: $password_hash}'
}

ra_default_route_json() {
    local family=$1
    ip -j "-$family" route show default 2>/dev/null | jq -c '.[0] // empty'
}

ra_capture_network_family() {
    local family=$1 route interface gateway mac family_config interface_kind
    route=$(ra_default_route_json "$family" || true)
    if [[ -z $route ]]; then
        jq -n '{mode:"none"}'
        return
    fi
    interface=$(jq -r '.dev // empty' <<<"$route")
    gateway=$(jq -r '.gateway // empty' <<<"$route")
    [[ -n $interface ]] || { jq -n '{mode:"none"}'; return; }
    family_config=$(ip -j "-$family" address show dev "$interface" scope global 2>/dev/null |
        jq -ce '
          def is_dynamic:
            (.dynamic == true) or
            ((.flags // []) |
              if type == "array" then
                any(.[]; type == "string" and ascii_downcase == "dynamic")
              elif type == "string" then
                test("(^|[[:space:],])dynamic([[:space:],]|$)"; "i")
              else
                false
              end);
          [
            .[0].addr_info[]? |
            select(.scope == "global") |
            {
              cidr: (.local + "/" + (.prefixlen | tostring)),
              dynamic: is_dynamic
            }
          ] as $addresses |
          if ($addresses | length) == 0 then
            {mode: "none"}
          elif any($addresses[]; .dynamic) then
            {
              mode: "dhcp",
              address: "",
              extra_addresses: [
                $addresses[] | select(.dynamic | not) | .cidr
              ]
            }
          else
            {
              mode: "static",
              address: $addresses[0].cidr,
              extra_addresses: [$addresses[1:][] | .cidr]
            }
          end' 2>/dev/null) ||
        ra_die "could not inspect global IPv${family} addresses on $interface"
    if [[ $(jq -r .mode <<<"$family_config") == none ]]; then
        ra_warn "ignoring an IPv${family} default route on $interface without a usable global address"
        printf '%s\n' "$family_config"
        return
    fi
    interface_kind=$(ip -d -j link show dev "$interface" |
        jq -r '.[0].linkinfo.info_kind // empty' 2>/dev/null || true)
    [[ -z $interface_kind ]] ||
        ra_die "layered default-route interfaces are not supported yet: $interface ($interface_kind)"
    mac=$(cat "/sys/class/net/$interface/address")
    jq -n --arg interface "$interface" --arg mac "$mac" --arg gateway "$gateway" \
        --argjson family_config "$family_config" \
        '$family_config + {interface:$interface, mac:$mac, gateway:$gateway}'
}

ra_capture_network() {
    local dns ipv4 ipv6
    dns=$(ra_capture_dns) || return 1
    ipv4=$(ra_capture_network_family 4) || return 1
    ipv6=$(ra_capture_network_family 6) || return 1
    jq -n --argjson ipv4 "$ipv4" --argjson ipv6 "$ipv6" --argjson dns "$dns" \
        '{ipv4:$ipv4, ipv6:$ipv6, dns:$dns}'
}

ra_capture_dns() {
    local resolver_file
    resolver_file=/etc/resolv.conf
    if grep -Eq '^nameserver[[:space:]]+(127\.0\.0\.(1|53)|::1)([[:space:]]|$)' "$resolver_file" 2>/dev/null &&
        [[ -r /run/systemd/resolve/resolv.conf ]]; then
        resolver_file=/run/systemd/resolve/resolv.conf
    fi
    awk '/^nameserver[[:space:]]/ {
        if ($2 != "127.0.0.1" && $2 != "127.0.0.53" && $2 != "::1") print $2
    }' "$resolver_file" | sort -u | ra_json_array_from_lines
}

ra_find_esp() {
    local target source _fstype
    while read -r target source _fstype; do
        case "$target" in
            /efi|/boot/efi|/boot) printf '%s\t%s\n' "$target" "$source"; return 0 ;;
        esac
    done < <(findmnt -rn -o TARGET,SOURCE,FSTYPE | awk '$3 ~ /^(vfat|fat|msdos)$/')
    return 1
}

ra_path_backing_disks() {
    local path=$1 source
    source=$(findmnt -T "$path" -rn -o SOURCE) || return 1
    source=${source%%\[*}
    lsblk -srnpo NAME,TYPE "$source" | awk '$2 == "disk" {print $1}' | sort -u
}

ra_validate_boot_storage_target() {
    local target=$1 esp_info esp_source
    local -a boot_disks=() esp_disks=()
    target=$(readlink -f "$target")
    mapfile -t boot_disks < <(ra_path_backing_disks /boot)
    if ((${#boot_disks[@]} != 1)) ||
        [[ $(readlink -f "${boot_disks[0]}") != "$target" ]]; then
        ra_die "the boot filesystem must be on the selected root disk: $target"
    fi
    if [[ $(ra_boot_mode) == uefi ]]; then
        esp_info=$(ra_find_esp) || ra_die "the EFI system partition is no longer mounted"
        IFS=$'\t' read -r _ esp_source <<<"$esp_info"
        mapfile -t esp_disks < <(lsblk -srnpo NAME,TYPE "$esp_source" |
            awk '$2 == "disk" {print $1}' | sort -u)
        if ((${#esp_disks[@]} != 1)) ||
            [[ $(readlink -f "${esp_disks[0]}") != "$target" ]]; then
            ra_die "the EFI system partition must be on the selected root disk: $target"
        fi
    fi
}

ra_preflight_host() {
    [[ $(uname -m) == "$RA_ARCH" ]] || ra_die "only x86_64 hosts are supported"
    ra_is_container && ra_die "containers are not supported"
    ra_secure_boot_enabled && ra_die "disable Secure Boot before preparing a redeploy"
    [[ $(findmnt -rn -o FSTYPE /) != tmpfs ]] || ra_die "live tmpfs roots are not supported"
    local memory_mib
    local -a root_disks=()
    memory_mib=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    ((memory_mib >= 512)) || ra_die "at least 512 MiB RAM is required"
    mapfile -t root_disks < <(ra_root_disks)
    ((${#root_disks[@]} == 1)) ||
        ra_die "the source root must resolve to exactly one physical disk; RAID and multipath roots are unsupported"
    ra_package_manager >/dev/null || ra_die "supported source families are apt, dnf/yum, zypper, apk, and pacman"
    if [[ $(ra_boot_mode) == uefi ]]; then
        ra_find_esp >/dev/null || ra_die "UEFI mode requires a mounted EFI system partition at /efi, /boot/efi, or /boot"
        [[ -w /sys/firmware/efi/efivars ]] || ra_die "EFI variables are not writable"
    fi
}
