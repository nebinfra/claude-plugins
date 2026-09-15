#!/bin/bash
set -euo pipefail

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
HOOK=$REPO_ROOT/plugins/nebcore-ai/codex/session-start.sh
TEST_ROOT=$(mktemp -d)
SYSTEM_PATH=$PATH
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_equal() {
    local want=$1 actual=$2 label=$3
    [[ "$actual" == "$want" ]] || fail "$label: got <$actual>, want <$want>"
}

assert_gone() {
    local pid=$1 label=$2
    if kill -0 "$pid" 2>/dev/null; then
        fail "$label process $pid is still running"
    fi
}

mkdir -p "$TEST_ROOT/bin"
cat >"$TEST_ROOT/bin/nebcli" <<'FAKE'
#!/bin/bash
set -euo pipefail

if [[ $1 == --version ]]; then
    case ${NEBCORE_FIXTURE_MODE:?} in
        old) printf 'nebcli version 6.12.0\n' ;;
        leading-old) printf 'nebcli version 06.012.000\n' ;;
        component-max) printf 'nebcli version 2147483647.2147483647.2147483647\n' ;;
        component-overflow) printf 'nebcli version 2147483648.13.0\n' ;;
        component-too-long) printf 'nebcli version 00000000006.13.0\n' ;;
        unreadable) printf 'secret-version-marker\n' ;;
        version-overflow) dd if=/dev/zero bs=16385 count=1 2>/dev/null | tr '\000' 1 ;;
        version-block)
            bash -c 'trap "" TERM; while :; do :; done' &
            printf '%s\n' "$!" >"$NEBCORE_FIXTURE_PID"
            printf 'ready\n' >"$NEBCORE_FIXTURE_READY"
            wait
            ;;
        *) printf 'nebcli version 6.17.1\n' ;;
    esac
    exit 0
fi

[[ $1 == mcp ]] || exit 91
if IFS= read -r _; then
    exit 92
fi
case ${NEBCORE_FIXTURE_MODE:?} in
    login) printf '%s\n' 'no platform URL configured: set PLATFORM_URL env or run `nebcli login`' >&2; exit 1 ;;
    bridge-overflow) dd if=/dev/zero bs=16385 count=1 2>/dev/null | tr '\000' s >&2; exit 1 ;;
    bridge-block)
        bash -c 'trap "" TERM; while :; do :; done' &
        printf '%s\n' "$!" >"$NEBCORE_FIXTURE_PID"
        printf 'ready\n' >"$NEBCORE_FIXTURE_READY"
        wait
        ;;
    unexpected) printf 'secret-bridge-marker\n' >&2; exit 1 ;;
    *) exit 0 ;;
esac
FAKE
chmod +x "$TEST_ROOT/bin/nebcli"

run_diagnostic() {
    local mode=$1
    shift
    PATH="$TEST_ROOT/bin:$SYSTEM_PATH" NEBCORE_FIXTURE_MODE=$mode bash "$HOOK" "$@"
}

mkdir -p "$TEST_ROOT/empty"
missing=$(PATH="$TEST_ROOT/empty" /bin/bash "$HOOK")
assert_equal 'NebCore AI tools are unavailable because nebcli is not installed. Install nebcli, run nebcli login, then start a new Codex session.' "$missing" missing

old=$(run_diagnostic old)
assert_equal 'NebCore AI tools are unavailable because nebcli 6.12.0 is older than the required 6.13.0. Upgrade nebcli, run nebcli login, then start a new Codex session.' "$old" old

old=$(run_diagnostic leading-old)
assert_equal 'NebCore AI tools are unavailable because nebcli 6.12.0 is older than the required 6.13.0. Upgrade nebcli, run nebcli login, then start a new Codex session.' "$old" leading-old

maximum=$(run_diagnostic component-max)
assert_equal '' "$maximum" component-max

overflow=$(run_diagnostic component-overflow)
assert_equal 'NebCore AI tools are unavailable because the installed nebcli version could not be verified. Upgrade nebcli to 6.13.0 or newer, run nebcli login, then start a new Codex session.' "$overflow" component-overflow

overflow=$(run_diagnostic component-too-long)
assert_equal 'NebCore AI tools are unavailable because the installed nebcli version could not be verified. Upgrade nebcli to 6.13.0 or newer, run nebcli login, then start a new Codex session.' "$overflow" component-too-long

login=$(run_diagnostic login)
assert_equal 'NebCore AI tools are unavailable because nebcli is not logged in. Run nebcli login, then start a new Codex session.' "$login" login

success=$(run_diagnostic success)
assert_equal '' "$success" success

unreadable=$(run_diagnostic unreadable)
assert_equal 'NebCore AI tools are unavailable because the installed nebcli version could not be verified. Upgrade nebcli to 6.13.0 or newer, run nebcli login, then start a new Codex session.' "$unreadable" unreadable
[[ "$unreadable" != *secret-version-marker* ]] || fail 'version output leaked'

unexpected=$(run_diagnostic unexpected)
assert_equal '' "$unexpected" unexpected
[[ "$unexpected" != *secret-bridge-marker* ]] || fail 'bridge output leaked'

overflow=$(run_diagnostic version-overflow)
assert_equal 'NebCore AI tools are unavailable because the installed nebcli version could not be verified. Upgrade nebcli to 6.13.0 or newer, run nebcli login, then start a new Codex session.' "$overflow" version-overflow

overflow=$(run_diagnostic bridge-overflow)
assert_equal 'NebCore AI tools are unavailable because the nebcli prerequisite check did not complete safely. Verify nebcli 6.13.0 or newer, run nebcli login, then start a new Codex session.' "$overflow" bridge-overflow

# shellcheck source=plugins/nebcore-ai/codex/session-start.sh
source "$HOOK"
trap nebcore_child_timeout ALRM
trap nebcore_stream_overflow USR1
trap nebcore_internal_timeout USR2
NEBCORE_FIXTURE_MODE=success nebcore_run_child "$TEST_ROOT/bin/nebcli" version '' --version
assert_equal exit "$nebcore_child_outcome" exact-limit-setup

cat >"$TEST_ROOT/bin/exact-output" <<'EXACT'
#!/bin/bash
dd if=/dev/zero bs="${1:?}" count=1 2>/dev/null | tr '\000' x
EXACT
chmod +x "$TEST_ROOT/bin/exact-output"
nebcore_run_child "$TEST_ROOT/bin/exact-output" version '' 16384
assert_equal exit "$nebcore_child_outcome" exact-limit
assert_equal 32768 "${#nebcore_child_stdout}" exact-limit-retained-hex
nebcore_run_child "$TEST_ROOT/bin/exact-output" version '' 16385
assert_equal overflow "$nebcore_child_outcome" overflow-sentinel
assert_equal 32768 "${#nebcore_child_stdout}" overflow-retained-hex

for stage in version bridge; do
    ready=$TEST_ROOT/$stage-ready
    pid_file=$TEST_ROOT/$stage-pid
    mkfifo "$ready"
    mode=$stage-block
    if [[ $stage == version ]]; then
        output=$(PATH="$TEST_ROOT/bin:$SYSTEM_PATH" NEBCORE_FIXTURE_MODE=$mode NEBCORE_FIXTURE_READY=$ready NEBCORE_FIXTURE_PID=$pid_file bash -c 'source "$1"; nebcore_diagnose "$2" ""' _ "$HOOK" "$ready")
        assert_equal 'NebCore AI tools are unavailable because the installed nebcli version could not be verified. Upgrade nebcli to 6.13.0 or newer, run nebcli login, then start a new Codex session.' "$output" version-deadline
    else
        output=$(PATH="$TEST_ROOT/bin:$SYSTEM_PATH" NEBCORE_FIXTURE_MODE=$mode NEBCORE_FIXTURE_READY=$ready NEBCORE_FIXTURE_PID=$pid_file bash -c 'source "$1"; nebcore_diagnose "" "$2"' _ "$HOOK" "$ready")
        assert_equal 'NebCore AI tools are unavailable because the nebcli prerequisite check did not complete safely. Verify nebcli 6.13.0 or newer, run nebcli login, then start a new Codex session.' "$output" bridge-deadline
    fi
    [[ -s "$pid_file" ]] || fail "$stage fixture did not publish its grandchild"
    assert_gone "$(cat "$pid_file")" "$stage descendant"
done

printf 'PASS: nebcore-ai POSIX prerequisite diagnostics\n'
