#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap '[[ $TEST_ROOT == /tmp/* ]] && rm -rf "$TEST_ROOT"' EXIT

export RA_PROJECT_ROOT=$PROJECT_ROOT
export ARCH_REDEPLOY_STATE_DIR="$TEST_ROOT/state"
export ARCH_REDEPLOY_BOOT_DIR="$TEST_ROOT/boot"

# shellcheck source=lib/common.sh
source "$PROJECT_ROOT/lib/common.sh"
# shellcheck source=lib/stages.sh
source "$PROJECT_ROOT/lib/stages.sh"
# shellcheck source=lib/detect.sh
source "$PROJECT_ROOT/lib/detect.sh"
# shellcheck source=lib/mirrors.sh
source "$PROJECT_ROOT/lib/mirrors.sh"
# shellcheck source=lib/build.sh
source "$PROJECT_ROOT/lib/build.sh"
# shellcheck source=lib/boot.sh
source "$PROJECT_ROOT/lib/boot.sh"
# shellcheck source=installer/target.sh
source "$PROJECT_ROOT/installer/target.sh"

tests=0

pass() {
    printf 'ok %d - %s\n' "$tests" "$1"
}

fail() {
    printf 'not ok %d - %s\n' "$tests" "$1" >&2
    exit 1
}

assert() {
    local name=$1
    shift
    ((tests += 1))
    if "$@"; then pass "$name"; else fail "$name"; fi
}

assert_eq() {
    local name=$1 expected=$2 actual=$3
    ((tests += 1))
    if [[ $actual == "$expected" ]]; then
        pass "$name"
    else
        printf 'expected: %q\nactual:   %q\n' "$expected" "$actual" >&2
        fail "$name"
    fi
}

mkdir -p "$RA_STATE_DIR"
printf '{"state":"prepared","value":1}\n' >"$RA_STATE_FILE"
# shellcheck disable=SC2016 # jq program must receive $value literally.
ra_state_update '.value = $value' --argjson value 2
assert_eq "atomic state update" "2" "$(jq -r .value "$RA_STATE_FILE")"
assert "state remains valid JSON" jq -e . "$RA_STATE_FILE"
state_before=$(cat "$RA_STATE_FILE")
# shellcheck disable=SC2016 # positional parameters are expanded by the child shell.
assert "failed state updates are rejected" bash -c \
    'source "$1/lib/common.sh"; ! ra_state_update "(" 2>/dev/null' _ "$PROJECT_ROOT"
assert_eq "failed state update preserves the original" "$state_before" "$(cat "$RA_STATE_FILE")"

assert "preparing can transition to prepared" ra_state_transition_allowed preparing prepared
assert "prepared can transition to scheduled" ra_state_transition_allowed prepared scheduled
# shellcheck disable=SC2016 # positional parameters are expanded by the child shell.
assert "scheduled cannot transition back to prepared" bash -c \
    'source "$1/lib/common.sh"; ! ra_state_transition_allowed scheduled prepared' _ "$PROJECT_ROOT"

assert "adjacent guided stages can advance" ra_stage_transition_allowed inspect build
# shellcheck disable=SC2016 # positional parameter is expanded by the child shell.
assert "guided stages cannot be skipped" bash -c \
    'source "$1/lib/stages.sh"; ! ra_stage_transition_allowed build armed' _ "$PROJECT_ROOT"

timeline=$(ra_render_timeline install)
assert_eq "timeline marks only one current stage" "1" "$(grep -c '^ > ' <<<"$timeline")"
assert "timeline marks the numbered current item" grep -q '^ > 7\. Install and configure Arch$' <<<"$timeline"
# shellcheck disable=SC2016 # positional parameter is expanded by the child shell.
assert "timeline omits inferred status words" bash -c \
    '! grep -Eq "\[(done|next|later)\]" <<<"$1"' _ "$timeline"

printf '%s\n' '{
  "state":"preparing",
  "progress":{"current":"build","completed":{"inspect":"earlier"}}
}' >"$RA_STATE_FILE"
ra_progress_set review
assert_eq "progress journal advances atomically" "review" "$(jq -r .progress.current "$RA_STATE_FILE")"
assert "progress journal records the completed stage" jq -e '.progress.completed.build' "$RA_STATE_FILE"

printf '%s\n' '{"state":"prepared"}' >"$RA_STATE_FILE"
assert_eq "legacy prepared state maps to review" "review" "$(ra_progress_current)"

assert_eq "boot RAM calculation includes duplicate image space and reserve" \
    "402653484" "$(ra_boot_memory_required 100 50)"
assert_eq "boot RAM calculation reserves separately staged payload memory" \
    "402654484" "$(ra_boot_memory_required 100 50 1000)"
test_key_only_hash_is_unlocked() {
    [[ $RA_KEY_ONLY_PASSWORD_HASH != '!'* && $RA_KEY_ONLY_PASSWORD_HASH != '*'* ]]
}
assert "key-only accounts remain unlocked for OpenSSH public-key authentication" \
    test_key_only_hash_is_unlocked
# shellcheck disable=SC2016 # positional parameters are expanded by the child shell.
assert "online mode rejects one mirror" bash -c \
    'source "$1/lib/common.sh"; ! ra_online_mirror_count_valid '\''["https://one.example"]'\''' _ "$PROJECT_ROOT"
assert "online mode accepts two mirrors" ra_online_mirror_count_valid \
    '["https://one.example","https://two.example"]'

test_dependencies_are_read_only() (
    local package_log="$TEST_ROOT/package-manager.log"
    ra_package_manager() { echo apt-get; }
    # shellcheck disable=SC2317,SC2329 # The assertion fails if production code invokes this mock.
    apt-get() { printf 'called\n' >"$package_log"; }
    # shellcheck disable=SC2317,SC2329 # Production code invokes the command builtin indirectly.
    command() {
        [[ $1 == -v ]] && return 1
        builtin command "$@"
    }
    if ra_ensure_host_dependencies >/dev/null 2>&1; then return 1; fi
    [[ ! -e $package_log ]]
)
assert "dependency preflight never invokes a package manager" test_dependencies_are_read_only

test_legacy_sfdisk_is_rejected() (
    local output
    # shellcheck disable=SC2317,SC2329 # Capability fixture reports every executable except sfdisk JSON.
    command() {
        [[ $1 == -v ]] && return 0
        builtin command "$@"
    }
    sfdisk() {
        [[ ${1:-} == --help ]] || return 1
        printf '%s\n' 'legacy sfdisk usage'
    }
    ra_boot_mode() { printf '%s\n' bios; }
    ra_package_manager() { printf '%s\n' yum; }
    if output=$(ra_ensure_host_dependencies 2>&1); then
        return 1
    fi
    grep -q 'sfdisk with --json support' <<<"$output"
)
assert "legacy sfdisk without JSON support is rejected before preparation" \
    test_legacy_sfdisk_is_rejected

test_systemd_source_return_preflight() (
    local runtime="$TEST_ROOT/source-systemd"
    mkdir -p "$runtime"
    # shellcheck disable=SC2317,SC2329 # Production capability detection invokes this mock indirectly.
    systemctl() { :; }
    ARCH_REDEPLOY_INIT_KIND=systemd \
        ARCH_REDEPLOY_SYSTEMD_RUNTIME_DIR="$runtime" \
        ra_preflight_source_return_hook
)
assert "running systemd supports the source-return hook" \
    test_systemd_source_return_preflight

test_openrc_source_return_preflight() (
    local openrc_run="$TEST_ROOT/openrc-run"
    : >"$openrc_run"
    chmod 0755 "$openrc_run"
    # shellcheck disable=SC2317,SC2329 # Production capability detection invokes this mock indirectly.
    rc-update() { :; }
    ARCH_REDEPLOY_INIT_KIND=openrc \
        ARCH_REDEPLOY_OPENRC_RUN="$openrc_run" \
        ra_preflight_source_return_hook
)
assert "running OpenRC supports the source-return hook" \
    test_openrc_source_return_preflight

test_sysv_source_return_preflight_is_rejected() (
    local absent_systemd="$TEST_ROOT/no-systemd" absent_openrc="$TEST_ROOT/no-openrc-run"
    if (
        ARCH_REDEPLOY_INIT_KIND='' \
            ARCH_REDEPLOY_SYSTEMD_RUNTIME_DIR="$absent_systemd" \
            ARCH_REDEPLOY_OPENRC_RUN="$absent_openrc" \
            ra_preflight_source_return_hook
    ) >/dev/null 2>&1; then
        return 1
    fi
)
assert "SysV-style sources are rejected before preparation" \
    test_sysv_source_return_preflight_is_rejected

apk_dependencies=$(ra_print_host_dependency_command apk)
assert "Alpine dependency hint installs GNU coreutils" grep -qw coreutils <<<"$apk_dependencies"

test_admin_detection_defaults_without_sshd() (
    local fake_bin="$TEST_ROOT/no-sshd-bin" admin
    mkdir -p "$fake_bin"
    for utility in awk cut getent jq; do
        ln -s "$(command -v "$utility")" "$fake_bin/$utility"
    done
    admin=$(PATH="$fake_bin" SUDO_USER=root ra_detect_admin) || return 1
    [[ $(jq -r .port <<<"$admin") == 22 ]]
)
assert "admin detection defaults to port 22 without a source SSH server" \
    test_admin_detection_defaults_without_sshd

test_admin_detection_preserves_doas_user() (
    local expected_home="$TEST_ROOT/alpine-home" admin
    mkdir -p "$expected_home/.ssh"
    printf '%s\n' \
        'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMF8Li8YM0fcNEoktai0yKokrpzKWEIbgC7KY1cMvRAb alpine@test' \
        >"$expected_home/.ssh/authorized_keys"
    getent() {
        case "$1:$2" in
            passwd:alpine) printf 'alpine:x:1000:1000::%s:/bin/ash\n' "$expected_home" ;;
            shadow:alpine) printf '%s\n' 'alpine:!:1:0:99999:7:::' ;;
            *) return 2 ;;
        esac
    }
    admin=$(DOAS_USER=alpine SUDO_USER='' ra_detect_admin) || return 1
    jq -e '
      .user == "alpine" and
      .port == 22 and
      (.authorized_keys | startswith("ssh-ed25519 "))
    ' <<<"$admin" >/dev/null
)
assert "admin detection preserves the doas-invoking user" \
    test_admin_detection_preserves_doas_user

test_mixed_address_capture_is_order_independent() (
    local address_fixture dynamic_first static_first first second
    ra_default_route_json() {
        [[ $1 == 4 ]] || return 1
        printf '%s\n' '{"dev":"eth0","gateway":"192.0.2.1"}'
    }
    cat() {
        if [[ ${1:-} == /sys/class/net/eth0/address ]]; then
            printf '%s\n' '52:54:00:12:34:56'
        else
            command cat "$@"
        fi
    }
    ip() {
        case "$*" in
            '-d -j link show dev eth0')
                printf '%s\n' '[{"ifname":"eth0"}]'
                ;;
            '-j -4 address show dev eth0 scope global')
                printf '%s\n' "$address_fixture"
                ;;
            *)
                return 1
                ;;
        esac
    }
    dynamic_first='[{"addr_info":[
      {"scope":"global","local":"192.0.2.10","prefixlen":24,"dynamic":true},
      {"scope":"global","local":"192.0.2.99","prefixlen":32}
    ]}]'
    static_first='[{"addr_info":[
      {"scope":"global","local":"192.0.2.99","prefixlen":32},
      {"scope":"global","local":"192.0.2.10","prefixlen":24,"flags":["dynamic"]}
    ]}]'
    address_fixture=$dynamic_first
    first=$(ra_capture_network_family 4) || return 1
    address_fixture=$static_first
    second=$(ra_capture_network_family 4) || return 1
    [[ $(jq -cS . <<<"$first") == "$(jq -cS . <<<"$second")" ]] || return 1
    jq -e '
      .mode == "dhcp" and
      .address == "" and
      .extra_addresses == ["192.0.2.99/32"] and
      .interface == "eth0" and
      .mac == "52:54:00:12:34:56" and
      .gateway == "192.0.2.1"
    ' <<<"$first" >/dev/null
)
assert "mixed DHCP and static addresses are classified independently of order" \
    test_mixed_address_capture_is_order_independent

test_unusable_ipv6_does_not_block_usable_ipv4() (
    local network
    ra_capture_dns() { printf '%s\n' '["10.0.2.3"]'; }
    ra_default_route_json() {
        if [[ $1 == 4 ]]; then
            printf '%s\n' '{"dev":"eth0","gateway":"10.0.2.2"}'
        else
            printf '%s\n' '{"dev":"eth0","gateway":"fec0::2"}'
        fi
    }
    cat() {
        if [[ ${1:-} == /sys/class/net/eth0/address ]]; then
            printf '%s\n' '52:54:00:12:34:56'
        else
            command cat "$@"
        fi
    }
    ip() {
        case "$*" in
            '-d -j link show dev eth0')
                printf '%s\n' '[{"ifname":"eth0"}]'
                ;;
            '-j -4 address show dev eth0 scope global')
                printf '%s\n' '[{"addr_info":[{
                  "scope":"global","local":"10.0.2.15","prefixlen":24,"dynamic":true
                }]}]'
                ;;
            '-j -6 address show dev eth0 scope global')
                printf '%s\n' '[{"addr_info":[{
                  "scope":"site","local":"fec0::5054:ff:fe12:3456","prefixlen":64
                }]}]'
                ;;
            *)
                return 1
                ;;
        esac
    }
    network=$(ra_capture_network) || return 1
    jq -e '
      .ipv4.mode == "dhcp" and
      .ipv4.interface == "eth0" and
      .ipv6 == {mode:"none"} and
      .dns == ["10.0.2.3"]
    ' <<<"$network" >/dev/null
)
assert "an unusable IPv6 route does not block usable IPv4" \
    test_unusable_ipv6_does_not_block_usable_ipv4

test_target_disk_selection_keeps_stdout_machine_readable() (
    local display="$TEST_ROOT/target-disk-display" selected
    ra_root_disks() { printf '%s\n' /dev/vda; }
    ra_list_disks() {
        printf '%s\n' \
            '{"path":"/dev/vda","size":21474836480,"model":"QEMU","serial":"RA-TEST","ro":false}'
    }
    ra_prompt_default() { printf '%s' /dev/vda; }
    ra_is_block_device() { return 0; }
    lsblk() { printf '%s\n' disk; }
    selected=$(ra_select_target_disk 2>"$display") || return 1
    [[ $selected == /dev/vda ]] &&
        grep -Fq '/dev/vda  21474836480 bytes  QEMU  serial=RA-TEST' "$display"
)
assert "target selection returns only the disk path while displaying details" \
    test_target_disk_selection_keeps_stdout_machine_readable

test_installer_disk_lookup_failure_reaches_parent_err_trap() (
    local library="$TEST_ROOT/installer-functions.sh"
    local trap_log="$TEST_ROOT/installer-trap.log"
    local expected_pid_log="$TEST_ROOT/installer-expected-pid.log"
    local order_log="$TEST_ROOT/installer-preflight-order.log"
    sed \
        -e '/^source /d' \
        -e '/^exec > /d' \
        -e '/^trap .* ERR$/d' \
        -e '/^main "\$@"$/d' \
        "$PROJECT_ROOT/installer/install.sh" >"$library"
    # shellcheck disable=SC2016 # The child shell must expand its own BASHPID.
    bash -c '
      source "$1"
      set_installer_stage() { :; }
      validate_config() { :; }
      configure_live_network() { printf "network\n" >>"$order_log"; }
      start_installer_ssh() { printf "ssh\n" >>"$order_log"; }
      find_target_disk() { printf "disk\n" >>"$order_log"; return 1; }
      trap_log=$2
      expected_pid_log=$3
      order_log=$4
      record_failure() { printf "%s\n" "$BASHPID" >>"$trap_log"; }
      printf "%s\n" "$BASHPID" >"$expected_pid_log"
      trap record_failure ERR
      main
    ' _ "$library" "$trap_log" "$expected_pid_log" "$order_log" >/dev/null 2>&1 || true
    [[ -s $trap_log && -s $expected_pid_log ]] || return 1
    [[ $(wc -l <"$trap_log") -eq 1 ]] || return 1
    [[ $(cat "$trap_log") == "$(cat "$expected_pid_log")" ]] &&
        [[ $(tr '\n' ' ' <"$order_log") == "network ssh disk " ]]
)
assert "disk lookup failures remain remotely inspectable and reach the parent ERR trap" \
    test_installer_disk_lookup_failure_reaches_parent_err_trap

test_download_retries_all_errors() (
    local attempts=0 curl_destination=
    curl() {
        while (($#)); do
            case $1 in
                --output) curl_destination=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        ((attempts += 1))
        ((attempts > 1)) || return 22
        printf 'verified\n' >"$curl_destination"
    }
    sleep() { :; }
    RA_DOWNLOAD_RETRY_DELAY_SECONDS=0 ra_download \
        https://downloads.example/artifact "$TEST_ROOT/retried-download" || return 1
    [[ $attempts == 2 && $(cat "$TEST_ROOT/retried-download") == verified ]]
)
assert "host downloads retry HTTP errors without new curl-only flags" \
    test_download_retries_all_errors

test_builder_chroot_preserves_network_environment_exactly() (
    local log="$TEST_ROOT/builder-chroot-environment.log" variable
    local -a actual expected
    for variable in \
        HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
        http_proxy https_proxy all_proxy no_proxy \
        SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE REQUESTS_CA_BUNDLE; do
        unset "$variable"
    done
    export HTTP_PROXY='http://proxy.example:8080/path with spaces?token=a=b'
    export HTTPS_PROXY=
    export ALL_PROXY='socks5h://proxy.example:1080'
    export NO_PROXY='localhost,127.0.0.1,.upper.example.test'
    export http_proxy='http://lower-proxy.example:8081'
    export https_proxy='https://lower-proxy.example:8443'
    export all_proxy='socks5://lower-proxy.example:1081'
    export no_proxy='localhost,127.0.0.1,.example.test'
    export SSL_CERT_FILE='/run/reinstall arch/ca.pem'
    export SSL_CERT_DIR='/run/arch-redeploy/certificates'
    export CURL_CA_BUNDLE='/run/arch-redeploy/ca=bundle.pem'
    export REQUESTS_CA_BUNDLE='/run/arch-redeploy/requests-ca.pem'
    chroot() {
        printf '%s\0' "$@" >"$log"
    }

    ra_builder_chroot /builder-root command-name 'argument with spaces' 'key=value'
    mapfile -d '' -t actual <"$log"
    expected=(
        /builder-root
        /usr/bin/env
        -i
        HOME=/root
        TERM=dumb
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        LC_ALL=C
        'HTTP_PROXY=http://proxy.example:8080/path with spaces?token=a=b'
        HTTPS_PROXY=
        'ALL_PROXY=socks5h://proxy.example:1080'
        'NO_PROXY=localhost,127.0.0.1,.upper.example.test'
        'http_proxy=http://lower-proxy.example:8081'
        'https_proxy=https://lower-proxy.example:8443'
        'all_proxy=socks5://lower-proxy.example:1081'
        'no_proxy=localhost,127.0.0.1,.example.test'
        'SSL_CERT_FILE=/run/reinstall arch/ca.pem'
        'SSL_CERT_DIR=/run/arch-redeploy/certificates'
        'CURL_CA_BUNDLE=/run/arch-redeploy/ca=bundle.pem'
        'REQUESTS_CA_BUNDLE=/run/arch-redeploy/requests-ca.pem'
        command-name
        'argument with spaces'
        'key=value'
    )
    ((${#actual[@]} == ${#expected[@]})) || return 1
    for variable in "${!expected[@]}"; do
        [[ ${actual[$variable]} == "${expected[$variable]}" ]] || return 1
    done
)
assert "builder chroot preserves defined proxy and CA variables exactly" \
    test_builder_chroot_preserves_network_environment_exactly

test_builder_chroot_does_not_leak_unrelated_environment() (
    local log="$TEST_ROOT/builder-chroot-isolation.log" variable
    for variable in \
        HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
        http_proxy https_proxy all_proxy no_proxy \
        SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE REQUESTS_CA_BUNDLE; do
        unset "$variable"
    done
    export ARCH_REDEPLOY_PROXY_SECRET='must-not-cross-env-i'
    export PACMAN_AUTH_TOKEN='must-not-cross-env-i-either'
    chroot() {
        printf '%s\n' "$@" >"$log"
    }

    ra_builder_chroot /builder-root /usr/bin/true
    ! grep -Eq 'must-not-cross|^(ARCH_REDEPLOY_PROXY_SECRET|PACMAN_AUTH_TOKEN)=' "$log"
)
assert "builder chroot does not leak unrelated host environment" \
    test_builder_chroot_does_not_leak_unrelated_environment

test_builder_default_trust_includes_explicit_ca() (
    local root="$TEST_ROOT/builder-ca" custom="$TEST_ROOT/proxy-ca.pem"
    local requests_ca="$TEST_ROOT/requests-ca.pem" log="$TEST_ROOT/builder-ca-chroot.log"
    mkdir -p "$root/etc/ssl/certs"
    printf '%s\n' \
        '-----BEGIN CERTIFICATE-----' \
        'U1lTVEVNLVJPT1Q=' \
        '-----END CERTIFICATE-----' \
        >"$root/etc/ssl/certs/ca-certificates.crt"
    printf '%s\n' \
        '-----BEGIN CERTIFICATE-----' \
        'UFJPWFktQ0E=' \
        '-----END CERTIFICATE-----' \
        >"$custom"
    printf '%s\n' \
        '-----BEGIN CERTIFICATE-----' \
        'UkVRVUVTVFMtQ0E=' \
        '-----END CERTIFICATE-----' \
        >"$requests_ca"
    chroot() { printf '%s\n' "$@" >"$log"; }
    SSL_CERT_FILE="$custom" CURL_CA_BUNDLE="$custom" REQUESTS_CA_BUNDLE="$requests_ca" \
        ra_extend_builder_ca_trust "$root" || return 1
    SSL_CERT_FILE="$custom" CURL_CA_BUNDLE="$custom" REQUESTS_CA_BUNDLE="$requests_ca" \
        ra_builder_chroot "$root" /usr/bin/true || return 1
    grep -Fq 'U1lTVEVNLVJPT1Q=' "$root/etc/ssl/certs/ca-certificates.crt" &&
        grep -Fq 'UFJPWFktQ0E=' "$root/etc/ssl/certs/ca-certificates.crt" &&
        grep -Fq 'UkVRVUVTVFMtQ0E=' "$root/etc/ssl/certs/ca-certificates.crt" &&
        grep -Fxq 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' "$log" &&
        grep -Fxq 'CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt' "$log" &&
        grep -Fxq 'REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt' "$log"
)
assert "builder default trust includes the explicit proxy CA for libalpm" \
    test_builder_default_trust_includes_explicit_ca

test_builder_default_trust_includes_explicit_ca_directory() (
    local root="$TEST_ROOT/builder-ca-directory"
    local custom_dir="$TEST_ROOT/custom-ca-directory"
    local log="$TEST_ROOT/builder-ca-directory-chroot.log"
    mkdir -p "$root/etc/ssl/certs" "$custom_dir"
    printf '%s\n' \
        '-----BEGIN CERTIFICATE-----' \
        'U1lTVEVNLVJPT1Q=' \
        '-----END CERTIFICATE-----' \
        >"$root/etc/ssl/certs/ca-certificates.crt"
    printf '%s\n' \
        '-----BEGIN CERTIFICATE-----' \
        'RElSRUNUT1JZLUNB' \
        '-----END CERTIFICATE-----' \
        >"$custom_dir/proxy.pem"
    ln -s proxy.pem "$custom_dir/0123abcd.0"
    chroot() { printf '%s\n' "$@" >"$log"; }
    RA_BUILDER_DEFAULT_CA_READY=0
    SSL_CERT_FILE='' CURL_CA_BUNDLE='' REQUESTS_CA_BUNDLE='' SSL_CERT_DIR="$custom_dir" \
        ra_extend_builder_ca_trust "$root" || return 1
    SSL_CERT_FILE='' CURL_CA_BUNDLE='' REQUESTS_CA_BUNDLE='' SSL_CERT_DIR="$custom_dir" \
        ra_builder_chroot "$root" /usr/bin/true || return 1
    ! grep -Fq 'RElSRUNUT1JZLUNB' "$root/etc/ssl/certs/ca-certificates.crt" &&
        grep -Fq 'RElSRUNUT1JZLUNB' "$root/etc/arch-redeploy-host-ca.d/0/0123abcd.0" &&
        grep -Fxq 'SSL_CERT_DIR=/etc/arch-redeploy-host-ca.d/0' "$log"
)
assert "builder preserves explicit CA-directory lookup semantics inside the chroot" \
    test_builder_default_trust_includes_explicit_ca_directory

test_online_fallback_rejects_proxy_environment() (
    local variable
    for variable in \
        HTTP_PROXY HTTPS_PROXY ALL_PROXY \
        http_proxy https_proxy all_proxy \
        SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE REQUESTS_CA_BUNDLE; do
        unset "$variable"
    done
    ra_online_fallback_environment_safe || return 1
    HTTP_PROXY=http://proxy.example:8080
    if ra_online_fallback_environment_safe; then return 1; fi
    unset HTTP_PROXY
    SSL_CERT_DIR=/etc/ssl/custom
    ! ra_online_fallback_environment_safe
)
assert "online-after-wipe fallback rejects proxy or custom-CA environments" \
    test_online_fallback_rejects_proxy_environment

test_verified_artifact_commit_is_idempotent() (
    local artifacts="$RA_STATE_DIR/artifacts" kernel_sha initramfs_sha
    mkdir -p "$artifacts"
    printf 'kernel\n' >"$artifacts/vmlinuz"
    printf 'initramfs\n' >"$artifacts/initramfs.img"
    kernel_sha=$(ra_sha256 "$artifacts/vmlinuz")
    initramfs_sha=$(ra_sha256 "$artifacts/initramfs.img")
    printf '%s\n' '{"state":"preparing","install_id":"artifact-test"}' >"$RA_STATE_FILE"
    jq -n --arg install_id artifact-test --arg kernel_sha "$kernel_sha" \
        --argjson kernel_bytes "$(ra_bytes "$artifacts/vmlinuz")" \
        --arg initramfs_sha "$initramfs_sha" \
        --argjson initramfs_bytes "$(ra_bytes "$artifacts/initramfs.img")" '{
          install_id:$install_id,
          kernel_sha256:$kernel_sha,
          kernel_bytes:$kernel_bytes,
          initramfs_sha256:$initramfs_sha,
          initramfs_bytes:$initramfs_bytes,
          prepared_at:"now"
        }' >"$artifacts/complete.json"
    ra_finalize_prepared_artifacts || return 1
    ra_finalize_prepared_artifacts || return 1
    [[ $(jq -r .state "$RA_STATE_FILE") == prepared ]]
)
assert "verified preparation artifact commit is idempotent" \
    test_verified_artifact_commit_is_idempotent

test_offline_artifact_commit_tracks_external_payload() (
    local artifacts="$RA_STATE_DIR/artifacts" kernel_sha initramfs_sha rootfs_sha
    mkdir -p "$artifacts"
    printf 'kernel\n' >"$artifacts/vmlinuz"
    printf 'initramfs\n' >"$artifacts/initramfs.img"
    printf 'offline-root\n' >"$artifacts/rootfs.tar.zst"
    kernel_sha=$(ra_sha256 "$artifacts/vmlinuz")
    initramfs_sha=$(ra_sha256 "$artifacts/initramfs.img")
    rootfs_sha=$(ra_sha256 "$artifacts/rootfs.tar.zst")
    jq -n --arg rootfs_sha "$rootfs_sha" '{
      state:"preparing",
      install_id:"offline-artifact-test",
      payload:{mode:"offline", rootfs_sha256:$rootfs_sha}
    }' >"$RA_STATE_FILE"
    jq -n --arg kernel_sha "$kernel_sha" --arg initramfs_sha "$initramfs_sha" \
        --arg rootfs_sha "$rootfs_sha" \
        --argjson kernel_bytes "$(ra_bytes "$artifacts/vmlinuz")" \
        --argjson initramfs_bytes "$(ra_bytes "$artifacts/initramfs.img")" \
        --argjson rootfs_bytes "$(ra_bytes "$artifacts/rootfs.tar.zst")" '{
          install_id:"offline-artifact-test",
          kernel_sha256:$kernel_sha,
          kernel_bytes:$kernel_bytes,
          initramfs_sha256:$initramfs_sha,
          initramfs_bytes:$initramfs_bytes,
          rootfs_sha256:$rootfs_sha,
          rootfs_bytes:$rootfs_bytes,
          prepared_at:"now"
        }' >"$artifacts/complete.json"
    ra_finalize_prepared_artifacts || return 1
    ra_finalize_prepared_artifacts || return 1
    [[ $(jq -r .artifacts.rootfs "$RA_STATE_FILE") == artifacts/rootfs.tar.zst ]] &&
        [[ $(jq -r .artifacts.rootfs_sha256 "$RA_STATE_FILE") == "$rootfs_sha" ]]
)
assert "offline preparation commit tracks the separately staged payload" \
    test_offline_artifact_commit_tracks_external_payload

test_boot_artifact_staging_is_owned_and_idempotent() (
    local install_id=01234567-89ab-cdef-0123-456789abcdef
    local artifacts="$RA_STATE_DIR/artifacts" pending="${RA_BOOT_DIR}.pending-$install_id"
    rm -rf -- "$RA_BOOT_DIR" "$pending"
    mkdir -p "$artifacts"
    printf 'kernel\n' >"$artifacts/vmlinuz"
    printf 'initramfs\n' >"$artifacts/initramfs.img"
    printf 'offline-root\n' >"$artifacts/rootfs.tar.zst"
    jq -n --arg install_id "$install_id" '{
      install_id:$install_id,
      payload:{mode:"offline"},
      artifacts:{
        kernel:"artifacts/vmlinuz",
        initramfs:"artifacts/initramfs.img",
        rootfs:"artifacts/rootfs.tar.zst"
      }
    }' >"$RA_STATE_FILE"
    ra_verify_boot_capacity() { return 0; }
    ra_stage_boot_files || return 1
    ra_stage_boot_files || return 1
    [[ $(cat "$RA_BOOT_DIR/install-id") == "$install_id" ]] || return 1
    cmp "$artifacts/rootfs.tar.zst" "$RA_BOOT_DIR/rootfs.tar.zst" || return 1
    mkdir -p "$pending"
    ra_remove_owned_boot_dir || return 1
    [[ ! -e $RA_BOOT_DIR && ! -e $pending ]]
)
assert "boot artifact staging and cleanup are install-ID-owned and idempotent" \
    test_boot_artifact_staging_is_owned_and_idempotent

test_offline_payload_kernel_arguments() (
    local args
    mkdir -p "$RA_BOOT_DIR"
    printf 'payload\n' >"$RA_BOOT_DIR/rootfs.tar.zst"
    printf '%s\n' '{"payload":{"mode":"offline"}}' >"$RA_STATE_FILE"
    findmnt() {
        case $* in
            *'-o TARGET') printf '%s\n' / ;;
            *'-o FSROOT') printf '%s\n' /@ ;;
            *'-o UUID') printf '%s\n' 11111111-2222-3333-4444-555555555555 ;;
            *'-o FSTYPE') printf '%s\n' btrfs ;;
            *) return 1 ;;
        esac
    }
    args=$(ra_payload_kernel_args) || return 1
    [[ $args == *'arch_redeploy_payload_uuid=11111111-2222-3333-4444-555555555555'* ]] &&
        [[ $args == *'arch_redeploy_payload_fstype=btrfs'* ]] &&
        [[ $args == *"arch_redeploy_payload_path=/@$RA_BOOT_DIR/rootfs.tar.zst"* ]] || return 1
    rm -rf -- "$RA_BOOT_DIR"
)
assert "offline payload location is passed to recovery without entering initramfs" \
    test_offline_payload_kernel_arguments

stale_build="$RA_STATE_DIR/tmp/build.interrupted"
mkdir -p "$stale_build/alpine"
printf 'partial\n' >"$stale_build/alpine/artifact"
ra_cleanup_stale_builds
assert "interrupted build workspaces are reclaimed before retry" test ! -e "$stale_build"

test_build_cleanup_survives_function_scope() {
    local work="$RA_STATE_DIR/tmp/build.cleanup-scope" output status
    mkdir -p "$work/alpine"
    set +e
    output=$(
        (
            arm_cleanup_from_local_scope() {
                local scoped_work=$work
                ra_arm_build_cleanup "$scoped_work" "$scoped_work/alpine"
            }
            arm_cleanup_from_local_scope
            exit 17
        ) 2>&1
    )
    status=$?
    set -e
    [[ $status == 17 ]] &&
        [[ ! -e $work ]] &&
        [[ $output != *"unbound variable"* ]]
}
assert "build cleanup remains safe after function-local variables expire" \
    test_build_cleanup_survives_function_scope

disk_expected='{"size":1000,"serial":"SERIAL","wwn":"WWN","partition_id":"id","partition_hash":"hash"}'
disk_same='{"size":1000,"serial":"SERIAL","wwn":"WWN","partition_id":"id","partition_hash":"hash"}'
disk_drift='{"size":1000,"serial":"SERIAL","wwn":"WWN","partition_id":"id","partition_hash":"changed"}'
assert "matching disk identity passes" ra_disk_identity_matches "$disk_expected" "$disk_same"
# shellcheck disable=SC2016 # positional parameters are expanded by the child shell.
assert "partition-table drift is rejected" bash -c \
    'source "$1/lib/detect.sh"; ! ra_disk_identity_matches "$2" "$3"' \
    _ "$PROJECT_ROOT" "$disk_expected" "$disk_drift"

test_partition_hash_ignores_device_path() (
    local selected=/dev/vda partition_number=1 first second changed
    sfdisk() {
        [[ $1 == --json && $2 == "$selected" ]] || return 1
        jq -n --arg device "$selected" --argjson number "$partition_number" '{
          partitiontable: {
            label:"gpt",
            id:"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            device:$device,
            unit:"sectors",
            sectorsize:512,
            partitions:[{
              node:($device + ($number | tostring)),
              start:2048,
              size:4096,
              type:"0FC63DAF-8483-4772-8E79-3D69D8477DE4",
              uuid:"11111111-2222-3333-4444-555555555555",
              name:"root"
            }]
          }
        }'
    }
    first=$(ra_partition_table_hash "$selected") || return 1
    selected=/dev/sda
    second=$(ra_partition_table_hash "$selected") || return 1
    [[ $first == "$second" ]] || return 1
    partition_number=2
    changed=$(ra_partition_table_hash "$selected") || return 1
    [[ $first != "$changed" ]]
)
assert "partition-table identity survives a device-path rename" \
    test_partition_hash_ignores_device_path

test_unreadable_partition_table_fails_closed() (
    lsblk() {
        printf '%s\n' '{"blockdevices":[{"path":"/dev/vda","size":1000}]}'
    }
    # shellcheck disable=SC2317,SC2329 # Deliberate failure path for the subshell test.
    sfdisk() { return 1; }
    ! ra_disk_identity /dev/vda >/dev/null
)
assert "unreadable partition tables fail disk capture closed" \
    test_unreadable_partition_table_fails_closed

test_disk_serial_falls_back_to_sysfs() (
    local fake_dev_root="$TEST_ROOT/fake-dev"
    local fake_dev="$fake_dev_root/vda"
    local fake_alias="$fake_dev_root/disk/by-id/virtio-test"
    local fake_sys="$TEST_ROOT/fake-sys-class-block"
    mkdir -p "$(dirname "$fake_alias")" "$fake_sys/vda"
    : >"$fake_dev"
    ln -s ../../vda "$fake_alias"
    printf '  RA-UBU-BIOS  \n' >"$fake_sys/vda/serial"
    lsblk() {
        [[ $* == *SERIAL* ]] || return 1
        printf '%s\n' DIFFERENT-USERSPACE-VALUE
    }
    [[ $(ARCH_REDEPLOY_SYS_CLASS_BLOCK_ROOT="$fake_sys" \
        ra_disk_serial "$fake_alias") == RA-UBU-BIOS ]]
)
assert "disk serial prefers the normalized kernel view across device aliases" \
    test_disk_serial_falls_back_to_sysfs

test_disk_serial_uses_device_sysfs_fallback() (
    local fake_dev="$TEST_ROOT/device-serial-dev/vdb"
    local fake_sys="$TEST_ROOT/device-serial-sys"
    mkdir -p "$(dirname "$fake_dev")" "$fake_sys/vdb/device"
    : >"$fake_dev"
    printf 'DEVICE-SERIAL\n' >"$fake_sys/vdb/device/serial"
    lsblk() { printf '\n'; }
    [[ $(ARCH_REDEPLOY_SYS_CLASS_BLOCK_ROOT="$fake_sys" \
        ra_disk_serial "$fake_dev") == DEVICE-SERIAL ]]
)
assert "disk serial supports the device sysfs fallback path" \
    test_disk_serial_uses_device_sysfs_fallback

test_source_disk_identity_uses_shared_serial() (
    local fake_dev="$TEST_ROOT/identity-dev/vda" identity
    mkdir -p "$(dirname "$fake_dev")"
    : >"$fake_dev"
    lsblk() {
        printf '%s\n' '{"blockdevices":[{
          "name":"vda","path":"/dev/vda","size":21474836480,
          "serial":null,"wwn":null,"ro":false,"rm":false,
          "log-sec":512,"phy-sec":512,"type":"disk"
        }]}'
    }
    ra_disk_serial() { printf '%s' RA-UBU-BIOS; }
    ra_partition_table_id() { printf '%s' table-id; }
    ra_partition_table_hash() { printf '%064d' 0; }
    identity=$(ra_disk_identity "$fake_dev") || return 1
    [[ $(jq -r .serial <<<"$identity") == RA-UBU-BIOS ]]
)
assert "source disk identity uses the shared normalized serial" \
    test_source_disk_identity_uses_shared_serial

test_recovery_disk_matcher_uses_shared_serial() (
    local library="$TEST_ROOT/recovery-disk-functions.sh"
    local config="$TEST_ROOT/recovery-disk-config.json"
    sed \
        -e '/^source /d' \
        -e '/^exec > /d' \
        -e '/^trap .* ERR$/d' \
        -e '/^main "\$@"$/d' \
        -e "s|^readonly CONFIG=.*|readonly CONFIG='$config'|" \
        "$PROJECT_ROOT/installer/install.sh" >"$library"
    printf '%s\n' '{"disk":{
      "size":21474836480,
      "serial":"RA-UBU-BIOS",
      "wwn":null,
      "log-sec":512,
      "phy-sec":512
    }}' >"$config"
    # shellcheck disable=SC1090 # Generated from the production installer for this fixture.
    source "$library"
    # shellcheck disable=SC2317,SC2329 # Production invokes this fixture through disk_matches_manifest.
    disk_is_writable_whole() { :; }
    # shellcheck disable=SC2317,SC2329 # Production invokes this fixture through disk_matches_manifest.
    ra_disk_serial() { printf '%s' RA-UBU-BIOS; }
    # shellcheck disable=SC2317,SC2329 # Production invokes this fixture through disk_matches_manifest.
    lsblk() {
        case $* in
            '-bdnro SIZE /dev/vda') printf '%s\n' 21474836480 ;;
            '-dnro WWN /dev/vda') printf '\n' ;;
            '-bdnro LOG-SEC /dev/vda') printf '%s\n' 512 ;;
            '-bdnro PHY-SEC /dev/vda') printf '%s\n' 512 ;;
            *) return 1 ;;
        esac
    }
    disk_matches_manifest /dev/vda
)
assert "recovery disk matching uses the shared normalized serial" \
    test_recovery_disk_matcher_uses_shared_serial

test_recovery_no_cancel_path_succeeds() (
    local library="$TEST_ROOT/recovery-cancellation-functions.sh"
    local cancel_request="$TEST_ROOT/recovery-cancellation-request"
    sed \
        -e '/^source /d' \
        -e '/^exec > /d' \
        -e '/^trap .* ERR$/d' \
        -e '/^main "\$@"$/d' \
        -e "s|^readonly CANCEL_REQUEST=.*|readonly CANCEL_REQUEST='$cancel_request'|" \
        "$PROJECT_ROOT/installer/install.sh" >"$library"
    # shellcheck disable=SC1090 # Generated from the production installer for this fixture.
    source "$library"
    rm -f "$cancel_request"
    honor_cancellation
)
assert "normal recovery continues when no cancellation was requested" \
    test_recovery_no_cancel_path_succeeds

test_recovery_find_target_disk_uses_unique_sysfs_serial() (
    local library="$TEST_ROOT/recovery-find-disk-functions.sh"
    local config="$TEST_ROOT/recovery-find-disk-config.json"
    local fake_sys="$TEST_ROOT/recovery-find-disk-sys" candidates result
    sed \
        -e '/^source /d' \
        -e '/^exec > /d' \
        -e '/^trap .* ERR$/d' \
        -e '/^main "\$@"$/d' \
        -e "s|^readonly CONFIG=.*|readonly CONFIG='$config'|" \
        "$PROJECT_ROOT/installer/install.sh" >"$library"
    printf '%s\n' '{"disk":{
      "path":"/dev/vda",
      "size":21474836480,
      "serial":"RA-UBU-BIOS",
      "wwn":null,
      "log-sec":512,
      "phy-sec":512
    }}' >"$config"
    mkdir -p "$fake_sys/vdb" "$fake_sys/vdc"
    printf 'RA-UBU-BIOS\n' >"$fake_sys/vdb/serial"
    printf 'RA-UBU-BIOS\n' >"$fake_sys/vdc/serial"
    # shellcheck disable=SC1090 # Generated from the production installer for this fixture.
    source "$library"
    # shellcheck disable=SC2317,SC2329 # Production invokes this fixture through disk matching.
    disk_is_writable_whole() { :; }
    # shellcheck disable=SC2317,SC2329 # Production invokes this fixture through target discovery.
    lsblk() {
        case $* in
            '-dpnro NAME,TYPE') printf '%s\n' "$candidates" ;;
            '-bdnro SIZE /dev/vdb'|'-bdnro SIZE /dev/vdc') printf '%s\n' 21474836480 ;;
            '-dnro WWN /dev/vdb'|'-dnro WWN /dev/vdc') printf '\n' ;;
            '-bdnro LOG-SEC /dev/vdb'|'-bdnro LOG-SEC /dev/vdc') printf '%s\n' 512 ;;
            '-bdnro PHY-SEC /dev/vdb'|'-bdnro PHY-SEC /dev/vdc') printf '%s\n' 512 ;;
            '-dnro SERIAL /dev/vdb'|'-dnro SERIAL /dev/vdc') printf '\n' ;;
            *) return 1 ;;
        esac
    }

    candidates='/dev/vdb disk'
    result=$(ARCH_REDEPLOY_SYS_CLASS_BLOCK_ROOT="$fake_sys" find_target_disk) || return 1
    [[ $result == /dev/vdb ]] || return 1

    candidates=$'/dev/vdb disk\n/dev/vdc disk'
    if ARCH_REDEPLOY_SYS_CLASS_BLOCK_ROOT="$fake_sys" find_target_disk >/dev/null; then
        return 1
    fi

    printf 'WRONG-SERIAL\n' >"$fake_sys/vdb/serial"
    candidates='/dev/vdb disk'
    ! ARCH_REDEPLOY_SYS_CLASS_BLOCK_ROOT="$fake_sys" find_target_disk >/dev/null
)
assert "recovery finds exactly one renamed disk by its kernel serial" \
    test_recovery_find_target_disk_uses_unique_sysfs_serial

mirror_file="$TEST_ROOT/mirrorlist"
ra_write_pacman_mirrorlist '["https://one.example/arch","https://two.example/arch"]' "$mirror_file"
# shellcheck disable=SC2016 # pacman expands $repo and $arch at runtime.
assert_eq "pacman variables remain literal" \
    'Server = https://one.example/arch/$repo/os/$arch' "$(head -n1 "$mirror_file")"
assert_eq "multiple mirrors are retained" "2" "$(wc -l <"$mirror_file" | tr -d ' ')"

test_mirror_probe_tolerates_proxy_handshake() (
    local arguments="$TEST_ROOT/mirror-probe-arguments"
    curl() {
        printf '%s\n' "$@" >"$arguments"
        printf '%s\t%s' 0.5 206
    }
    [[ $(ra_probe_url https://mirror.example/core.db) == 0.5 ]] || return 1
    grep -Fxq 10 "$arguments" &&
        grep -Fxq 30 "$arguments"
)
assert "mirror probes allow a proxied TLS handshake" \
    test_mirror_probe_tolerates_proxy_handshake

test_alpine_mirror_requires_archive() (
    # shellcheck disable=SC2317,SC2329 # Production invokes this fixture through the mirror helper.
    ra_probe_url() {
        case $1 in
            *.tar.gz.sha256|*.tar.gz.asc) printf '%s' 0.1 ;;
            *.tar.gz) return 1 ;;
            *) return 1 ;;
        esac
    }
    ! ra_validate_mirror_base alpine https://alpine.example
)
assert "Alpine mirror validation rejects checksum-only availability" \
    test_alpine_mirror_requires_archive

test_mirror_validation_retries_transient_failure() (
    local attempts=0
    # shellcheck disable=SC2317,SC2329 # Production invokes these fixtures through validation.
    ra_probe_required_mirror_content() {
        ((attempts += 1))
        ((attempts >= 2))
    }
    # shellcheck disable=SC2317,SC2329 # Avoid a real backoff in the transient fixture.
    sleep() { :; }
    ra_validate_mirror_base arch https://arch.example &&
        ((attempts == 2))
)
assert "selected mirror validation retries a transient failure" \
    test_mirror_validation_retries_transient_failure

test_mirror_selection_keeps_stdout_machine_readable() (
    local display="$TEST_ROOT/mirror-selection-display" selected
    # shellcheck disable=SC2317,SC2329 # Production calls this fixture through the selection helper.
    ra_probe_mirror_set() {
        if [[ $1 == alpine ]]; then
            printf '%s\t%s\t%s\n' 0.1 global https://alpine.example
        else
            printf '%s\t%s\t%s\n' 0.2 global https://arch-one.example
            printf '%s\t%s\t%s\n' 0.3 china https://arch-two.example
        fi
    }
    # shellcheck disable=SC2317,SC2329 # Select the ranked defaults without another prompt.
    ra_confirm() { return 0; }
    selected=$(ra_choose_mirrors 2>"$display") || return 1
    jq -e '
      .alpine == "https://alpine.example" and
      .arch == ["https://arch-one.example", "https://arch-two.example"]
    ' <<<"$selected" >/dev/null &&
        grep -Fq 'https://alpine.example' "$display" &&
        grep -Fq 'https://arch-two.example' "$display"
)
assert "mirror selection returns only JSON while displaying rankings" \
    test_mirror_selection_keeps_stdout_machine_readable

test_locked_transaction_preflight() (
    local lock="$TEST_ROOT/packages.lock" probes=0
    printf '%s\t%s\t%s\n' coreutils 9.7-1 core/os/x86_64/coreutils-9.7-1-x86_64.pkg.tar.zst >"$lock"
    ra_probe_url() { ((probes += 1)); return 0; }
    ra_preflight_locked_transaction "$lock" '["https://one.example","https://two.example"]' || return 1
    ((probes == 4))
)
assert "locked online transaction checks package and signature on two mirrors" \
    test_locked_transaction_preflight

test_locked_transaction_rejects_one_mirror() (
    local lock="$TEST_ROOT/packages-one-mirror.lock"
    printf '%s\t%s\t%s\n' coreutils 9.7-1 core/os/x86_64/coreutils-9.7-1-x86_64.pkg.tar.zst >"$lock"
    ra_probe_url() { [[ $1 == https://one.example/* ]]; }
    ! ra_preflight_locked_transaction "$lock" '["https://one.example","https://two.example"]' 2>/dev/null
)
assert "locked online transaction rejects single-mirror availability" \
    test_locked_transaction_rejects_one_mirror

test_uefi_helper_defined() { declare -F ra_efi_bootnums_by_label >/dev/null; }
assert "UEFI boot helper is defined as shell code" test_uefi_helper_defined

test_grub_command_uses_only_grub_names() (
    local mock_bin="$TEST_ROOT/grub-command-bin"
    mkdir -p "$mock_bin"
    : >"$mock_bin/reboot"
    : >"$mock_bin/grub-reboot"
    chmod 0755 "$mock_bin/reboot" "$mock_bin/grub-reboot"
    [[ $(PATH="$mock_bin" ra_grub_command reboot) == "$mock_bin/grub-reboot" ]]
)
assert "GRUB command lookup never selects the system reboot command" \
    test_grub_command_uses_only_grub_names

test_uefi_loader_measurement_includes_margin() (
    local required
    # shellcheck disable=SC2317,SC2329 # Production calls this fixture as the standalone command.
    mock_standalone() {
        local output=
        while (($#)); do
            if [[ $1 == -o ]]; then
                output=$2
                break
            fi
            shift
        done
        [[ -n $output ]] || return 1
        truncate -s $((2 * 1024 * 1024)) "$output"
    }
    required=$(ra_uefi_loader_required_bytes mock_standalone) || return 1
    [[ $required == $((3 * 1024 * 1024)) ]]
)
assert "UEFI capacity preflight includes loader size and safety margin" \
    test_uefi_loader_measurement_includes_margin

printf '%s\n' '{"install_id":"01234567-89ab-cdef-0123-456789abcdef"}' >"$RA_STATE_FILE"
assert_eq "source UEFI label is scoped to the install ID" \
    "arch-redeploy-01234567" "$(ra_source_efi_label)"

test_grub_entry_output() (
    local generated="$TEST_ROOT/generated-grub.cfg" expected
    findmnt() { printf '%s\n' 'test-fs-uuid'; }
    ra_grub_path() {
        case $1 in
            */vmlinuz) printf '%s\n' '/arch-redeploy/vmlinuz' ;;
            */initramfs.img) printf '%s\n' '/arch-redeploy/initramfs.img' ;;
            *) return 1 ;;
        esac
    }
    ra_write_grub_entry "$generated" || return 1
    expected=$(printf '%s\n' \
        "$RA_BOOT_START" \
        'set timeout=3' \
        "menuentry '$RA_GRUB_ENTRY' --unrestricted {" \
        '    insmod all_video' \
        '    search --no-floppy --fs-uuid --set=root test-fs-uuid' \
        '    set btrfs_relative_path=n' \
        '    linux /arch-redeploy/vmlinuz console=tty0 console=ttyS0,115200n8' \
        '    initrd /arch-redeploy/initramfs.img' \
        '}' \
        "$RA_BOOT_END")
    [[ $(cat "$generated") == "$expected" ]]
)
assert "generated GRUB entry contains only the expected menu block" test_grub_entry_output

write_grub_one_shot_fixture() {
    local distribution=$1 destination=$2
    case $distribution in
        ubuntu|arch)
            # shellcheck disable=SC2016 # GRUB expands these variables at boot.
            printf '%s\n' \
                'if [ -s $prefix/grubenv ]; then' \
                '  load_env' \
                'fi' \
                'if [ "${next_entry}" ] ; then' \
                '  set default="${next_entry}"' \
                '  set next_entry=' \
                '  save_env next_entry' \
                '  set boot_once=true' \
                'fi' >"$destination"
            ;;
        fedora)
            # shellcheck disable=SC2016 # GRUB expands these variables at boot.
            printf '%s\n' \
                'if [ -f ${config_directory}/grubenv ]; then' \
                '  load_env -f ${config_directory}/grubenv' \
                'elif [ -s $prefix/grubenv ]; then' \
                '  load_env' \
                'fi' \
                'if [ -n "${next_entry}" ]; then' \
                '  set default="${next_entry}"' \
                '  set next_entry=""' \
                '  save_env next_entry' \
                '  set boot_once=true' \
                'fi' >"$destination"
            ;;
        opensuse)
            # shellcheck disable=SC2016 # GRUB expands these variables at boot.
            printf '%s\n' \
                'if [ -f ${config_directory}/grubenv ]; then' \
                '  load_env -f ${config_directory}/grubenv' \
                'elif [ -s $prefix/grubenv ]; then' \
                '  load_env' \
                'fi' \
                'if [ "${env_block}" ]; then' \
                '  set env_block="(${root})${env_block}"' \
                '  export env_block' \
                '  load_env -f "${env_block}"' \
                'fi' \
                'if test -n "${next_entry}"; then' \
                "  set default='\${next_entry}'" \
                '  set next_entry=' \
                '  save_env next_entry' \
                '  if [ "${env_block}" ]; then' \
                '    save_env -f "${env_block}" next_entry' \
                '  fi' \
                '  set boot_once=true' \
                'fi' >"$destination"
            ;;
        opensuse-legacy)
            # shellcheck disable=SC2016 # GRUB expands these variables at boot.
            printf '%s\n' \
                'if [ -s $prefix/grubenv ]; then' \
                '  load_env' \
                'fi' \
                'if [ "${next_entry}" ]; then' \
                '  set default="${next_entry}"' \
                '  set next_entry=' \
                '  save_env next_entry' \
                '  set boot_once=true' \
                'fi' >"$destination"
            ;;
        *) return 1 ;;
    esac
}

test_grub_one_shot_distro_variants() (
    local distribution config
    for distribution in ubuntu fedora opensuse arch; do
        config="$TEST_ROOT/$distribution-grub.cfg"
        write_grub_one_shot_fixture "$distribution" "$config" || return 1
        if [[ $distribution == opensuse ]]; then
            ra_grub_cfg_supports_one_shot "$config" btrfs || return 1
        else
            ra_grub_cfg_supports_one_shot "$config" ext4 || return 1
        fi
    done
)
assert "Ubuntu, Fedora, openSUSE, and Arch GRUB configs expose one-shot semantics" \
    test_grub_one_shot_distro_variants

test_grub_one_shot_rejects_incomplete_or_decoy_config() (
    local config="$TEST_ROOT/incomplete-grub.cfg"
    # shellcheck disable=SC2016 # GRUB expands these variables at boot.
    printf '%s\n' \
        '# load_env' \
        '# if [ "${next_entry}" ]; then' \
        '# set default="${next_entry}"' \
        '# set next_entry=' \
        '# save_env next_entry' \
        'set default=0' >"$config"
    if ra_grub_cfg_supports_one_shot "$config" ext4; then return 1; fi

    # shellcheck disable=SC2016 # GRUB expands these variables at boot.
    printf '%s\n' \
        'load_env' \
        'if [ "${next_entry}" ]; then' \
        '  set default="${next_entry}"' \
        '  set next_entry=' \
        'fi' >"$config"
    if ra_grub_cfg_supports_one_shot "$config" ext4; then return 1; fi

    # shellcheck disable=SC2016 # GRUB expands these variables at boot.
    printf '%s\n' \
        'load_env' \
        'if [ "${next_entry}" ]; then' \
        '  set default="${next_entry}"' \
        '  save_env next_entry' \
        '  set next_entry=' \
        'fi' >"$config"
    ! ra_grub_cfg_supports_one_shot "$config" ext4
)
assert "GRUB capability check rejects comments, missing persistence, and wrong ordering" \
    test_grub_one_shot_rejects_incomplete_or_decoy_config

test_bios_grub_capability_requires_working_editenv() (
    local config="$TEST_ROOT/editor-grub.cfg" failing_editor="$TEST_ROOT/failing-grub-editenv"
    write_grub_one_shot_fixture ubuntu "$config" || return 1

    ra_grub_command() {
        [[ $1 == reboot ]] && printf '%s' /bin/true
    }
    if ra_bios_grub_one_shot_capable "$config" ext4; then return 1; fi

    printf '#!/bin/sh\nexit 1\n' >"$failing_editor"
    chmod +x "$failing_editor"
    ra_grub_command() {
        case $1 in
            reboot) printf '%s' /bin/true ;;
            editenv) printf '%s' "$failing_editor" ;;
            *) return 1 ;;
        esac
    }
    if ra_bios_grub_one_shot_capable "$config" ext4; then return 1; fi

    ra_grub_command() {
        case $1 in
            reboot|editenv) printf '%s' /bin/true ;;
            *) return 1 ;;
        esac
    }
    ra_bios_grub_one_shot_capable "$config" ext4
)
assert "BIOS GRUB capability requires grub-editenv and a readable environment" \
    test_bios_grub_capability_requires_working_editenv

test_btrfs_grub_capability_requires_external_environment() (
    local config="$TEST_ROOT/opensuse-btrfs-grub.cfg"
    local legacy="$TEST_ROOT/opensuse-legacy-grub.cfg"
    local missing_load="$TEST_ROOT/opensuse-missing-external-load.cfg"
    local unrelated_save="$TEST_ROOT/opensuse-unrelated-external-save.cfg"
    local editor="$TEST_ROOT/btrfs-grub-editenv"
    local MOCK_GRUB_ENV
    write_grub_one_shot_fixture opensuse "$config" || return 1
    write_grub_one_shot_fixture opensuse-legacy "$legacy" || return 1
    # shellcheck disable=SC2016 # The expression matches literal GRUB variables.
    sed '/load_env -f "${env_block}"/d' "$config" >"$missing_load"
    # shellcheck disable=SC2016 # The expression replaces literal GRUB variables.
    sed 's/save_env -f "${env_block}" next_entry/save_env -f "${other_block}" next_entry/' \
        "$config" >"$unrelated_save"
    # shellcheck disable=SC2016 # MOCK_GRUB_ENV is supplied to the generated mock.
    printf '#!/bin/sh\nprintf "%%s\\n" "$MOCK_GRUB_ENV"\n' >"$editor"
    chmod +x "$editor"
    export MOCK_GRUB_ENV
    ra_grub_command() {
        case $1 in
            reboot) printf '%s' /bin/true ;;
            editenv) printf '%s' "$editor" ;;
            *) return 1 ;;
        esac
    }

    for MOCK_GRUB_ENV in \
        '' \
        'env_block=512+0' \
        'env_block=+1' \
        'env_block=512+1 trailing'; do
        if ra_bios_grub_one_shot_capable "$config" btrfs; then return 1; fi
    done

    MOCK_GRUB_ENV=$'saved_entry=source\nenv_block=512+1'
    ra_bios_grub_one_shot_capable "$config" btrfs || return 1
    if ra_bios_grub_one_shot_capable "$legacy" btrfs; then return 1; fi
    if ra_bios_grub_one_shot_capable "$missing_load" btrfs; then return 1; fi
    if ra_bios_grub_one_shot_capable "$unrelated_save" btrfs; then return 1; fi
    ra_grub_cfg_supports_one_shot "$legacy" ext4
)
assert "Btrfs GRUB requires an external writable environment block" \
    test_btrfs_grub_capability_requires_external_environment

test_bios_boot_source_rejects_unsupported_stacks() (
    local mock_types mock_status=0
    lsblk() {
        ((mock_status == 0)) || return "$mock_status"
        printf '%s\n' "$mock_types"
    }

    mock_types=$'part\ndisk'
    ra_bios_boot_source_supported /dev/vda1 || return 1
    for mock_types in \
        $'crypt\npart\ndisk' \
        $'lvm\npart\ndisk' \
        $'mpath\ndisk' \
        $'raid1\npart\ndisk'; do
        if ra_bios_boot_source_supported /dev/mapper/test; then return 1; fi
    done
    mock_types=
    if ra_bios_boot_source_supported /dev/unknown; then return 1; fi
    mock_status=1
    ! ra_bios_boot_source_supported /dev/unknown
)
assert "BIOS preflight rejects crypt, LVM, multipath, and RAID boot stacks" \
    test_bios_boot_source_rejects_unsupported_stacks

test_uefi_cancel_restores_bootnext() (
    local efi_dir="$TEST_ROOT/esp/EFI/arch-redeploy" log="$TEST_ROOT/efibootmgr.log"
    mkdir -p "$efi_dir"
    printf 'uefi-test\n' >"$efi_dir/install-id"
    printf '%s\n' "$(jq -n --arg efi_dir "$efi_dir" '{
      state:"scheduled",
      install_id:"uefi-test",
      schedule:{kind:"uefi",efi_dir:$efi_dir,bootnum:"0002",original_bootnext:"0001"}
    }')" >"$RA_STATE_FILE"
    efibootmgr() {
        if (($# == 0)); then
            printf 'BootNext: 0002\nBoot0002* arch-redeploy HD(test)\n'
        else
            printf '%s\n' "$*" >>"$log"
        fi
    }
    ra_unschedule_boot || return 1
    [[ ! -e $efi_dir ]] || return 1
    grep -qx -- '--bootnum 0002 --delete-bootnum' "$log" || return 1
    grep -qx -- '--bootnext 0001' "$log"
)
assert "UEFI cancellation restores the prior BootNext" test_uefi_cancel_restores_bootnext

test_uefi_cancel_preserves_external_bootnext() (
    local log="$TEST_ROOT/efibootmgr-external.log"
    efibootmgr() {
        if (($# == 0)); then
            printf 'BootNext: 0003\n'
        else
            printf '%s\n' "$*" >>"$log"
        fi
    }
    ra_restore_bootnext 0001 0002
    [[ ! -e $log ]]
)
assert "UEFI rollback preserves an externally changed BootNext" \
    test_uefi_cancel_preserves_external_bootnext

marked_file="$TEST_ROOT/grub.cfg"
printf 'before\n%s\nremove me\n%s\nafter\n' "$RA_BOOT_START" "$RA_BOOT_END" >"$marked_file"
ra_remove_marked_entry "$marked_file"
assert_eq "cancel removes only the marked GRUB block" $'before\nafter' "$(cat "$marked_file")"

target_root="$TEST_ROOT/target"
mkdir -p "$target_root/etc/systemd/network"
network_config="$TEST_ROOT/network.json"
printf '%s\n' '{
  "network": {
    "ipv4": {"mode":"dhcp","mac":"52:54:00:12:34:56","address":"","gateway":"","extra_addresses":["192.0.2.99/32"]},
    "ipv6": {"mode":"static","mac":"52:54:00:12:34:56","address":"2001:db8::2/64","gateway":"2001:db8::1","extra_addresses":["2001:db8::3/64"]},
    "dns":["1.1.1.1","2606:4700:4700::1111"]
  }
}' >"$network_config"
target_write_network "$target_root" "$network_config"
network_file=$(find "$target_root/etc/systemd/network" -name '*-arch-redeploy.network')
network_sha=$(ra_sha256 "$network_file")
target_write_network "$target_root" "$network_config"
assert_eq "network generation is idempotent" "$network_sha" "$(ra_sha256 "$network_file")"
assert_eq "one networkd file is emitted per MAC" "1" "$(wc -l <<<"$network_file")"
assert "IPv4 DHCP is preserved" grep -qx 'DHCP=ipv4' "$network_file"
assert "static extra address is preserved with DHCP" grep -qx 'Address=192.0.2.99/32' "$network_file"
assert "static IPv6 address is preserved" grep -qx 'Address=2001:db8::2/64' "$network_file"
assert "on-link IPv6 gateway is preserved" grep -qx 'GatewayOnLink=yes' "$network_file"
assert_eq "both DNS servers are preserved" "2" "$(grep -c '^DNS=' "$network_file")"

dual_static_root="$TEST_ROOT/dual-static-target"
mkdir -p "$dual_static_root/etc/systemd/network"
dual_static_config="$TEST_ROOT/dual-static-network.json"
printf '%s\n' '{
  "network": {
    "ipv4": {"mode":"static","mac":"52:54:00:12:34:56","address":"192.0.2.2/24","gateway":"192.0.2.1","extra_addresses":["192.0.2.3/24"]},
    "ipv6": {"mode":"static","mac":"52:54:00:12:34:56","address":"2001:db8::2/64","gateway":"2001:db8::1","extra_addresses":["2001:db8::3/64"]},
    "dns":["1.1.1.1","2606:4700:4700::1111"]
  }
}' >"$dual_static_config"
target_write_network "$dual_static_root" "$dual_static_config"
dual_static_file=$(find "$dual_static_root/etc/systemd/network" -name '*-arch-redeploy.network')
assert_eq "dual-stack static addresses stay in the Network section" "4" \
    "$(awk '/^\[Route\]/{exit} /^Address=/{count++} END{print count + 0}' "$dual_static_file")"
assert_eq "dual-stack static gateways get separate Route sections" "2" \
    "$(grep -c '^\[Route\]$' "$dual_static_file")"

separate_root="$TEST_ROOT/separate-target"
mkdir -p "$separate_root/etc/systemd/network"
separate_config="$TEST_ROOT/separate-network.json"
printf '%s\n' '{
  "network": {
    "ipv4": {"mode":"static","mac":"52:54:00:00:00:04","address":"192.0.2.2/24","gateway":"192.0.2.1","extra_addresses":[]},
    "ipv6": {"mode":"dhcp","mac":"52:54:00:00:00:06","address":"","gateway":"","extra_addresses":[]},
    "dns":["1.1.1.1"]
  }
}' >"$separate_config"
target_write_network "$separate_root" "$separate_config"
assert_eq "separate IPv4 and IPv6 NICs get separate networkd files" "2" \
    "$(find "$separate_root/etc/systemd/network" -name '*-arch-redeploy.network' | wc -l | tr -d ' ')"
assert "DHCPv6 is attached to the IPv6 MAC" grep -lq 'MACAddress=52:54:00:00:00:06' \
    "$(grep -l 'DHCP=ipv6' "$separate_root/etc/systemd/network"/*-arch-redeploy.network)"

test_bios_schedule_rejects_incapable_grub_without_mutation() (
    local mock_cfg="$TEST_ROOT/incapable-grub.cfg" original
    printf 'existing\n' >"$mock_cfg"
    original=$(cat "$mock_cfg")
    printf '{"state":"prepared"}\n' >"$RA_STATE_FILE"
    ra_find_grub_cfg() { printf '%s' "$mock_cfg"; }
    ra_bios_grub_one_shot_capable() { return 1; }

    if ra_schedule_bios_grub; then return 1; fi
    [[ $(cat "$mock_cfg") == "$original" ]] || return 1
    jq -e 'has("schedule") | not' "$RA_STATE_FILE" >/dev/null
)
assert "BIOS scheduling rejects incapable GRUB before changing its config" \
    test_bios_schedule_rejects_incapable_grub_without_mutation

test_bios_schedule_cancel() (
    local mock_cfg="$TEST_ROOT/mock-grub.cfg" mock="$TEST_ROOT/grub-reboot" log="$TEST_ROOT/grub-reboot.log"
    local restored="$TEST_ROOT/grub-next-restored.log" original
    printf 'existing\n' >"$mock_cfg"
    original=$(cat "$mock_cfg")
    # shellcheck disable=SC2016 # $1 belongs to the generated mock script.
    printf '#!/bin/sh\nprintf "%%s\\n" "$1" >"%s"\n' "$log" >"$mock"
    chmod +x "$mock"
    printf '{"state":"prepared"}\n' >"$RA_STATE_FILE"
    ra_find_grub_cfg() { printf '%s' "$mock_cfg"; }
    ra_write_grub_entry() {
        printf '%s\nmenuentry test {}\n%s\n' "$RA_BOOT_START" "$RA_BOOT_END" >"$1"
    }
    ra_grub_next_entry() { printf '%s' 'previous-one-shot'; }
    ra_restore_grub_next_entry() { printf '%s' "$1" >"$restored"; }
    ra_grub_command() { [[ $1 == reboot ]] && printf '%s' "$mock"; }
    ra_bios_grub_one_shot_capable() { return 0; }
    ra_schedule_bios_grub || return 1
    [[ $(jq -r .schedule.kind "$RA_STATE_FILE") == bios-grub ]] || return 1
    grep -qx "$RA_GRUB_ENTRY" "$log" || return 1
    grep -qF "$RA_BOOT_START" "$mock_cfg" || return 1
    ra_unschedule_boot || return 1
    if grep -qF "$RA_BOOT_START" "$mock_cfg"; then return 1; fi
    [[ $(cat "$mock_cfg") == "$original" ]] || return 1
    [[ $(cat "$restored") == previous-one-shot ]] || return 1
)
assert "mocked BIOS scheduling restores exact config and prior selector" test_bios_schedule_cancel

test_bios_schedule_rollback() (
    local mock_cfg="$TEST_ROOT/failing-grub.cfg" mock="$TEST_ROOT/failing-grub-reboot"
    printf 'existing\n' >"$mock_cfg"
    printf '#!/bin/sh\nexit 1\n' >"$mock"
    chmod +x "$mock"
    printf '{"state":"prepared"}\n' >"$RA_STATE_FILE"
    ra_find_grub_cfg() { printf '%s' "$mock_cfg"; }
    ra_write_grub_entry() {
        printf '%s\nmenuentry test {}\n%s\n' "$RA_BOOT_START" "$RA_BOOT_END" >"$1"
    }
    ra_grub_command() { [[ $1 == reboot ]] && printf '%s' "$mock"; }
    ra_bios_grub_one_shot_capable() { return 0; }
    if ra_schedule_bios_grub; then return 1; fi
    if grep -qF "$RA_BOOT_START" "$mock_cfg"; then return 1; fi
    [[ $(jq -r '.schedule // "none"' "$RA_STATE_FILE") == none ]]
)
assert "failed mocked BIOS scheduling rolls back its config" test_bios_schedule_rollback

test_bios_cancel_preserves_external_drift() (
    local mock_cfg="$TEST_ROOT/drift-grub.cfg" mock="$TEST_ROOT/drift-grub-reboot"
    printf 'existing\n' >"$mock_cfg"
    printf '#!/bin/sh\nexit 0\n' >"$mock"
    chmod +x "$mock"
    printf '{"state":"prepared"}\n' >"$RA_STATE_FILE"
    ra_find_grub_cfg() { printf '%s' "$mock_cfg"; }
    ra_write_grub_entry() {
        printf '%s\nmenuentry test {}\n%s\n' "$RA_BOOT_START" "$RA_BOOT_END" >"$1"
    }
    ra_grub_command() { [[ $1 == reboot ]] && printf '%s' "$mock"; }
    ra_bios_grub_one_shot_capable() { return 0; }
    ra_schedule_bios_grub || return 1
    printf 'external-change\n' >>"$mock_cfg"
    ra_unschedule_boot || return 1
    [[ $(cat "$mock_cfg") == $'existing\nexternal-change' ]]
)
assert "BIOS cancellation preserves external configuration drift" \
    test_bios_cancel_preserves_external_drift

test_return_hook_lifecycle() (
    local unit_dir="$TEST_ROOT/systemd" log="$TEST_ROOT/systemctl.log"
    mkdir -p "$unit_dir" "$RA_STATE_DIR"
    printf '{"install_id":"test-id"}\n' >"$RA_STATE_FILE"
    systemctl() { printf '%s\n' "$*" >>"$log"; }
    ARCH_REDEPLOY_INIT_KIND=systemd \
        ARCH_REDEPLOY_SYSTEMD_UNIT_DIR="$unit_dir" \
        ra_install_source_return_hook || return 1
    [[ $(jq -r .return_hook.kind "$RA_STATE_FILE") == systemd ]] || return 1
    [[ -x $RA_STATE_DIR/runtime/source-rollback ]] || return 1
    [[ -r $RA_STATE_DIR/runtime/lib/disk.sh ]] || return 1
    [[ -f $unit_dir/arch-redeploy-return.service ]] || return 1
    RA_PROJECT_ROOT="$RA_STATE_DIR/runtime" \
        ARCH_REDEPLOY_STATE_DIR="$RA_STATE_DIR" \
        bash -c '
          set -Eeuo pipefail
          source "$RA_PROJECT_ROOT/lib/common.sh"
          source "$RA_PROJECT_ROOT/lib/detect.sh"
          source "$RA_PROJECT_ROOT/lib/boot.sh"
          declare -F ra_partition_table_hash >/dev/null
          declare -F ra_unschedule_boot >/dev/null
        ' || return 1
    ra_remove_source_return_hook || return 1
    [[ ! -e $unit_dir/arch-redeploy-return.service ]] || return 1
    ra_remove_source_return_hook
)
assert "source return hook install and removal are idempotent" test_return_hook_lifecycle

test_recovery_control() (
    local current="$TEST_ROOT/recovery-current" cancel="$TEST_ROOT/recovery-cancel"
    local erased="$TEST_ROOT/recovery-erased" blocked_cancel="$TEST_ROOT/recovery-blocked-cancel"
    local boundary_lock="$TEST_ROOT/recovery-boundary.lock" output
    printf '%s\n' install >"$current"
    output=$(ARCH_REDEPLOY_CURRENT_STAGE="$current" \
        ARCH_REDEPLOY_CANCEL_REQUEST="$cancel" \
        ARCH_REDEPLOY_ERASE_STARTED="$erased" \
        ARCH_REDEPLOY_BOUNDARY_LOCK="$boundary_lock" \
        ARCH_REDEPLOY_STAGES_LIBRARY="$PROJECT_ROOT/lib/stages.sh" \
        "$PROJECT_ROOT/installer/control.sh" status) || return 1
    grep -q '^ > 7\.' <<<"$output" || return 1
    ARCH_REDEPLOY_CURRENT_STAGE="$current" \
        ARCH_REDEPLOY_CANCEL_REQUEST="$cancel" \
        ARCH_REDEPLOY_ERASE_STARTED="$erased" \
        ARCH_REDEPLOY_BOUNDARY_LOCK="$boundary_lock" \
        ARCH_REDEPLOY_STAGES_LIBRARY="$PROJECT_ROOT/lib/stages.sh" \
        "$PROJECT_ROOT/installer/control.sh" cancel >/dev/null || return 1
    [[ -e $cancel ]] || return 1
    : >"$erased"
    if ARCH_REDEPLOY_CURRENT_STAGE="$current" \
        ARCH_REDEPLOY_CANCEL_REQUEST="$blocked_cancel" \
        ARCH_REDEPLOY_ERASE_STARTED="$erased" \
        ARCH_REDEPLOY_BOUNDARY_LOCK="$boundary_lock" \
        ARCH_REDEPLOY_STAGES_LIBRARY="$PROJECT_ROOT/lib/stages.sh" \
        "$PROJECT_ROOT/installer/control.sh" cancel >/dev/null 2>&1; then
        return 1
    fi
    [[ ! -e $blocked_cancel ]]
)
assert "recovery control cancels only before disk erasure" test_recovery_control

test_udhcpc_mask() (
    local mock_bin="$TEST_ROOT/mock-bin" log="$TEST_ROOT/ip.log"
    mkdir -p "$mock_bin"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$log" >"$mock_bin/ip"
    chmod +x "$mock_bin/ip"
    PATH="$mock_bin:$PATH" RESOLV_CONF="$TEST_ROOT/resolv.conf" \
        interface=eth0 ip=192.0.2.10 mask=255.255.254.0 \
        router=192.0.2.1 dns=1.1.1.1 "$PROJECT_ROOT/installer/udhcpc.script" bound
    grep -qx 'address replace 192.0.2.10/23 dev eth0' "$log"
)
assert "DHCP subnet masks are converted to prefixes" test_udhcpc_mask

test_gpg_home="$TEST_ROOT/gnupg"
mkdir -m 0700 "$test_gpg_home"
fingerprint=$(gpg --batch --homedir "$test_gpg_home" --import-options show-only \
    --with-colons --import "$PROJECT_ROOT/assets/alpine-release-key.asc" 2>/dev/null |
    awk -F: '$1 == "fpr" {print $10; exit}')
assert_eq "pinned Alpine release-key fingerprint" \
    "0482D84022F52DF1C4E7CD43293ACD0907D9495A" "$fingerprint"

assert "CLI help is available without root" "$PROJECT_ROOT/arch-redeploy" help
# shellcheck disable=SC2016 # positional parameter is expanded by the child shell.
assert "stage-named prepare command is rejected" bash -c \
    '! "$1/arch-redeploy" prepare >/dev/null 2>&1' _ "$PROJECT_ROOT"
# shellcheck disable=SC2016 # positional parameter is expanded by the child shell.
assert "stage-named schedule command is rejected" bash -c \
    '! "$1/arch-redeploy" schedule >/dev/null 2>&1' _ "$PROJECT_ROOT"
# shellcheck disable=SC2016 # positional parameter is expanded by the child shell.
assert "explicit run command is absent" bash -c \
    '! "$1/arch-redeploy" run >/dev/null 2>&1' _ "$PROJECT_ROOT"
# shellcheck disable=SC2016 # positional parameter is expanded by the child shell.
assert "help exposes only operational commands" bash -c '
    help=$($1/arch-redeploy help)
    ! grep -Eq "^  (prepare|schedule|run)[[:space:]]" <<<"$help"
' _ "$PROJECT_ROOT"
# shellcheck disable=SC2016 # positional parameter is expanded by the child shell.
assert "Windows entrypoints are absent" bash -c \
    '! find "$1" -maxdepth 2 -type f \( -name "*.bat" -o -name "*.ps1" -o -name "*.xml" \) | grep -q .' _ "$PROJECT_ROOT"

printf '1..%d\n' "$tests"
