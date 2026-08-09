#!/bin/bash

set -Eeuo pipefail

# shellcheck source=lib/stages.sh
source /usr/local/lib/arch-redeploy/stages.sh

ra_render_timeline cleanup
echo

systemctl -q is-active sshd.service
systemctl -q is-active systemd-networkd.service
ip route show default | grep -q . || ip -6 route show default | grep -q .

result_dir=/var/lib/arch-redeploy
result_file=$result_dir/result.json
install -d -m 0700 "$result_dir"
if [[ -r /.arch-redeploy-install-id ]]; then
    install -m 0600 /.arch-redeploy-install-id "$result_dir/install-id"
fi
[[ -r $result_dir/install-id ]] || {
    echo "arch-redeploy install ID is unavailable; refusing final cleanup" >&2
    exit 1
}
install_id=$(cat "$result_dir/install-id")
[[ $install_id =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || {
    echo "arch-redeploy install ID is invalid; refusing final cleanup" >&2
    exit 1
}
finalizing_at=$(date -u +%FT%TZ)
result_tmp=$(mktemp "$result_dir/result.XXXXXX")
printf '{"install_id":"%s","status":"finalizing","updated_at":"%s"}\n' \
    "$install_id" "$finalizing_at" >"$result_tmp"
chmod 0600 "$result_tmp"
mv -f "$result_tmp" "$result_file"
sync

compact_install_id=${install_id//-/}
source_boot_label=$(printf 'arch-redeploy-%.8s' "${compact_install_id,,}")
recovery_boot_label=$(printf 'arch-redeploy-recovery-%.8s' "${compact_install_id,,}")
rm -f /etc/grub.d/41_arch_redeploy_recovery
grub-mkconfig -o /boot/grub/grub.cfg
if [[ -d /sys/firmware/efi ]]; then
    if command -v efibootmgr >/dev/null; then
        while IFS= read -r bootnum; do
            if [[ -n $bootnum ]]; then
                efibootmgr --bootnum "$bootnum" --delete-bootnum || true
            fi
        done < <(efibootmgr 2>/dev/null |
            awk -v source_label="$source_boot_label" -v recovery_label="$recovery_boot_label" \
                '$1 ~ /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]\*?$/ &&
                ($2 == recovery_label || $2 == source_label) {
                value=$1; sub(/^Boot/, "", value); sub(/\*$/, "", value); print value
            }')
    fi
    rm -rf "/efi/EFI/$recovery_boot_label"
fi
rm -rf /arch-redeploy-recovery
rm -f /.arch-redeploy-install-id

completed_at=$(date -u +%FT%TZ)
result_tmp=$(mktemp "$result_dir/result.XXXXXX")
printf '{"install_id":"%s","status":"complete","completed_at":"%s"}\n' \
    "$install_id" "$completed_at" >"$result_tmp"
chmod 0600 "$result_tmp"
mv -f "$result_tmp" "$result_file"
sync

systemctl disable arch-redeploy-finalize.service 2>/dev/null || true
rm -f /etc/systemd/system/arch-redeploy-finalize.service
systemctl daemon-reload 2>/dev/null || true
rm -f /usr/local/lib/arch-redeploy/finalize.sh
rm -f /usr/local/lib/arch-redeploy/stages.sh
