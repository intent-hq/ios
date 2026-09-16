#!/usr/bin/env bash
# Self-tests for scripts/xcodebuild.sh: the simulator lock, the
# crash-vs-failure classification of a test run, and the resolution of
# ONLY_TESTING selectors against the enumerated test catalog. xcrun and
# xcodebuild are replaced by stubs on PATH, so this runs anywhere with bash
# (including the stock macOS Bash 3.2) plus python3 (which the lock keeper and
# the resolver need) and never touches a real simulator.
#
# Usage: scripts/test_xcodebuild.sh
set -euo pipefail

cd "$(dirname "$0")/.."
SCRIPT=$PWD/scripts/xcodebuild.sh

work=$(mktemp -d "${TMPDIR:-/tmp}/xcodebuild-selftest.XXXXXX")
# test-ios-unit preflights the gitignored TailcatKit.xcframework; a stand-in
# directory is created for the run and removed again unless it already existed.
tailcatkit=TailcatKit/build/TailcatKit.xcframework
made_tailcatkit=0
trap 'rm -rf -- "$work"; [ "$made_tailcatkit" -eq 0 ] || { rm -rf -- "$tailcatkit"; rmdir TailcatKit/build 2>/dev/null || true; }' EXIT
stubs=$work/bin
mkdir -p "$stubs"

cat > "$stubs/xcrun" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# STUB_MODE picks the canned xcodebuild outcome (marker prints STUB_MARKER as
# the only crash line); STUB_SLEEP holds the "device" for that many seconds;
# STUB_LOG records start/end epoch seconds; STUB_LINGER leaves a detached
# child (like xcodebuild's helper daemons) alive for that many seconds with
# every inherited fd except stdout/stderr still open; STUB_WATCH=<pid> records
# at start whether that peer process is still alive; STUB_RESIST=<secs> spawns
# a child that ignores SIGTERM for that long (logged as "child <pid>") and
# STUB_RESIST_ROOT=1 makes the stub itself ignore SIGTERM. STUB_ARGS records
# every invocation's argv as one "argv: [arg] [arg] ..." line. An
# -enumerate-tests invocation copies $STUB_CATALOG to the requested
# -test-enumeration-output-path and exits 0 (nonzero with STUB_ENUMERATE_FAIL=1)
# without running the canned outcome.
cat > "$stubs/xcodebuild" <<'EOF'
#!/usr/bin/env bash
if [ -n "${STUB_ARGS:-}" ]; then
  { printf 'argv:'; printf ' [%s]' "$@"; echo; } >> "$STUB_ARGS"
fi
case " $* " in
  *" -enumerate-tests "*)
    if [ -n "${STUB_ENUMERATE_FAIL:-}" ]; then
      echo "xcodebuild: error: Unable to enumerate tests (stub)"
      exit 70
    fi
    out=; prev=
    for arg in "$@"; do
      [ "$prev" != "-test-enumeration-output-path" ] || out=$arg
      prev=$arg
    done
    cp "$STUB_CATALOG" "$out"
    exit 0 ;;
esac
[ -z "${STUB_LOG:-}" ] || echo "start $(date +%s) $$" >> "$STUB_LOG"
if [ -n "${STUB_WATCH:-}" ]; then
  if kill -0 "$STUB_WATCH" 2>/dev/null; then echo "peer alive" >> "$STUB_LOG"; else echo "peer dead" >> "$STUB_LOG"; fi
fi
if [ -n "${STUB_RESIST:-}" ]; then
  (trap '' TERM; exec sleep "$STUB_RESIST") &
  [ -z "${STUB_LOG:-}" ] || echo "child $!" >> "$STUB_LOG"
fi
[ -z "${STUB_RESIST_ROOT:-}" ] || trap '' TERM
[ -z "${STUB_LINGER:-}" ] || (sleep "$STUB_LINGER" >/dev/null 2>&1 &)
sleep "${STUB_SLEEP:-0}"
[ -z "${STUB_LOG:-}" ] || echo "end $(date +%s) $$" >> "$STUB_LOG"
case "${STUB_MODE:-pass}" in
  marker)
    echo "Test Suite 'FooTests' started"
    echo "$STUB_MARKER"
    echo "Failing tests:"
    echo "	IntentTests:"
    echo "		FooTests.testBar()"
    echo "** TEST EXECUTE FAILED **"
    exit 65 ;;
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

# The enumerated catalog in xcodebuild's flat JSON shape: an XCTest suite with
# "()" methods, a Swift Testing suite with a parameterised function, a UI
# suite, a look-alike of a suite that does not exist, and one disabled test.
export STUB_CATALOG=$work/catalog.json
cat > "$STUB_CATALOG" <<'EOF'
{
  "errors" : [ ],
  "values" : [
    {
      "testPlan" : "Intent",
      "enabledTests" : [
        { "identifier" : "IntentTests/DemoFixturesTests/testFoo()", "name" : "testFoo()" },
        { "identifier" : "IntentTests/DemoFixturesTests/testBar()", "name" : "testBar()" },
        { "identifier" : "IntentTests/ConversationTranscriptScrollPolicyTests/recoversAfterBlank(width:)", "name" : "recoversAfterBlank(width:)" },
        { "identifier" : "IntentTests/ConversationTranscriptScrollPolicyTests/staysPinnedAtEnd()", "name" : "staysPinnedAtEnd()" },
        { "identifier" : "IntentTests/NewMessagesDividerViewTests/testDividerAppears()", "name" : "testDividerAppears()" },
        { "identifier" : "IntentUITests/ConversationTranscriptScrollUITests/testGoToEndButtonAppears()", "name" : "testGoToEndButtonAppears()" }
      ],
      "disabledTests" : [
        { "identifier" : "IntentTests/QuarantinedDemoTests/flakyOnCI()", "name" : "flakyOnCI()" }
      ]
    }
  ]
}
EOF

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
# run_filtered <name> <ONLY_TESTING> <subcommand> [env...]: exit status on
# stdout, output in $work/<name>.out, the stub's argv lines in $work/<name>.args.
run_filtered() {
  local name=$1 only=$2 sub=$3 status=0
  shift 3
  : > "$work/$name.args"
  env STUB_ARGS="$work/$name.args" ONLY_TESTING="$only" "$@" "$SCRIPT" "$sub" > "$work/$name.out" 2>&1 || status=$?
  echo "$status"
}
# argv_line <name> <n>: the n-th recorded xcodebuild invocation; argv_count <name>.
argv_line() { sed -n "${2}p" "$work/$1.args"; }
argv_count() { grep -c '^argv:' "$work/$1.args" || true; }
# The lock is a flock(2), so "free" means a non-blocking exclusive flock succeeds.
lock_is_free() {
  python3 -c 'import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)' "$lock" 2>/dev/null
}
assert_lock_free() { if lock_is_free; then pass "$1"; else fail "$1: lock still held"; fi; }
# hold_lock: background process that takes the flock, records its own PID as
# the holder (as the wrapper would), and keeps it until killed. Sets $holder.
hold_lock() {
  python3 -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT)
fcntl.flock(fd, fcntl.LOCK_EX)
os.ftruncate(fd, 0); os.write(fd, ("%d\n" % os.getpid()).encode())
open(sys.argv[2], "w").close()
time.sleep(120)' "$lock" "$work/held" &
  holder=$!
  while [ ! -e "$work/held" ]; do sleep 0.1; done
  rm -f "$work/held"
}
# kept_log <outfile>: the retained log path named in a crash diagnostic.
kept_log() { sed -n 's/^Full xcodebuild output kept at: //p' "$1"; }

mkdir -p "$SIM_LOCK_DIR"

echo "# passing run"
status=$(STUB_MODE=pass run_wrapper "$work/pass.out" test-without-building)
assert_eq "passing run exits 0" "$status" 0
assert_lacks "passing run prints no crash diagnostic" "$(cat "$work/pass.out")" "crashed or was terminated"
assert_lock_free "lock released after passing run"
assert_eq "lock file is left empty when free" "$(cat "$lock")" ""
assert_eq "passing run keeps no log" "$(ls "$work" | grep -c '^xcodebuild-test\.')" 0

echo "# failing tests"
status=$(STUB_MODE=fail run_wrapper "$work/fail.out" test-without-building)
assert_eq "failing tests pass xcodebuild's 65 through" "$status" 65
assert_lacks "failing tests are not reported as a crash" "$(cat "$work/fail.out")" "crashed or was terminated"
assert_contains "failing tests keep xcodebuild's own report" "$(cat "$work/fail.out")" "Failing tests:"
assert_lock_free "lock released after failing run"

echo "# test-process crash"
status=$(STUB_MODE=crash run_wrapper "$work/crash.out" test-without-building)
out=$(cat "$work/crash.out")
assert_eq "crash exits 80, not 65" "$status" 80
assert_contains "crash prints the distinguishing diagnostic" "$out" "crashed or was terminated (exit 65 is NOT a plain test failure)"
assert_contains "crash names the test that was running" "$out" "IntentTests.AppCoordinatorTests/testBoot()"
assert_contains "crash quotes the signal line" "$out" "Test crashed with signal kill."
assert_contains "crash keeps the full log" "$out" "Full xcodebuild output kept at: $work/xcodebuild-test."
[ -s "$(kept_log "$work/crash.out")" ] && pass "crash log file exists and is non-empty" || fail "crash log file missing"
assert_eq "crash diagnostic dedupes repeated restart lines" \
  "$(grep -c 'Restarting after unexpected exit' "$work/crash.out")" 3
assert_lock_free "lock released after crash"

echo "# each termination marker alone is classified as a crash"
markers=(
  "Restarting after unexpected exit, crash, or test timeout in IntentTests.FooTests/testBar(); summary will include totals from previous launches."
  "Test crashed with signal segv."
  "Early unexpected exit, operation never finished bootstrapping - no restart will be attempted."
  "Lost connection to the test manager service"
  "Test operation failure: Lost connection to test manager service."
  "Test operation failure: Lost connection to test runner"
  "lost connection to test runner"
  "Test runner exited before starting test execution."
  "Test runner never began executing tests after launching."
  "Test runner crashed before starting test execution."
  "The test runner exited with code 137 before finishing running tests."
)
i=0
for marker in "${markers[@]}"; do
  i=$((i + 1))
  status=$(STUB_MODE=marker STUB_MARKER=$marker run_wrapper "$work/marker$i.out" test-without-building)
  out=$(cat "$work/marker$i.out")
  assert_eq "marker $i exits 80: $marker" "$status" 80
  assert_contains "marker $i is quoted in the diagnostic" "$out" "  $marker"
  [ -s "$(kept_log "$work/marker$i.out")" ] && pass "marker $i keeps the log file" || fail "marker $i: log file missing"
done
status=$(STUB_MODE=marker STUB_MARKER="Test Suite 'Lost connection test' passed" run_wrapper "$work/nomarker.out" test-without-building)
assert_eq "a look-alike line without a marker stays a plain 65" "$status" 65

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

echo "# four competing runs never overlap"
STUB_LOG=$work/timeline4
for n in 1 2 3 4; do
  STUB_LOG=$STUB_LOG STUB_SLEEP=1 "$SCRIPT" test-without-building > "$work/c$n.out" 2>&1 &
  pids[$n]=$!
done
ok=1
for n in 1 2 3 4; do wait "${pids[$n]}" || ok=0; done
assert_eq "all four competing runs exit 0" "$ok" 1
assert_eq "all four stub runs completed" "$(grep -c '^end ' "$STUB_LOG")" 4
overlaps=$(awk '$1 == "start" { if (active) bad++; active = 1 } $1 == "end" { active = 0 } END { print bad + 0 }' "$STUB_LOG")
assert_eq "no stub run started while another was active" "$overlaps" 0

echo "# lock timeout"
hold_lock
status=$(SIM_LOCK_TIMEOUT=1 run_wrapper "$work/timeout.out" test-without-building)
assert_eq "lock timeout exits 81" "$status" 81
assert_contains "lock timeout names the holder" "$(cat "$work/timeout.out")" "timed out after 1s waiting for simulator $SIM_UDID: lock $lock is held by PID $holder"
assert_contains "lock timeout says how to proceed" "$(cat "$work/timeout.out")" "SIM_LOCK_TIMEOUT"
status=$(SIM_LOCK_TIMEOUT=0 run_wrapper "$work/timeout0.out" test-without-building)
assert_eq "SIM_LOCK_TIMEOUT=0 gives up at once" "$status" 81
assert_lacks "SIM_LOCK_TIMEOUT=0 never announces a wait" "$(cat "$work/timeout0.out")" "giving up after"
assert_contains "SIM_LOCK_TIMEOUT=0 still names the holder" "$(cat "$work/timeout0.out")" "lock $lock is held by PID $holder"
lock_is_free && fail "timed-out waiters released the holder's lock" || pass "timed-out waiters leave the holder's lock alone"
assert_eq "timed-out waiters leave the holder's PID record alone" "$(cat "$lock")" "$holder"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true

echo "# a SIGKILLed wrapper takes its running xcodebuild down before the lock is released"
STUB_LOG=$work/timeline-kill
STUB_LOG=$STUB_LOG STUB_SLEEP=60 "$SCRIPT" test-without-building > "$work/victim.out" 2>&1 &
victim=$!
for _ in $(seq 1 100); do grep -q '^start ' "$STUB_LOG" 2>/dev/null && break; sleep 0.1; done
victim_xcodebuild=$(grep '^start ' "$STUB_LOG" | cut -d' ' -f3)
assert_eq "holder records its PID in the lock file" "$(cat "$lock")" "$victim"
[ -n "$victim_xcodebuild" ] && kill -0 "$victim_xcodebuild" && pass "stub xcodebuild is running under the SIGKILL victim" || fail "stub xcodebuild not running"
STUB_LOG=$STUB_LOG STUB_WATCH=$victim_xcodebuild SIM_LOCK_TIMEOUT=30 "$SCRIPT" test-without-building > "$work/afterkill.out" 2>&1 &
waiter=$!
for _ in $(seq 1 100); do grep -q 'waiting for simulator' "$work/afterkill.out" 2>/dev/null && break; sleep 0.1; done
assert_contains "second run is waiting on the victim's lock" "$(cat "$work/afterkill.out")" "held by PID $victim"
kill -9 "$victim"; wait "$victim" 2>/dev/null || true
wait "$waiter" && pass "waiter exits 0 once the orphaned xcodebuild is gone" || fail "waiter failed"
kill -0 "$victim_xcodebuild" 2>/dev/null && fail "orphaned stub xcodebuild $victim_xcodebuild is still alive" || pass "orphaned stub xcodebuild was terminated"
assert_eq "the orphaned stub never reached its end marker" "$(grep -c "^end .* $victim_xcodebuild\$" "$STUB_LOG")" 0
assert_eq "the second run's xcodebuild started only after the orphan was dead" "$(grep -c '^peer dead' "$STUB_LOG")" 1
assert_eq "the second run's xcodebuild never saw the orphan alive" "$(grep -c '^peer alive' "$STUB_LOG")" 0
assert_contains "the keeper reports the termination on the victim's stderr" "$(cat "$work/victim.out")" \
  "PID $victim died while xcodebuild PID $victim_xcodebuild was still running; terminating it before releasing the simulator lock"
assert_lacks "a SIGTERM-responsive run is not escalated to SIGKILL" "$(cat "$work/victim.out")" "sending SIGKILL"
assert_lock_free "lock released after the orphaned run was terminated"
assert_eq "lock file is empty after the orphaned run was terminated" "$(cat "$lock")" ""

# orphan_case <name> <grace> <env...>: SIGKILLs a wrapper whose stub xcodebuild
# (started with <env...>) has a SIGTERM-immune process in its tree, with a
# second run waiting on the lock and watching the stub's "child" PID (or the
# stub itself when no child was logged). Asserts the immune process was
# SIGKILLed after <grace> seconds and was dead before the second run started.
orphan_case() {
  local name=$1 grace=$2 log=$work/timeline-$1 victim waiter root immune
  shift 2
  env STUB_LOG="$log" "$@" "$SCRIPT" test-without-building > "$work/$name.victim.out" 2>&1 &
  victim=$!
  for _ in $(seq 1 100); do grep -q '^start ' "$log" 2>/dev/null && break; sleep 0.1; done
  sleep 0.3
  root=$(grep '^start ' "$log" | cut -d' ' -f3)
  immune=$(grep '^child ' "$log" | cut -d' ' -f2 || true)
  [ -n "$immune" ] || immune=$root
  kill -0 "$immune" 2>/dev/null && pass "$name: SIGTERM-immune PID $immune is running" || fail "$name: no immune process"
  STUB_LOG=$log STUB_WATCH=$immune SIM_LOCK_TIMEOUT=30 "$SCRIPT" test-without-building > "$work/$name.waiter.out" 2>&1 &
  waiter=$!
  for _ in $(seq 1 100); do grep -q 'waiting for simulator' "$work/$name.waiter.out" 2>/dev/null && break; sleep 0.1; done
  kill -9 "$victim"; wait "$victim" 2>/dev/null || true
  wait "$waiter" && pass "$name: waiter exits 0 once the orphaned tree is gone" || fail "$name: waiter failed"
  kill -0 "$root" 2>/dev/null && fail "$name: xcodebuild root PID $root survived the release" || pass "$name: xcodebuild root is gone"
  kill -0 "$immune" 2>/dev/null && fail "$name: immune PID $immune survived the release" || pass "$name: immune process was killed"
  assert_eq "$name: the second run's xcodebuild started only after the immune process was dead" "$(grep -c '^peer dead' "$log")" 1
  assert_eq "$name: the second run's xcodebuild never saw the immune process alive" "$(grep -c '^peer alive' "$log")" 0
  assert_contains "$name: the keeper reports the SIGKILL escalation" "$(cat "$work/$name.victim.out")" "ignored SIGTERM for ${grace}s; sending SIGKILL"
  assert_lock_free "$name: lock released after the escalation"
}

echo "# a SIGTERM-responsive xcodebuild with a SIGTERM-immune child: the child is waited for and SIGKILLed"
orphan_case resistant-child 1 SIM_LOCK_KILL_GRACE=1 STUB_SLEEP=60 STUB_RESIST=60

echo "# a SIGTERM-immune xcodebuild itself is SIGKILLed after the grace period"
orphan_case resistant-root 1 SIM_LOCK_KILL_GRACE=1 STUB_SLEEP=60 STUB_RESIST_ROOT=1

echo "# a SIGKILLed wrapper whose xcodebuild already returned terminates nothing"
STUB_LOG=$work/timeline-kill2
STUB_LOG=$STUB_LOG STUB_LINGER=15 "$SCRIPT" test-without-building > "$work/victim2.out" 2>&1 &
victim=$!
for _ in $(seq 1 100); do grep -q '^end ' "$STUB_LOG" 2>/dev/null && break; sleep 0.1; done
kill -9 "$victim" 2>/dev/null || true; wait "$victim" 2>/dev/null || true
assert_lacks "no termination is reported when xcodebuild had finished" "$(cat "$work/victim2.out")" "terminating it before releasing"
status=$(SIM_LOCK_TIMEOUT=5 run_wrapper "$work/afterkill2.out" test-without-building)
assert_eq "next run proceeds after the finished holder was SIGKILLed" "$status" 0

echo "# a leftover PID in an unlocked file is not a lock"
true & dead=$!
wait "$dead"
echo "$dead" > "$lock"
status=$(SIM_LOCK_TIMEOUT=0 run_wrapper "$work/stale.out" test-without-building)
assert_eq "an unlocked file with a stale PID does not block the run" "$status" 0
assert_lacks "no wait is announced for an unlocked file" "$(cat "$work/stale.out")" "waiting for simulator"
assert_eq "the stale PID is cleared after the run" "$(cat "$lock")" ""

echo "# a child that outlives xcodebuild does not keep the lock"
status=$(STUB_LINGER=15 run_wrapper "$work/linger.out" test-without-building)
assert_eq "run whose xcodebuild leaves a lingering child exits 0" "$status" 0
assert_lock_free "lock is free while the lingering child is still alive"
status=$(SIM_LOCK_TIMEOUT=0 run_wrapper "$work/afterlinger.out" test-without-building)
assert_eq "next run proceeds at once despite the lingering child" "$status" 0

echo "# knob validation"
status=$(SIM_LOCK_TIMEOUT=soon run_wrapper "$work/knob.out" test-without-building)
assert_eq "non-numeric SIM_LOCK_TIMEOUT is refused" "$status" 1
assert_contains "non-numeric SIM_LOCK_TIMEOUT names the knob" "$(cat "$work/knob.out")" "SIM_LOCK_TIMEOUT must be a non-negative integer"
status=$(SIM_LOCK_KILL_GRACE=-1 run_wrapper "$work/knob2.out" test-without-building)
assert_eq "non-numeric SIM_LOCK_KILL_GRACE is refused" "$status" 1
assert_contains "non-numeric SIM_LOCK_KILL_GRACE names the knob" "$(cat "$work/knob2.out")" "SIM_LOCK_KILL_GRACE must be a non-negative integer"

echo "# empty ONLY_TESTING: no enumeration, xcodebuild argv unchanged"
status=$(run_filtered plain "" test-without-building)
assert_eq "empty ONLY_TESTING exits 0" "$status" 0
assert_eq "empty ONLY_TESTING makes exactly one xcodebuild call" "$(argv_count plain)" 1
assert_eq "empty ONLY_TESTING leaves the argv byte-identical" "$(argv_line plain 1)" \
  "argv: [test-without-building] [-project] [Intent.xcodeproj] [-scheme] [Intent] [-destination] [platform=iOS Simulator,id=$SIM_UDID] [-parallel-testing-enabled] [NO]"
assert_lacks "empty ONLY_TESTING prints no resolution notice" "$(cat "$work/plain.out")" "ONLY_TESTING"

echo "# a target-wide selector resolves; enumeration precedes the real run"
status=$(run_filtered target "IntentTests" test-without-building)
assert_eq "target-wide selector exits 0" "$status" 0
assert_eq "filtered run makes an enumeration call and a test call" "$(argv_count target)" 2
enum=$(argv_line target 1)
real=$(argv_line target 2)
assert_contains "enumeration uses the same project and destination" "$enum" \
  "argv: [test-without-building] [-project] [Intent.xcodeproj] [-scheme] [Intent] [-destination] [platform=iOS Simulator,id=$SIM_UDID]"
assert_contains "enumeration asks for a flat json catalog" "$enum" \
  "[-enumerate-tests] [-test-enumeration-style] [flat] [-test-enumeration-format] [json] [-test-enumeration-output-path] [$work/xcodebuild-enumerate."
assert_lacks "enumeration carries no -only-testing:" "$enum" "-only-testing:"
assert_lacks "enumeration is not a real test run" "$enum" "-parallel-testing-enabled"
assert_eq "the real run keeps the unfiltered argv plus the selector" "$real" \
  "argv: [test-without-building] [-project] [Intent.xcodeproj] [-scheme] [Intent] [-destination] [platform=iOS Simulator,id=$SIM_UDID] [-parallel-testing-enabled] [NO] [-only-testing:IntentTests]"
assert_contains "target-wide selector reports its resolved count" "$(cat "$work/target.out")" "ONLY_TESTING: IntentTests -> 5 test(s)"
assert_lock_free "lock released after a resolved filtered run"
assert_eq "enumeration scratch files are removed" "$(ls "$work" | grep -c '^xcodebuild-enumerate\.')" 0

echo "# Target/Class selectors resolve for XCTest and Swift Testing suites"
status=$(run_filtered xctest "IntentTests/DemoFixturesTests" test-without-building)
assert_eq "XCTest suite selector exits 0" "$status" 0
assert_contains "XCTest suite selector resolves its () methods" "$(cat "$work/xctest.out")" "ONLY_TESTING: IntentTests/DemoFixturesTests -> 2 test(s)"
status=$(run_filtered swifttesting "IntentTests/ConversationTranscriptScrollPolicyTests" test-without-building)
assert_eq "Swift Testing suite selector exits 0" "$status" 0
assert_contains "Swift Testing suite selector resolves its functions" "$(cat "$work/swifttesting.out")" "ONLY_TESTING: IntentTests/ConversationTranscriptScrollPolicyTests -> 2 test(s)"

echo "# method selectors resolve with and without () or a parameter list"
methods="IntentTests/DemoFixturesTests/testFoo IntentTests/DemoFixturesTests/testBar() IntentTests/ConversationTranscriptScrollPolicyTests/recoversAfterBlank IntentTests/ConversationTranscriptScrollPolicyTests/recoversAfterBlank(width:)"
status=$(run_filtered methods "$methods" test-without-building)
out=$(cat "$work/methods.out")
assert_eq "method selectors exit 0" "$status" 0
assert_contains "bare XCTest method matches testFoo()" "$out" "ONLY_TESTING: IntentTests/DemoFixturesTests/testFoo -> 1 test(s)"
assert_contains "XCTest method with () matches" "$out" "ONLY_TESTING: IntentTests/DemoFixturesTests/testBar() -> 1 test(s)"
assert_contains "bare Swift Testing function matches its parameterised identifier" "$out" "ONLY_TESTING: IntentTests/ConversationTranscriptScrollPolicyTests/recoversAfterBlank -> 1 test(s)"
assert_contains "Swift Testing function with parameter list matches" "$out" "ONLY_TESTING: IntentTests/ConversationTranscriptScrollPolicyTests/recoversAfterBlank(width:) -> 1 test(s)"
real=$(argv_line methods 2)
for id in $methods; do
  assert_contains "the real run carries -only-testing:$id" "$real" "[-only-testing:$id]"
done
status=$(run_filtered wrongparams "IntentTests/ConversationTranscriptScrollPolicyTests/recoversAfterBlank(height:)" test-without-building)
assert_eq "a method selector with the wrong parameter list exits 82" "$status" 82

echo "# a file-name or typo selector exits 82 with the look-alike suite"
status=$(run_filtered typo "IntentTests/NewMessagesDividerTests" test-without-building)
out=$(cat "$work/typo.out")
assert_eq "unmatched selector exits 82" "$status" 82
assert_contains "unmatched selector is named" "$out" "ONLY_TESTING selector 'IntentTests/NewMessagesDividerTests' matched no test in the enumerated catalog"
assert_contains "unmatched selector gets the look-alike suite suggested" "$out" "did you mean: IntentTests/NewMessagesDividerViewTests"
assert_contains "unmatched selector gets the Target/Suite reminder" "$out" "not a file name"
assert_contains "unmatched selector says the run was not started" "$out" "the test run was not started"
assert_contains "unmatched selector names the exit code" "$out" "Exiting 82 (unmatched ONLY_TESTING selector)"
assert_eq "unmatched selector never starts the real run" "$(argv_count typo)" 1
assert_lacks "unmatched selector passes no -only-testing: to xcodebuild" "$(cat "$work/typo.args")" "-only-testing:"
assert_lock_free "lock released after an unmatched selector"
status=$(run_filtered filename "IntentTests/NewMessagesDividerViewTests.swift" test-without-building)
assert_eq "a .swift file name exits 82" "$status" 82
assert_contains "a .swift file name gets the suite suggested" "$(cat "$work/filename.out")" "did you mean: IntentTests/NewMessagesDividerViewTests"

echo "# a valid selector does not rescue an unmatched one"
status=$(run_filtered mixed "IntentTests/TranscriptScrollPolicyTests IntentUITests/ConversationTranscriptScrollUITests" test-without-building)
out=$(cat "$work/mixed.out")
assert_eq "mixed valid and unmatched selectors exit 82" "$status" 82
assert_contains "the unmatched selector is named" "$out" "'IntentTests/TranscriptScrollPolicyTests' matched no test"
assert_contains "the unmatched selector gets the policy suite suggested" "$out" "did you mean: IntentTests/ConversationTranscriptScrollPolicyTests"
assert_contains "the valid UI selector is reported as resolved" "$out" "ONLY_TESTING: IntentUITests/ConversationTranscriptScrollUITests -> 1 test(s)"
assert_lacks "the valid UI selector is not reported as unmatched" "$out" "'IntentUITests/ConversationTranscriptScrollUITests' matched"
assert_eq "mixed selectors never start the real run" "$(argv_count mixed)" 1
assert_lock_free "lock released after mixed selectors"

echo "# a selector matching only disabled tests exits 82"
status=$(run_filtered disabled "IntentTests/QuarantinedDemoTests" test-without-building)
assert_eq "only-disabled selector exits 82" "$status" 82
assert_contains "only-disabled selector says so" "$(cat "$work/disabled.out")" "ONLY_TESTING selector 'IntentTests/QuarantinedDemoTests' matched only disabled tests (1, e.g. IntentTests/QuarantinedDemoTests/flakyOnCI())"
assert_eq "only-disabled selector never starts the real run" "$(argv_count disabled)" 1

echo "# duplicate selectors collapse; a shadowed selector is still resolved"
status=$(run_filtered dupes "IntentTests IntentTests/DemoFixturesTests IntentTests" test-without-building)
out=$(cat "$work/dupes.out")
assert_eq "duplicate selectors exit 0" "$status" 0
assert_eq "a duplicate selector is resolved once" "$(grep -c '^ONLY_TESTING: IntentTests ->' "$work/dupes.out")" 1
assert_contains "the shadowed selector is resolved individually" "$out" "ONLY_TESTING: IntentTests/DemoFixturesTests -> 2 test(s)"
assert_eq "a duplicate selector is forwarded once" "$(argv_line dupes 2 | grep -o '\[-only-testing:IntentTests\]' | grep -c .)" 1
assert_contains "the shadowed selector is still forwarded" "$(argv_line dupes 2)" "[-only-testing:IntentTests/DemoFixturesTests]"

echo "# a failed or unparsable enumeration exits 83"
status=$(run_filtered enumfail "IntentTests" test-without-building STUB_ENUMERATE_FAIL=1)
out=$(cat "$work/enumfail.out")
assert_eq "failed enumeration exits 83" "$status" 83
assert_contains "failed enumeration says the selection is unverified" "$out" "could not verify the ONLY_TESTING selection: xcodebuild -enumerate-tests exited 70"
assert_contains "failed enumeration names the exit code" "$out" "Exiting 83 (test selection unverified), not 70"
assert_eq "failed enumeration never starts the real run" "$(argv_count enumfail)" 1
assert_lock_free "lock released after a failed enumeration"
echo "not json" > "$work/garbage.json"
status=$(run_filtered garbage "IntentTests" test-without-building STUB_CATALOG="$work/garbage.json")
assert_eq "unparsable catalog exits 83" "$status" 83
assert_contains "unparsable catalog is reported" "$(cat "$work/garbage.out")" "could not verify the ONLY_TESTING selection: the test enumeration output is unreadable"
assert_eq "unparsable catalog never starts the real run" "$(argv_count garbage)" 1
echo '{ "errors" : [ ], "values" : [ ] }' > "$work/empty.json"
status=$(run_filtered emptycatalog "IntentTests" test-without-building STUB_CATALOG="$work/empty.json")
assert_eq "catalog without tests exits 83" "$status" 83
assert_contains "catalog without tests is reported" "$(cat "$work/emptycatalog.out")" "the test enumeration output lists no tests"
assert_lock_free "lock released after an unparsable catalog"

echo "# a flag-like entry is refused before any xcodebuild call"
status=$(run_filtered flaglike "IntentTests -sdk" test-without-building)
assert_eq "flag-like entry exits 1" "$status" 1
assert_contains "flag-like entry is named" "$(cat "$work/flaglike.out")" "ONLY_TESTING entry '-sdk' looks like a flag"
assert_eq "flag-like entry makes no xcodebuild call" "$(argv_count flaglike)" 0

echo "# test-ios-unit: enumeration carries -skip-testing:, a skipped selector exits 82"
if [ ! -d "$tailcatkit" ]; then
  mkdir -p "$tailcatkit"
  made_tailcatkit=1
fi
status=$(run_filtered unitskip "IntentUITests/ConversationTranscriptScrollUITests" test-ios-unit)
out=$(cat "$work/unitskip.out")
assert_eq "UI selector under test-ios-unit exits 82" "$status" 82
assert_contains "UI selector under test-ios-unit names the exclusion" "$out" \
  "ONLY_TESTING selector 'IntentUITests/ConversationTranscriptScrollUITests' is excluded by -skip-testing:IntentUITests on this subcommand"
assert_eq "test-ios-unit builds, enumerates, and stops" "$(argv_count unitskip)" 2
assert_contains "test-ios-unit builds first" "$(argv_line unitskip 1)" "argv: [build-for-testing]"
enum=$(argv_line unitskip 2)
assert_contains "test-ios-unit enumeration carries -skip-testing:IntentUITests" "$enum" "[-enumerate-tests] [-test-enumeration-style] [flat] [-test-enumeration-format] [json] [-test-enumeration-output-path] [$work/xcodebuild-enumerate."
assert_contains "test-ios-unit enumeration ends with the skip flag" "$enum" "] [-skip-testing:IntentUITests]"
assert_lacks "test-ios-unit enumeration carries no -only-testing:" "$enum" "-only-testing:"
assert_lock_free "lock released after a skipped selector"
status=$(run_filtered unitok "IntentTests/DemoFixturesTests" test-ios-unit)
assert_eq "unit selector under test-ios-unit exits 0" "$status" 0
assert_eq "test-ios-unit builds, enumerates, and runs" "$(argv_count unitok)" 3
assert_contains "test-ios-unit real run carries the selector and the skip flag" "$(argv_line unitok 3)" \
  "[-parallel-testing-enabled] [NO] [-only-testing:IntentTests/DemoFixturesTests] [-skip-testing:IntentUITests]"

echo
if [ "$failures" -eq 0 ]; then
  echo "all xcodebuild.sh self-tests passed"
else
  echo "$failures xcodebuild.sh self-test(s) FAILED" >&2
  exit 1
fi
