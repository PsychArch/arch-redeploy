#!/usr/bin/env bash

[[ ${RA_DISK_LOADED:-} == 1 ]] && return 0
RA_DISK_LOADED=1

ra_trim_disk_identifier() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "$value"
}

ra_disk_serial() {
    local disk=$1 resolved node value path
    local sys_class_block=${ARCH_REDEPLOY_SYS_CLASS_BLOCK_ROOT:-/sys/class/block}
    resolved=$(readlink -f -- "$disk" 2>/dev/null || printf '%s' "$disk")
    node=${resolved##*/}
    for path in "$sys_class_block/$node/serial" "$sys_class_block/$node/device/serial"; do
        [[ -r $path ]] || continue
        value=$(cat "$path" 2>/dev/null || true)
        value=$(ra_trim_disk_identifier "$value")
        if [[ -n $value ]]; then
            printf '%s' "$value"
            return 0
        fi
    done
    value=$(LC_ALL=C lsblk -dnro SERIAL "$disk" 2>/dev/null | sed -n '1p') || value=
    value=$(ra_trim_disk_identifier "$value")
    if [[ -n $value ]]; then
        printf '%s' "$value"
    fi
    return 0
}

ra_sfdisk_json_supported() {
    local help
    command -v sfdisk >/dev/null 2>&1 || return 1
    help=$(LC_ALL=C sfdisk --help 2>&1) || return 1
    [[ $help == *--json* ]]
}

ra_partition_table_canonical() {
    local disk=$1
    LC_ALL=C sfdisk --json "$disk" 2>/dev/null |
        jq -ceS '
          def required($name):
            if . == null then error("missing partition-table " + $name) else . end;
          def lower_string:
            if type == "string" then ascii_downcase else . end;
          .partitiontable as $table |
          {
            label: ($table.label | required("label") | lower_string),
            id: ($table.id | required("id") | lower_string),
            partitions: [
              ($table.partitions // [])[] | {
                number: (
                  .node | required("partition node") |
                  capture("(?<number>[0-9]+)$").number | tonumber
                ),
                start: (.start | required("partition start")),
                size: (.size | required("partition size")),
                type: (.type | required("partition type") | lower_string),
                uuid: (.uuid // "" | lower_string),
                name: (.name // ""),
                attrs: (.attrs // ""),
                bootable: (.bootable // false)
              }
            ] | sort_by([.number, .start, .size])
          } |
          if (.partitions | length) == 0
          then error("partition table has no partitions")
          else .
          end'
}

ra_partition_table_hash() {
    ra_partition_table_canonical "$1" | sha256sum | awk '{print $1}'
}

ra_partition_table_id() {
    ra_partition_table_canonical "$1" |
        jq -er '.id | select(type == "string" and length > 0)'
}
