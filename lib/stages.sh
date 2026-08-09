#!/usr/bin/env bash

[[ ${RA_STAGES_LOADED:-} == 1 ]] && return 0
RA_STAGES_LOADED=1

readonly -a RA_STAGE_IDS=(
    inspect
    build
    review
    armed
    revalidate
    recovery
    install
    verify
    cleanup
)

ra_stage_label() {
    case $1 in
        inspect) echo "Inspect system and capture plan" ;;
        build) echo "Build and verify installer" ;;
        review) echo "Review redeploy plan" ;;
        armed) echo "Arm one-shot boot and reboot" ;;
        revalidate) echo "Revalidate disk, network, and payload" ;;
        recovery) echo "Create Arch layout and persistent recovery" ;;
        install) echo "Install and configure Arch" ;;
        verify) echo "Validate target and reboot" ;;
        cleanup) echo "Verify first boot and remove recovery" ;;
        *) return 1 ;;
    esac
}

ra_stage_index() {
    local wanted=$1 index
    for index in "${!RA_STAGE_IDS[@]}"; do
        if [[ ${RA_STAGE_IDS[$index]} == "$wanted" ]]; then
            printf '%s' "$index"
            return 0
        fi
    done
    return 1
}

ra_stage_valid() { ra_stage_index "$1" >/dev/null; }

ra_stage_transition_allowed() {
    local current_index next_index
    current_index=$(ra_stage_index "$1") || return 1
    next_index=$(ra_stage_index "$2") || return 1
    ((next_index == current_index || next_index == current_index + 1))
}

ra_render_timeline() {
    local current=$1 note=${2:-} current_index index marker label
    current_index=$(ra_stage_index "$current") || return 1
    printf 'Arch redeploy progress - stage %d of %d\n\n' \
        "$((current_index + 1))" "${#RA_STAGE_IDS[@]}"
    for index in "${!RA_STAGE_IDS[@]}"; do
        marker=' '
        ((index == current_index)) && marker='>'
        label=$(ra_stage_label "${RA_STAGE_IDS[$index]}")
        printf ' %s %d. %s' "$marker" "$((index + 1))" "$label"
        if ((index == current_index)) && [[ -n $note ]]; then
            printf ' (%s)' "$note"
        fi
        printf '\n'
        if ((index == 3)); then
            printf '      -------- reboot boundary --------\n'
        elif ((index == 4)); then
            printf '      ---- disk erasure begins here ----\n'
        fi
    done
}

ra_progress_current() {
    local current state
    if ! ra_state_exists; then
        printf '%s' inspect
        return
    fi
    current=$(jq -r '.progress.current // empty' "$RA_STATE_FILE")
    if ra_stage_valid "$current"; then
        printf '%s' "$current"
        return
    fi
    state=$(jq -r '.state // empty' "$RA_STATE_FILE")
    case $state in
        preparing) printf '%s' build ;;
        prepared) printf '%s' review ;;
        scheduled) printf '%s' armed ;;
        *) printf '%s' inspect ;;
    esac
}

ra_progress_initialize() {
    local current=$1 time=${2:-$(date -u +%FT%TZ)}
    ra_stage_valid "$current" || return 1
    # shellcheck disable=SC2016
    ra_state_update '.progress = {
        current:$current,
        started_at:$time,
        updated_at:$time,
        completed:{inspect:$time}
    }' --arg current "$current" --arg time "$time"
}

ra_progress_set() {
    local next=$1 current time
    current=$(ra_progress_current)
    ra_stage_transition_allowed "$current" "$next" || return 1
    [[ $current != "$next" ]] || return 0
    time=$(date -u +%FT%TZ)
    # shellcheck disable=SC2016
    ra_state_update '.progress.completed[.progress.current] = $time |
        .progress.current = $next | .progress.started_at = $time |
        .progress.updated_at = $time' --arg next "$next" --arg time "$time"
}
