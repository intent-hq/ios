#!/usr/bin/env bash
# Self-tests for scripts/xcodebuild.sh: the simulator lock and the
# crash-vs-failure classification of a test run. xcrun and xcodebuild are
# replaced by stubs on PATH, so this runs anywhere with bash (including the
# stock macOS Bash 3.2) and never touches a real simulator.
#
# Usage: scripts/test_xcodebuild.sh
set -euo pipefail

cd "$(dirname "$0")/.."
SCRIPT=$PWD/scripts/xcodebuild.sh

work=$(mktemp -d "${TMPDIR:-/tmp}/xcodebuild-selftest.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
stubs=$work/bin
mkdir -p "$stubs"

cat > "$stubs/xcrun" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# STUB_MODE picks the canned xcodebuild outcome; STUB_SLEEP holds the
# "device" for that many seconds; STUB_LOG records start/end epoch seconds.
cat > "$stubs/xcodebuild" <<'EOF'
#!/usr/bin/env bash
[ -z "${STUB_LOG:-}" ] || echo "start $(date +%s) $$" >> "$STUB_LOG"
sleep "${STUB_SLEEP:-0}"
[ -z "${STUB_LOG:-}" ] || echo "end $(date +%s) $$" >> "$STUB_LOG"
case "${STUB_MODE:-pass}" in
  pass)
    echo "Test Suite 'All tests' passed"
    echo "** TEST EXECUTE SUCCEEDED **"
    exit 0 ;;
  fail)
    echo "Test Suite 'FooTests' started"
    echo "/repo/IntentTests/FooTests.swift:12: error: -[IntentTests.FooTests testBar] : XCTAssertEqual failed"
    echo "Failing tests:"
    echo "	IntentTests:"
    echo "		FooTests.testBar()"
    echo "** TEST EXECUTE FAILED **"
    exit 65 ;;
  crash)
    echo "Test Suite 'AppCoordinatorTests' started"
    echo "Restarting after unexpected exit, crash, or test timeout in IntentTests.AppCoordinatorTests/testBoot(); summary will include totals from previous launches." >&2
    echo "Test Suite 'BackgroundHookStoreTests' started"
    echo "Restarting after unexpected exit, crash, or test timeout in IntentTests.AppCoordinatorTests/testBoot(); summary will include totals from previous launches." >&2
    echo "Failing tests:"
    echo "	IntentTests:"
    echo "		AppCoordinatorTests.testBoot()"
    echo "		BackgroundHookStoreTests.testLoad()"
    echo "Test crashed with signal kill."
    echo "** TEST EXECUTE FAILED **"
    exit 65 ;;
esac
EOF
chmod +x "$stubs/xcrun" "$stubs/xcodebuild"

export PATH="$stubs:$PATH"
export TMPDIR=$work
export SIM_UDID=00000000-0000-0000-0000-000000000001
export SIM_LOCK_DIR=$work/locks
lock=$SIM_LOCK_DIR/xcodebuild-sim-$SIM_UDID.lock

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
assert_contains() {
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1: output lacks '$3'"; printf '%s\n' "$2" | sed 's/^/    | /' ;;
  esac
}
assert_lacks() {
  case "$2" in
    *"$3"*) fail "$1: output unexpectedly contains '$3'" ;;
    *) pass "$1" ;;
  esac
}
# run_wrapper <outfile> <subcommand>: exit status on stdout, output in <outfile>.
run_wrapper() {
  local status=0
  "$SCRIPT" "$2" > "$1" 2>&1 || status=$?
  echo "$status"
}

echo "# passing run"
status=$(STUB_MODE=pass run_wrapper "$work/pass.out" test-without-building)
assert_eq "passing run exits 0" "$status" 0
assert_lacks "passing run prints no crash diagnostic" "$(cat "$work/pass.out")" "crashed or was terminated"
[ ! -L "$lock" ] && pass "lock released after passing run" || fail "lock left behind after passing run"

echo "# failing tests"
status=$(STUB_MODE=fail run_wrapper "$work/fail.out" test-without-building)
assert_eq "failing tests pass xcodebuild's 65 through" "$status" 65
assert_lacks "failing tests are not reported as a crash" "$(cat "$work/fail.out")" "crashed or was terminated"
assert_contains "failing tests keep xcodebuild's own report" "$(cat "$work/fail.out")" "Failing tests:"
[ ! -L "$lock" ] && pass "lock released after failing run" || fail "lock left behind after failing run"

echo "# test-process crash"
status=$(STUB_MODE=crash run_wrapper "$work/crash.out" test-without-building)
out=$(cat "$work/crash.out")
assert_eq "crash exits 80, not 65" "$status" 80
assert_contains "crash prints the distinguishing diagnostic" "$out" "crashed or was terminated (exit 65 is NOT a plain test failure)"
assert_contains "crash names the test that was running" "$out" "IntentTests.AppCoordinatorTests/testBoot()"
assert_contains "crash quotes the signal line" "$out" "Test crashed with signal kill."
assert_contains "crash keeps the full log" "$out" "Full xcodebuild output kept at: $work/xcodebuild-test."
assert_eq "crash diagnostic dedupes repeated restart lines" \
  "$(grep -c 'Restarting after unexpected exit' "$work/crash.out")" 3
[ ! -L "$lock" ] && pass "lock released after crash" || fail "lock left behind after crash"

echo "# two concurrent runs serialize on the simulator lock"
STUB_LOG=$work/timeline
STUB_LOG=$STUB_LOG STUB_SLEEP=3 "$SCRIPT" test-without-building > "$work/a.out" 2>&1 &
a=$!
sleep 1
STUB_LOG=$STUB_LOG STUB_SLEEP=1 "$SCRIPT" test-without-building > "$work/b.out" 2>&1 &
b=$!
wait "$a" && pass "first concurrent run exits 0" || fail "first concurrent run failed"
wait "$b" && pass "second concurrent run exits 0" || fail "second concurrent run failed"
assert_eq "both stub runs completed" "$(grep -c '^end ' "$STUB_LOG")" 2
first_end=$(grep '^end ' "$STUB_LOG" | head -n 1 | cut -d' ' -f2)
second_start=$(grep '^start ' "$STUB_LOG" | tail -n 1 | cut -d' ' -f2)
if [ "$second_start" -ge "$first_end" ]; then
  pass "second run started only after the first released the device"
else
  fail "runs overlapped: second started at $second_start, first ended at $first_end"; cat "$STUB_LOG"
fi
assert_contains "waiter announces who holds the lock" "$(cat "$work/b.out")" "waiting for simulator $SIM_UDID: lock $lock is held by PID"
assert_contains "waiter reports acquisition" "$(cat "$work/b.out")" "acquired simulator lock after"
assert_lacks "holder never waits" "$(cat "$work/a.out")" "waiting for simulator"

echo "# lock timeout"
sleep 30 &
holder=$!
mkdir -p "$SIM_LOCK_DIR"
ln -s "$holder" "$lock"
status=$(SIM_LOCK_TIMEOUT=1 run_wrapper "$work/timeout.out" test-without-building)
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
assert_eq "lock timeout exits 81" "$status" 81
assert_contains "lock timeout names the holder" "$(cat "$work/timeout.out")" "timed out after 1s waiting for simulator $SIM_UDID: lock $lock is held by PID $holder"
assert_contains "lock timeout says how to proceed" "$(cat "$work/timeout.out")" "SIM_LOCK_TIMEOUT"
[ "$(readlink "$lock")" = "$holder" ] && pass "timed-out waiter leaves the holder's lock alone" || fail "timed-out waiter disturbed the lock"
rm -f "$lock"

echo "# stale lock is reclaimed"
true & dead=$!
wait "$dead"
ln -s "$dead" "$lock"
status=$(run_wrapper "$work/stale.out" test-without-building)
assert_eq "stale lock does not block the run" "$status" 0
assert_contains "stale lock reclaim is announced" "$(cat "$work/stale.out")" "reclaiming stale simulator lock $lock (holder PID $dead is gone)"
[ ! -L "$lock" ] && pass "lock released after reclaimed run" || fail "lock left behind after reclaimed run"

echo "# knob validation"
status=$(SIM_LOCK_TIMEOUT=soon run_wrapper "$work/knob.out" test-without-building)
assert_eq "non-numeric SIM_LOCK_TIMEOUT is refused" "$status" 1
assert_contains "non-numeric SIM_LOCK_TIMEOUT names the knob" "$(cat "$work/knob.out")" "SIM_LOCK_TIMEOUT must be a non-negative integer"

echo
if [ "$failures" -eq 0 ]; then
  echo "all xcodebuild.sh self-tests passed"
else
  echo "$failures xcodebuild.sh self-test(s) FAILED" >&2
  exit 1
fi
