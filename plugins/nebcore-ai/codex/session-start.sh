#!/bin/bash
# REASON: child nonzero exits are classified outcomes, so the supervisor cannot use errexit.
set -uo pipefail
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    exec 2>/dev/null
fi

NEBCORE_MIN_VERSION=6.13.0
NEBCORE_COMPONENT_MAX=2147483647
NEBCORE_STREAM_LIMIT=16384
NEBCORE_CHILD_SECONDS=5
NEBCORE_WORK_SECONDS=10

NEBCORE_MISSING='NebCore AI tools are unavailable because nebcli is not installed. Install nebcli, run nebcli login, then start a new Codex session.'
NEBCORE_VERSION_FAILURE='NebCore AI tools are unavailable because the installed nebcli version could not be verified. Upgrade nebcli to 6.13.0 or newer, run nebcli login, then start a new Codex session.'
NEBCORE_LOGIN_MISSING='NebCore AI tools are unavailable because nebcli is not logged in. Run nebcli login, then start a new Codex session.'
NEBCORE_BRIDGE_FAILURE='NebCore AI tools are unavailable because the nebcli prerequisite check did not complete safely. Verify nebcli 6.13.0 or newer, run nebcli login, then start a new Codex session.'

nebcore_cleanup_paths=()
nebcore_active_group=''
nebcore_child_outcome=''
nebcore_child_status=0
nebcore_child_stdout=''
nebcore_child_stderr=''
nebcore_internal_expired=0

nebcore_cleanup() {
    local path
    if [[ -n "$nebcore_active_group" ]]; then
        kill -KILL -- "-$nebcore_active_group" 2>/dev/null || true
        wait "$nebcore_active_group" 2>/dev/null || true
        nebcore_active_group=''
    fi
    for path in "${nebcore_cleanup_paths[@]}"; do
        rm -rf -- "$path"
    done
    nebcore_cleanup_paths=()
}

nebcore_child_timeout() {
    if [[ -n "$nebcore_active_group" ]]; then
        nebcore_child_outcome=timeout
        kill -KILL -- "-$nebcore_active_group" 2>/dev/null || true
    fi
}

nebcore_stream_overflow() {
    if [[ -n "$nebcore_active_group" ]]; then
        nebcore_child_outcome=overflow
        kill -KILL -- "-$nebcore_active_group" 2>/dev/null || true
    fi
}

nebcore_internal_timeout() {
    nebcore_internal_expired=1
    if [[ -n "$nebcore_active_group" ]]; then
        nebcore_child_outcome=budget
        kill -KILL -- "-$nebcore_active_group" 2>/dev/null || true
    fi
}

nebcore_capture_stream() {
    local input_fifo=$1
    local result_fifo=$2
    local supervisor_pid=$3
    local encoded count
    encoded=$(LC_ALL=C dd if="$input_fifo" bs=1 count=$((NEBCORE_STREAM_LIMIT + 1)) 2>/dev/null | LC_ALL=C od -An -v -tx1 | tr -d '[:space:]')
    count=$((${#encoded} / 2))
    if (( count > NEBCORE_STREAM_LIMIT )); then
        kill -USR1 "$supervisor_pid" 2>/dev/null || true
        encoded=${encoded:0:$((NEBCORE_STREAM_LIMIT * 2))}
    fi
    printf '%s\n%s\n' "$count" "$encoded" >"$result_fifo"
}

nebcore_start_watchdog() {
    local signal=$1
    local seconds=$2
    local supervisor_pid=$3
    local control_fifo=${4:-}
    local watchdog_fifo=$5
    (
        exec 9<>"$watchdog_fifo"
        if [[ -n "$control_fifo" ]]; then
            IFS= read -r _ <"$control_fifo" || exit 0
            kill -"$signal" "$supervisor_pid" 2>/dev/null || true
        elif ! IFS= read -r -t "$seconds" _ <&9; then
            kill -"$signal" "$supervisor_pid" 2>/dev/null || true
        fi
    ) &
    NEBCORE_WATCHDOG_PID=$!
}

nebcore_stop_watchdog() {
    local watchdog_pid=$1
    kill -TERM "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
}

nebcore_read_capture() {
    local result_fifo=$1
    local count_name=$2
    local encoded_name=$3
    local count encoded
    exec 8<"$result_fifo"
    IFS= read -r count <&8 || {
        exec 8<&-
        return 1
    }
    IFS= read -r encoded <&8 || encoded=''
    exec 8<&-
    printf -v "$count_name" '%s' "$count"
    printf -v "$encoded_name" '%s' "$encoded"
}

nebcore_decode_ascii() {
    local encoded=$1
    local decoded_name=$2
    local decoded='' byte character
    while [[ -n "$encoded" ]]; do
        byte=${encoded:0:2}
        encoded=${encoded:2}
        case "$byte" in
            09|0a|0d|2[0-9a-f]|3[0-9a-f]|4[0-9a-f]|5[0-9a-f]|6[0-9a-f]|7[0-9a-e]) ;;
            *) return 1 ;;
        esac
        printf -v character '%b' "\\x$byte"
        decoded=$decoded$character
    done
    printf -v "$decoded_name" '%s' "$decoded"
}

nebcore_run_child() {
    local application=$1
    local test_deadline_fifo=$3
    shift 3
    local run_root start_fifo stdout_fifo stderr_fifo stdout_result stderr_result watchdog_fifo
    local stdout_reader stderr_reader watchdog_pid child_pid status stdout_count stderr_count

    nebcore_child_outcome=setup
    nebcore_child_status=0
    nebcore_child_stdout=''
    nebcore_child_stderr=''
    if (( nebcore_internal_expired )); then
        nebcore_child_outcome=budget
        return 0
    fi

    run_root=$(mktemp -d "${TMPDIR:-/tmp}/nebcore-hook.XXXXXX") || return 0
    nebcore_cleanup_paths+=("$run_root")
    start_fifo=$run_root/start
    stdout_fifo=$run_root/stdout
    stderr_fifo=$run_root/stderr
    stdout_result=$run_root/stdout-result
    stderr_result=$run_root/stderr-result
    watchdog_fifo=$run_root/watchdog
    mkfifo "$start_fifo" "$stdout_fifo" "$stderr_fifo" "$stdout_result" "$stderr_result" "$watchdog_fifo" || return 0

    nebcore_capture_stream "$stdout_fifo" "$stdout_result" "$$" &
    stdout_reader=$!
    nebcore_capture_stream "$stderr_fifo" "$stderr_result" "$$" &
    stderr_reader=$!

    set -m
    (
        trap - ALRM USR1 USR2
        IFS= read -r _ <"$start_fifo" || exit 126
        exec </dev/null
        exec "$application" "$@"
    ) >"$stdout_fifo" 2>"$stderr_fifo" &
    child_pid=$!
    set +m
    nebcore_active_group=$child_pid

    if ! kill -0 -- "-$child_pid" 2>/dev/null; then
        kill -KILL "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
        nebcore_active_group=''
        wait "$stdout_reader" "$stderr_reader" 2>/dev/null || true
        return 0
    fi

    nebcore_start_watchdog ALRM "$NEBCORE_CHILD_SECONDS" "$$" "$test_deadline_fifo" "$watchdog_fifo"
    watchdog_pid=$NEBCORE_WATCHDOG_PID
    printf 'start\n' >"$start_fifo"
    nebcore_child_outcome='exit'
    wait "$child_pid"
    status=$?
    if [[ "$nebcore_child_outcome" != exit ]]; then
        wait "$child_pid" 2>/dev/null || true
    fi
    nebcore_active_group=''
    nebcore_stop_watchdog "$watchdog_pid"

    nebcore_read_capture "$stdout_result" stdout_count nebcore_child_stdout || nebcore_child_outcome=setup
    nebcore_read_capture "$stderr_result" stderr_count nebcore_child_stderr || nebcore_child_outcome=setup
    wait "$stdout_reader" "$stderr_reader" 2>/dev/null || nebcore_child_outcome=setup
    if (( stdout_count > NEBCORE_STREAM_LIMIT || stderr_count > NEBCORE_STREAM_LIMIT )); then
        nebcore_child_outcome=overflow
    fi
    nebcore_child_status=$status

    rm -rf -- "$run_root"
    nebcore_cleanup_paths=("${nebcore_cleanup_paths[@]:0:${#nebcore_cleanup_paths[@]}-1}")
}

nebcore_compare_version() {
    local major=$1 minor=$2 patch=$3
    if (( major != 6 )); then
        (( major > 6 ))
        return
    fi
    if (( minor != 13 )); then
        (( minor > 13 ))
        return
    fi
    (( patch >= 0 ))
}

nebcore_parse_component() {
    local value=$1 output_name=$2 parsed
    if (( ${#value} > 10 )); then
        return 1
    fi
    # REASON: Equal-length ASCII digit strings preserve numeric ordering without evaluating an unbounded value.
    # shellcheck disable=SC2071
    if (( ${#value} == 10 )) && [[ $value > $NEBCORE_COMPONENT_MAX ]]; then
        return 1
    fi
    parsed=$((10#$value))
    printf -v "$output_name" '%s' "$parsed"
}

nebcore_diagnose() {
    local test_version_deadline=${1:-}
    local test_bridge_deadline=${2:-}
    local nebcli raw version major minor patch
    local internal_root internal_fifo internal_pid

    trap nebcore_cleanup EXIT HUP INT TERM
    trap nebcore_child_timeout ALRM
    trap nebcore_stream_overflow USR1
    trap nebcore_internal_timeout USR2

    nebcli=$(command -v nebcli 2>/dev/null || true)
    if [[ -z "$nebcli" || ! -x "$nebcli" ]]; then
        printf '%s\n' "$NEBCORE_MISSING"
        return 0
    fi

    internal_root=$(mktemp -d "${TMPDIR:-/tmp}/nebcore-hook-budget.XXXXXX") || {
        printf '%s\n' "$NEBCORE_VERSION_FAILURE"
        return 0
    }
    nebcore_cleanup_paths+=("$internal_root")
    internal_fifo=$internal_root/watchdog
    mkfifo "$internal_fifo" || {
        printf '%s\n' "$NEBCORE_VERSION_FAILURE"
        return 0
    }
    nebcore_start_watchdog USR2 "$NEBCORE_WORK_SECONDS" "$$" '' "$internal_fifo"
    internal_pid=$NEBCORE_WATCHDOG_PID

    nebcore_run_child "$nebcli" version "$test_version_deadline" --version
    if [[ "$nebcore_child_outcome" != exit || $nebcore_child_status -ne 0 ]]; then
        printf '%s\n' "$NEBCORE_VERSION_FAILURE"
        nebcore_stop_watchdog "$internal_pid"
        return 0
    fi
    if ! nebcore_decode_ascii "$nebcore_child_stdout$nebcore_child_stderr" raw; then
        printf '%s\n' "$NEBCORE_VERSION_FAILURE"
        nebcore_stop_watchdog "$internal_pid"
        return 0
    fi
    if [[ ! "$raw" =~ (^|[^0-9])v?([0-9]+)\.([0-9]+)\.([0-9]+)($|[^0-9]) ]]; then
        printf '%s\n' "$NEBCORE_VERSION_FAILURE"
        nebcore_stop_watchdog "$internal_pid"
        return 0
    fi
    if ! nebcore_parse_component "${BASH_REMATCH[2]}" major ||
        ! nebcore_parse_component "${BASH_REMATCH[3]}" minor ||
        ! nebcore_parse_component "${BASH_REMATCH[4]}" patch; then
        printf '%s\n' "$NEBCORE_VERSION_FAILURE"
        nebcore_stop_watchdog "$internal_pid"
        return 0
    fi
    version=$major.$minor.$patch
    nebcore_child_stdout=''
    nebcore_child_stderr=''

    if ! nebcore_compare_version "$major" "$minor" "$patch"; then
        printf 'NebCore AI tools are unavailable because nebcli %s is older than the required %s. Upgrade nebcli, run nebcli login, then start a new Codex session.\n' "$version" "$NEBCORE_MIN_VERSION"
        nebcore_stop_watchdog "$internal_pid"
        return 0
    fi

    nebcore_run_child "$nebcli" bridge "$test_bridge_deadline" mcp
    if [[ "$nebcore_child_outcome" == timeout || "$nebcore_child_outcome" == overflow || "$nebcore_child_outcome" == budget || "$nebcore_child_outcome" == setup ]]; then
        printf '%s\n' "$NEBCORE_BRIDGE_FAILURE"
        nebcore_stop_watchdog "$internal_pid" "$internal_fifo"
        return 0
    fi
    if nebcore_decode_ascii "$nebcore_child_stdout$nebcore_child_stderr" raw && [[ "$raw" == *"no platform URL configured: set PLATFORM_URL env or run \`nebcli login\`"* ]]; then
        printf '%s\n' "$NEBCORE_LOGIN_MISSING"
    fi
    nebcore_child_stdout=''
    nebcore_child_stderr=''
    nebcore_stop_watchdog "$internal_pid"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    nebcore_diagnose
fi
