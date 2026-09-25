#!/usr/bin/env bash
# Self-tests for scripts/xcodebuild.sh: the simulator lock, the
# crash-vs-failure classification of a test run, the resolution of
# ONLY_TESTING selectors against the enumerated test catalog, explicit build
# configuration, and the per-selector summary read back from the result bundle. xcrun and
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

# xcrun records its argv as "xcrun: [arg] ..." lines in STUB_ARGS; an
# xcresulttool test-results query prints $STUB_RESULTS (fixture JSON; a
# "-retry" bundle path prints $STUB_RESULTS_RETRY when set) or fails under
# STUB_RESULTS_FAIL=1; every other invocation (simctl) exits 0.
cat > "$stubs/xcrun" <<'EOF'
#!/usr/bin/env bash
if [ -n "${STUB_ARGS:-}" ]; then
  { printf 'xcrun:'; printf ' [%s]' "$@"; echo; } >> "$STUB_ARGS"
fi
case " $* " in
  *" xcresulttool get test-results tests --path "*)
    if [ -n "${STUB_RESULTS_FAIL:-}" ]; then
      echo "Error: the result bundle could not be opened (stub)" >&2
      exit 1
    fi
    case " $* " in
      *"-retry"*) cat "${STUB_RESULTS_RETRY:-$STUB_RESULTS}" ;;
      *) cat "$STUB_RESULTS" ;;
    esac ;;
esac
exit 0
EOF

# STUB_MODE picks the canned xcodebuild outcome (marker prints STUB_MARKER as
# the only crash line; pass prints STUB_PREAMBLE first when set); with
# STUB_THEN=<mode> and STUB_STATE=<file>, the first test invocation uses
# STUB_MODE and creates the file, every later one uses STUB_THEN; STUB_SLEEP
# holds the "device" for that many seconds; STUB_LOG records start/end epoch
# seconds; STUB_LINGER leaves a detached child (like xcodebuild's helper
# daemons) alive for that many seconds with every inherited fd except
# stdout/stderr still open; STUB_WATCH=<pid> records at start whether that
# peer process is still alive; STUB_RESIST=<secs> spawns a child that ignores
# SIGTERM for that long (logged as "child <pid>") and STUB_RESIST_ROOT=1 makes
# the stub itself ignore SIGTERM. STUB_ARGS records every invocation's argv as
# one "argv: [arg] [arg] ..." line. STUB_NO_FAILING=1 drops the "Failing
# tests" list from the marker outcome; STUB_FLAT_FAILING=1 prints it in the
# flat single-tab form (fully qualified entries, no target header) instead of
# the grouped one. A -resultBundlePath is created as a
# directory (not under STUB_NO_BUNDLE=1). An -enumerate-tests invocation
# copies $STUB_CATALOG to the requested -test-enumeration-output-path and
# exits 0 (nonzero with STUB_ENUMERATE_FAIL=1) without running the canned
# outcome.
cat > "$stubs/xcodebuild" <<'EOF'
#!/usr/bin/env bash
if [ -n "${STUB_ARGS:-}" ]; then
  { printf 'argv:'; printf ' [%s]' "$@"; echo; } >> "$STUB_ARGS"
fi
prev=
for arg in "$@"; do
  [ "$prev" != "-resultBundlePath" ] || [ -n "${STUB_NO_BUNDLE:-}" ] || mkdir -p "$arg"
  prev=$arg
done
case " $* " in
  *" -showsdks "*) echo "Simulator - iOS -sdk iphonesimulator"; echo "Simulator - visionOS -sdk xrsimulator"; exit 0 ;;
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
mode=${STUB_MODE:-pass}
if [ -n "${STUB_THEN:-}" ]; then
  if [ -e "$STUB_STATE" ]; then mode=$STUB_THEN; else : > "$STUB_STATE"; fi
fi
case "$mode" in
  marker)
    echo "Test Suite 'FooTests' started"
    echo "$STUB_MARKER"
    if [ -n "${STUB_FLAT_FAILING:-}" ]; then
      echo "Failing tests:"
      echo "	IntentTests.FooTests/testBar()"
      echo "	IntentTests.DemoFixturesTests.testQux()"
    elif [ -z "${STUB_NO_FAILING:-}" ]; then
      echo "Failing tests:"
      echo "	IntentTests:"
      echo "		FooTests.testBar()"
    fi
    echo "** TEST EXECUTE FAILED **"
    exit 65 ;;
  pass)
    [ -z "${STUB_PREAMBLE:-}" ] || echo "$STUB_PREAMBLE"
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

# make_results <file> <Target/Suite/test=Result>...: writes the document
# xcrun xcresulttool get test-results tests prints (Xcode 16 shape: a Test
# Plan node, one Unit/UI test bundle node per target, Test Suite nodes, and
# Test Case leaves identified as Suite/test with a result).
make_results() {
  python3 - "$@" <<'EOF'
import json, sys
out, bundles = sys.argv[1], {}
for spec in sys.argv[2:]:
    ident, result = spec.rsplit("=", 1)
    target, suite, test = ident.split("/", 2)
    bundles.setdefault(target, {}).setdefault(suite, []).append((test, result))
targets = []
for target, suites in bundles.items():
    kind = "UI test bundle" if target.endswith("UITests") else "Unit test bundle"
    children = [{"name": suite, "nodeType": "Test Suite", "nodeIdentifier": suite, "result": "Passed", "children": [
        {"name": test, "nodeType": "Test Case", "nodeIdentifier": suite + "/" + test, "result": result, "duration": "0.001s"}
        for test, result in tests]} for suite, tests in suites.items()]
    targets.append({"name": target, "nodeType": kind, "result": "Passed", "children": children})
doc = {"devices": [{"deviceName": "iPhone 16", "platform": "iOS Simulator"}],
       "testNodes": [{"name": "Intent", "nodeType": "Test Plan", "result": "Passed", "children": targets}],
       "testPlanConfigurations": [{"configurationId": "1", "configurationName": "Test Scheme Action"}]}
with open(out, "w") as f:
    json.dump(doc, f, indent=2)
EOF
}
# The default result bundle: every enabled test of the catalog passed.
export STUB_RESULTS=$work/results.json
make_results "$STUB_RESULTS" \
  "IntentTests/DemoFixturesTests/testFoo()=Passed" \
  "IntentTests/DemoFixturesTests/testBar()=Passed" \
  "IntentTests/ConversationTranscriptScrollPolicyTests/recoversAfterBlank(width:)=Passed" \
  "IntentTests/ConversationTranscriptScrollPolicyTests/staysPinnedAtEnd()=Passed" \
  "IntentTests/NewMessagesDividerViewTests/testDividerAppears()=Passed" \
  "IntentUITests/ConversationTranscriptScrollUITests/testGoToEndButtonAppears()=Passed"

export PATH="$stubs:$PATH"
export TMPDIR=$work
# The wrapper appends to a caller's step summary; the self-test's own CI job
# must not receive the fixture tables.
unset GITHUB_STEP_SUMMARY RESULT_BUNDLE ONLY_TESTING BUILD_CONFIGURATION UI_TEST_SHARD UI_TEST_SHARD_COUNT
unset TEST_ARTIFACT_PATH TEST_ARTIFACT_RUN TEST_ARTIFACT_REVISION TEST_ARTIFACT_SHA256 TEST_SELECTION_REPORT
unset CI_PHASE_TIMING PRODUCER_DISCOVERY_PROBE
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
# argv_line <name> <n>: the n-th recorded xcodebuild invocation; argv_count <name>;
# xcresulttool_count <name>: recorded xcrun xcresulttool queries.
argv_line() { grep '^argv:' "$work/$1.args" | sed -n "${2}p"; }
argv_count() { grep -c '^argv:' "$work/$1.args" || true; }
xcresulttool_count() { grep -c '^xcrun: \[xcresulttool\]' "$work/$1.args" || true; }
# temp_bundles: temporary result bundle directories left in $work.
temp_bundles() { ls "$work" | grep -c '^xcodebuild-result\.' || true; }
# kept_bundle <outfile>: the retained result bundle path named in a diagnostic.
kept_bundle() { sed -n 's/^Result bundle kept at: //p' "$1"; }
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
# kept_log <outfile>: the retained log path named in the first crash diagnostic.
kept_log() { sed -n 's/^Full xcodebuild output kept at: //p' "$1" | head -n 1; }
# retry_argv <name>: the recorded re-run, i.e. the second real test invocation
# (enumeration calls excluded).
retry_argv() { grep '^argv:' "$work/$1.args" | grep -v -- '-enumerate-tests' | sed -n '2p'; }

mkdir -p "$SIM_LOCK_DIR"

echo "# passing run"
status=$(STUB_MODE=pass run_wrapper "$work/pass.out" test-without-building)
assert_eq "passing run exits 0" "$status" 0
assert_lacks "passing run prints no crash diagnostic" "$(cat "$work/pass.out")" "crashed or was terminated"
assert_lock_free "lock released after passing run"
assert_eq "lock file is left empty when free" "$(cat "$lock")" ""
assert_eq "passing run keeps no log" "$(ls "$work" | grep -c '^xcodebuild-test\.')" 0
assert_lacks "phase timing is off by default" "$(cat "$work/pass.out")" "ci-phase"

echo "# opt-in phase boundaries preserve outcomes and keep markers off stdout"
for scenario in pass enumeration result selector tests; do
  knobs=(); expected=0; only=IntentTests/DemoFixturesTests
  case "$scenario" in
    enumeration) knobs+=(STUB_ENUMERATE_FAIL=1); expected=83 ;;
    result) knobs+=(STUB_RESULTS_FAIL=1); expected=83 ;;
    selector) only=IntentTests/DoesNotExist; expected=82 ;;
    tests) knobs+=(STUB_MODE=fail); expected=65 ;;
  esac
  status=0
  env CI_PHASE_TIMING=1 ONLY_TESTING="$only" STUB_SLEEP=0.1 RESULT_BUNDLE="$work/timing-$scenario.xcresult" ${knobs+"${knobs[@]}"} \
    "$SCRIPT" test-without-building > "$work/timing-$scenario.stdout" 2> "$work/timing-$scenario.stderr" || status=$?
  assert_eq "$scenario timing preserves exit" "$status" "$expected"
  assert_lock_free "$scenario timing releases the lock"
done
if python3 - "$work" <<'EOF'
import pathlib, re, sys
work = pathlib.Path(sys.argv[1])
for scenario in ('pass', 'enumeration', 'result', 'selector', 'tests'):
    assert 'ci-phase' not in (work / ('timing-' + scenario + '.stdout')).read_text()
    rows = [line for line in (work / ('timing-' + scenario + '.stderr')).read_text().splitlines()
            if line.startswith('ci-phase')]
    expected = [('simulator_readiness', 'success'), ('consumer_discovery',
                'failure' if scenario == 'enumeration' else 'success')]
    if scenario not in ('enumeration', 'selector'):
        expected += [('test_process', 'failure' if scenario == 'tests' else 'success'),
                     ('result_verification', 'failure' if scenario == 'result' else 'success')]
    actual = []
    for line in rows:
        match = re.fullmatch(r'ci-phase phase=([a-z_]+) outcome=(success|failure) elapsed_seconds=([0-9]+\.[0-9]{6})', line)
        assert match, line
        actual.append(match.group(1, 2))
        if match[1] == 'test_process':
            assert float(match[3]) >= 0.1, line
    assert actual == expected, (scenario, actual, expected)
EOF
then pass "timing markers have only fixed names, outcomes and elapsed seconds at actual phase boundaries"
else fail "timing marker contract"; fi

echo "# optional timer failure cannot gate or hide a failed operation"
real_python=$(command -v python3)
mkdir "$work/broken-timer"
cat > "$work/broken-timer/python3" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = scripts/ci_phase.py ]; then exit 7; fi
exec "$real_python" "\$@"
EOF
chmod +x "$work/broken-timer/python3"
for mode in pass fail; do
  expected=0; [ "$mode" != fail ] || expected=65
  status=$(PATH="$work/broken-timer:$PATH" CI_PHASE_TIMING=1 STUB_MODE="$mode" run_wrapper "$work/broken-$mode.out" test-without-building)
  assert_eq "timer failure preserves $mode operation" "$status" "$expected"
  assert_lacks "failed timer does not invent success" "$(cat "$work/broken-$mode.out")" "ci-phase"
done

echo "# failing tests"
status=$(STUB_MODE=fail run_wrapper "$work/fail.out" test-without-building)
assert_eq "failing tests pass xcodebuild's 65 through" "$status" 65
assert_lacks "failing tests are not reported as a crash" "$(cat "$work/fail.out")" "crashed or was terminated"
assert_contains "failing tests keep xcodebuild's own report" "$(cat "$work/fail.out")" "Failing tests:"
assert_lock_free "lock released after failing run"

echo "# test-process crash (the re-run crashes too: exactly one retry, exit 80)"
status=$(run_filtered crash "" test-without-building STUB_MODE=crash)
out=$(cat "$work/crash.out")
assert_eq "crash exits 80, not 65" "$status" 80
assert_contains "crash prints the distinguishing diagnostic" "$out" "crashed or was terminated (exit 65 is NOT a plain test failure)"
assert_contains "crash names the test that was running" "$out" "IntentTests.AppCoordinatorTests/testBoot()"
assert_contains "crash quotes the signal line" "$out" "Test crashed with signal kill."
assert_contains "crash keeps the full log" "$out" "Full xcodebuild output kept at: $work/xcodebuild-test."
[ -s "$(kept_log "$work/crash.out")" ] && pass "crash log file exists and is non-empty" || fail "crash log file missing"
assert_eq "crash diagnostic dedupes repeated restart lines (primary run and re-run)" \
  "$(grep -c 'Restarting after unexpected exit' "$work/crash.out")" 6
assert_eq "a crash is retried exactly once" "$(argv_count crash)" 2
assert_contains "the re-run is scoped to the interrupted suites" "$(argv_line crash 2)" \
  "[-parallel-testing-enabled] [NO] [-only-testing:IntentTests/AppCoordinatorTests] [-only-testing:IntentTests/BackgroundHookStoreTests]"
assert_contains "a re-run that crashes again is reported" "$out" "crashed as well; not retrying again"
assert_contains "a re-run that crashes again exits 80" "$out" "Exiting 80 (test-process crash), not 65"
assert_lock_free "lock released after crash"

echo "# a crashed suite is re-run once and the run is green when it passes"
rm -f -- "$work"/xcodebuild-retry.*
: > "$work/step-summary-crash.md"
status=$(run_filtered crashpass "" test-without-building STUB_MODE=crash STUB_THEN=pass STUB_STATE="$work/crashpass.state" \
  GITHUB_STEP_SUMMARY="$work/step-summary-crash.md")
out=$(cat "$work/crashpass.out")
assert_eq "crash then green re-run exits 0" "$status" 0
assert_eq "crash then green re-run makes two xcodebuild calls" "$(argv_count crashpass)" 2
assert_eq "the re-run keeps the destination and adds only the interrupted suites" "$(argv_line crashpass 2)" \
  "argv: [test-without-building] [-project] [Intent.xcodeproj] [-scheme] [Intent] [-destination] [platform=iOS Simulator,id=$SIM_UDID] [-parallel-testing-enabled] [NO] [-only-testing:IntentTests/AppCoordinatorTests] [-only-testing:IntentTests/BackgroundHookStoreTests]"
assert_contains "the crash signature is still printed" "$out" "crashed or was terminated (exit 65 is NOT a plain test failure)"
assert_contains "the re-run is announced with its suites" "$out" \
  "re-running the interrupted suite(s) once, alone: IntentTests/AppCoordinatorTests IntentTests/BackgroundHookStoreTests"
assert_contains "the merged verdict is printed" "$out" "the re-run of IntentTests/AppCoordinatorTests IntentTests/BackgroundHookStoreTests passed"
assert_contains "the crash log is kept after a green re-run" "$out" "Full xcodebuild output kept at: $work/xcodebuild-test."
[ -s "$(kept_log "$work/crashpass.out")" ] && pass "the kept crash log exists after a green re-run" || fail "crash log missing after a green re-run"
assert_eq "a green re-run keeps no log of its own" "$(ls "$work" | grep -c '^xcodebuild-retry\.')" 0
summary_md=$(cat "$work/step-summary-crash.md")
assert_contains "the job summary records the restart" "$summary_md" "### Test-runner restart (this run)"
assert_contains "the job summary quotes the crash line" "$summary_md" \
  "Restarting after unexpected exit, crash, or test timeout in IntentTests.AppCoordinatorTests/testBoot()"
assert_contains "the job summary quotes the signal line" "$summary_md" "Test crashed with signal kill."
assert_contains "the job summary records the re-run verdict" "$summary_md" \
  'Re-ran once, alone: `IntentTests/AppCoordinatorTests IntentTests/BackgroundHookStoreTests` — passed; the run is green (exit 0).'
assert_lock_free "lock released after a green re-run"

echo "# a crash without a step summary still prints the signature; a failing re-run keeps 65"
status=$(run_filtered crashfail "" test-without-building STUB_MODE=crash STUB_THEN=fail STUB_STATE="$work/crashfail.state")
out=$(cat "$work/crashfail.out")
assert_eq "crash then failing re-run exits 65" "$status" 65
assert_eq "crash then failing re-run makes two xcodebuild calls" "$(argv_count crashfail)" 2
assert_contains "the failing re-run is reported as real failures" "$out" "failed (exit 65) without a crash: these are real test failures"
assert_contains "the failing re-run keeps xcodebuild's own report" "$out" "Failing tests:"
assert_lacks "the failing re-run is not classified as a crash" "$out" "crashed as well"
assert_eq "a failing re-run keeps no re-run log (its failure is not a crash)" "$(ls "$work" | grep -c '^xcodebuild-retry\.')" 0

echo "# TEST_CRASH_RETRY=0 disables the re-run"
status=$(run_filtered noretry "" test-without-building STUB_MODE=crash STUB_THEN=pass STUB_STATE="$work/noretry.state" TEST_CRASH_RETRY=0)
assert_eq "TEST_CRASH_RETRY=0 exits 80" "$status" 80
assert_eq "TEST_CRASH_RETRY=0 makes one xcodebuild call" "$(argv_count noretry)" 1
assert_contains "TEST_CRASH_RETRY=0 says why" "$(cat "$work/noretry.out")" "TEST_CRASH_RETRY=0: not re-running"

echo "# a crash line without a test name falls back to the Failing tests list"
status=$(run_filtered signalonly "" test-without-building STUB_MODE=marker STUB_MARKER="Test crashed with signal segv." \
  STUB_THEN=pass STUB_STATE="$work/signalonly.state")
assert_eq "signal-only crash then green re-run exits 0" "$status" 0
assert_contains "signal-only crash re-runs the suite named under Failing tests" "$(argv_line signalonly 2)" \
  "[-parallel-testing-enabled] [NO] [-only-testing:IntentTests/FooTests]"

echo "# the Failing tests list also comes flat: one tab, fully qualified Target.Suite/test() entries"
status=$(run_filtered flatfailing "" test-without-building STUB_MODE=marker STUB_MARKER="Test crashed with signal segv." \
  STUB_THEN=pass STUB_STATE="$work/flatfailing.state" STUB_FLAT_FAILING=1)
assert_eq "signal-only crash with a flat Failing tests list then green re-run exits 0" "$status" 0
assert_eq "a flat Failing tests list is retried exactly once" "$(argv_count flatfailing)" 2
assert_contains "the flat list's suites are re-run (both / and . test separators)" "$(argv_line flatfailing 2)" \
  "[-parallel-testing-enabled] [NO] [-only-testing:IntentTests/FooTests] [-only-testing:IntentTests/DemoFixturesTests]"

echo "# a restart that names nothing and lists no failing test is not retried"
status=$(run_filtered nameless "" test-without-building STUB_MODE=marker STUB_MARKER="Lost connection to the test manager service" \
  STUB_THEN=pass STUB_STATE="$work/nameless.state" STUB_NO_FAILING=1)
assert_eq "a nameless crash exits 80" "$status" 80
assert_eq "a nameless crash makes one xcodebuild call" "$(argv_count nameless)" 1
assert_contains "a nameless crash says nothing could be re-run" "$(cat "$work/nameless.out")" "nothing to re-run"

echo "# the re-run honours ONLY_TESTING selectors narrower than the interrupted suite and merges the result bundles"
make_results "$work/crashprimary.json" "IntentTests/DemoFixturesTests/testFoo()=Failed" "IntentTests/DemoFixturesTests/testBar()=Passed" \
  "IntentTests/NewMessagesDividerViewTests/testDividerAppears()=Passed"
make_results "$work/crashretry.json" "IntentTests/DemoFixturesTests/testFoo()=Passed" "IntentTests/DemoFixturesTests/testBar()=Passed"
status=$(run_filtered crashonly "IntentTests/DemoFixturesTests/testFoo IntentTests/DemoFixturesTests/testBar() IntentTests/NewMessagesDividerViewTests" test-without-building \
  STUB_MODE=marker STUB_THEN=pass STUB_STATE="$work/crashonly.state" \
  STUB_MARKER="Restarting after unexpected exit, crash, or test timeout in IntentTests.DemoFixturesTests/testFoo(); summary will include totals from previous launches." \
  STUB_RESULTS="$work/crashprimary.json" STUB_RESULTS_RETRY="$work/crashretry.json")
out=$(cat "$work/crashonly.out")
assert_eq "filtered crash then green re-run exits 0" "$status" 0
assert_eq "filtered crash enumerates once and tests twice" "$(argv_count crashonly)" 3
retry=$(retry_argv crashonly)
assert_contains "the re-run writes a sibling result bundle" "$retry" "[-resultBundlePath] [$work/xcodebuild-result."
assert_contains "the re-run bundle is named after the primary one" "$retry" "/Intent-retry.xcresult]"
assert_contains "the re-run narrows to the ONLY_TESTING selectors inside the interrupted suite" "$retry" \
  "/Intent-retry.xcresult] [-only-testing:IntentTests/DemoFixturesTests/testFoo] [-only-testing:IntentTests/DemoFixturesTests/testBar()]"
assert_lacks "the re-run leaves out selectors of uninterrupted suites" "$retry" "NewMessagesDividerViewTests"
assert_lacks "a suite named as interrupted but outside the selection is not re-run" "$retry" "FooTests"
assert_contains "the left-out suite is reported" "$out" \
  "notice: IntentTests/FooTests is named as interrupted but lies outside the ONLY_TESTING selection; not re-running it."
assert_eq "both result bundles are read" "$(xcresulttool_count crashonly)" 2
assert_contains "the re-run result overrides the crashed test's primary result" "$out" \
  "  IntentTests/DemoFixturesTests/testFoo           1         1        0       0        0"
assert_contains "the uninterrupted selector keeps its primary result" "$out" \
  "  IntentTests/NewMessagesDividerViewTests         1         1        0       0        0"
assert_contains "the merged summary says so" "$out" "merged with the re-run"
assert_eq "the temporary bundles are removed after a green merged run" "$(temp_bundles)" 0

echo "# a selector naming the interrupted suite (or its target) keeps the whole suite in the re-run"
make_results "$work/overlapprimary.json" "IntentTests/DemoFixturesTests/testFoo()=Passed" "IntentTests/DemoFixturesTests/testBar()=Failed"
make_results "$work/overlapretry.json" "IntentTests/DemoFixturesTests/testFoo()=Passed" "IntentTests/DemoFixturesTests/testBar()=Passed"
status=$(run_filtered overlap "IntentTests/DemoFixturesTests/testFoo IntentTests/DemoFixturesTests" test-without-building \
  STUB_MODE=marker STUB_THEN=pass STUB_STATE="$work/overlap.state" STUB_NO_FAILING=1 \
  STUB_MARKER="Restarting after unexpected exit, crash, or test timeout in IntentTests.DemoFixturesTests/testBar(); summary will include totals from previous launches." \
  STUB_RESULTS="$work/overlapprimary.json" STUB_RESULTS_RETRY="$work/overlapretry.json")
out=$(cat "$work/overlap.out")
assert_eq "suite + nested selector: crash then green re-run exits 0" "$status" 0
retry=$(retry_argv overlap)
assert_contains "the suite selector wins over the nested one in the re-run" "$retry" "/Intent-retry.xcresult] [-only-testing:IntentTests/DemoFixturesTests]"
assert_lacks "the nested selector is not re-run on its own" "$retry" "[-only-testing:IntentTests/DemoFixturesTests/testFoo]"
assert_contains "the whole suite's re-run results replace the crashed suite's" "$out" \
  "  IntentTests/DemoFixturesTests                 2         2        0       0        0"
status=$(run_filtered overlaptarget "IntentTests IntentTests/DemoFixturesTests/testFoo" test-without-building \
  STUB_MODE=marker STUB_THEN=pass STUB_STATE="$work/overlaptarget.state" STUB_NO_FAILING=1 \
  STUB_MARKER="Restarting after unexpected exit, crash, or test timeout in IntentTests.DemoFixturesTests/testBar(); summary will include totals from previous launches." \
  STUB_RESULTS="$work/overlapprimary.json" STUB_RESULTS_RETRY="$work/overlapretry.json")
assert_eq "target + nested selector: crash then green re-run exits 0" "$status" 0
assert_contains "a target selector keeps the whole interrupted suite in the re-run" "$(retry_argv overlaptarget)" \
  "/Intent-retry.xcresult] [-only-testing:IntentTests/DemoFixturesTests]"

echo "# a re-run that records nothing for a selector is not green (the crashed suite's results are not trusted)"
make_results "$work/emptyretry.json"
status=$(run_filtered emptyretry "IntentTests/DemoFixturesTests/testBar" test-without-building \
  STUB_MODE=marker STUB_THEN=pass STUB_STATE="$work/emptyretry.state" STUB_NO_FAILING=1 \
  STUB_MARKER="Restarting after unexpected exit, crash, or test timeout in IntentTests.DemoFixturesTests/testBar(); summary will include totals from previous launches." \
  STUB_RESULTS="$work/overlapprimary.json" STUB_RESULTS_RETRY="$work/emptyretry.json")
out=$(cat "$work/emptyretry.out")
assert_eq "an empty re-run bundle is not green: exit 82" "$status" 82
assert_contains "the re-run narrowed to the selector" "$(retry_argv emptyretry)" "/Intent-retry.xcresult] [-only-testing:IntentTests/DemoFixturesTests/testBar]"
assert_contains "the primary Failed record stays as an unrecovered failure" "$out" \
  "  IntentTests/DemoFixturesTests/testBar         1         1        0       1        0"
assert_contains "the re-run selector is reported as recording nothing" "$out" \
  "error: the crash re-run of 'IntentTests/DemoFixturesTests/testBar' recorded no test executed or skipped for it"
assert_contains "the unrecovered test is named" "$out" \
  "error: IntentTests/DemoFixturesTests/testBar() failed in the crashed run and the re-run did not record it"
assert_contains "the exit line names the re-run" "$out" "or the crash re-run left an interrupted suite or test unrecovered"
assert_contains "both bundles are kept for inspection" "$out" "Re-run result bundle kept at: $work/xcodebuild-result."
rm -rf -- "$work"/xcodebuild-result.*

echo "# a target-wide selector is not satisfied by uninterrupted suites when the re-run of the interrupted one is empty"
make_results "$work/targetprimary.json" "IntentTests/DemoFixturesTests/testBar()=Failed" \
  "IntentTests/NewMessagesDividerViewTests/testDividerAppears()=Passed"
status=$(run_filtered targetempty "IntentTests" test-without-building \
  STUB_MODE=marker STUB_THEN=pass STUB_STATE="$work/targetempty.state" STUB_NO_FAILING=1 \
  STUB_MARKER="Restarting after unexpected exit, crash, or test timeout in IntentTests.DemoFixturesTests/testBar(); summary will include totals from previous launches." \
  STUB_RESULTS="$work/targetprimary.json" STUB_RESULTS_RETRY="$work/emptyretry.json")
out=$(cat "$work/targetempty.out")
assert_eq "target-wide selector + empty re-run exits 82" "$status" 82
assert_contains "the re-run covered the interrupted suite" "$(retry_argv targetempty)" "/Intent-retry.xcresult] [-only-testing:IntentTests/DemoFixturesTests]"
assert_contains "the uninterrupted suite's pass does not stand in for the interrupted one" "$out" \
  "error: the crash re-run of 'IntentTests/DemoFixturesTests' recorded no test executed or skipped for it"
assert_contains "the target row still shows the unrecovered failure" "$out" \
  "  IntentTests         5         2        0       1        0"
rm -rf -- "$work"/xcodebuild-result.*

echo "# a suite-wide re-run that omits the interrupted test does not count it as recovered"
make_results "$work/partialretry.json" "IntentTests/DemoFixturesTests/testFoo()=Passed"
status=$(run_filtered partialretry "IntentTests/DemoFixturesTests" test-without-building \
  STUB_MODE=marker STUB_THEN=pass STUB_STATE="$work/partialretry.state" STUB_NO_FAILING=1 \
  STUB_MARKER="Restarting after unexpected exit, crash, or test timeout in IntentTests.DemoFixturesTests/testBar(); summary will include totals from previous launches." \
  STUB_RESULTS="$work/overlapprimary.json" STUB_RESULTS_RETRY="$work/partialretry.json")
out=$(cat "$work/partialretry.out")
assert_eq "suite-wide selector + partial re-run exits 82" "$status" 82
assert_contains "the recorded test takes the re-run result, the omitted one keeps its failure" "$out" \
  "  IntentTests/DemoFixturesTests         2         2        0       1        0"
assert_contains "the omitted interrupted test is named as unrecovered" "$out" \
  "error: IntentTests/DemoFixturesTests/testBar() failed in the crashed run and the re-run did not record it"
assert_lacks "the suite itself is not reported as recording nothing" "$out" "recorded no test executed or skipped for it"
rm -rf -- "$work"/xcodebuild-result.*

echo "# RESULT_BUNDLE set: the re-run writes <bundle>-retry beside it"
status=$(run_filtered crashown "" test-without-building RESULT_BUNDLE="$work/crashown.xcresult" \
  STUB_MODE=crash STUB_THEN=pass STUB_STATE="$work/crashown.state")
assert_eq "RESULT_BUNDLE crash then green re-run exits 0" "$status" 0
assert_contains "the re-run bundle sits beside RESULT_BUNDLE" "$(argv_line crashown 2)" "[-resultBundlePath] [$work/crashown-retry.xcresult]"
[ -d "$work/crashown.xcresult" ] && pass "RESULT_BUNDLE is left in place after the re-run" || fail "RESULT_BUNDLE was removed"
[ -d "$work/crashown-retry.xcresult" ] && pass "the re-run bundle is left in place" || fail "the re-run bundle is missing"
status=$(run_filtered crashown2 "" test-without-building RESULT_BUNDLE="$work/TestResults" \
  STUB_MODE=crash STUB_THEN=pass STUB_STATE="$work/crashown2.state")
assert_contains "an extension-less RESULT_BUNDLE gets a -retry suffix" "$(argv_line crashown2 2)" "[-resultBundlePath] [$work/TestResults-retry]"

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
assert_eq "empty ONLY_TESTING never reads a result bundle" "$(xcresulttool_count plain)" 0
assert_eq "empty ONLY_TESTING leaves no temporary result bundle" "$(temp_bundles)" 0
status=$(run_filtered plainbundle "" test-without-building RESULT_BUNDLE="$work/plain.xcresult")
assert_eq "empty ONLY_TESTING with RESULT_BUNDLE exits 0" "$status" 0
assert_eq "empty ONLY_TESTING with RESULT_BUNDLE keeps that argv" "$(argv_line plainbundle 1)" \
  "argv: [test-without-building] [-project] [Intent.xcodeproj] [-scheme] [Intent] [-destination] [platform=iOS Simulator,id=$SIM_UDID] [-parallel-testing-enabled] [NO] [-resultBundlePath] [$work/plain.xcresult]"
assert_eq "empty ONLY_TESTING with RESULT_BUNDLE never reads it" "$(xcresulttool_count plainbundle)" 0

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
assert_contains "the real run keeps the unfiltered argv and adds a temporary result bundle" "$real" \
  "argv: [test-without-building] [-project] [Intent.xcodeproj] [-scheme] [Intent] [-destination] [platform=iOS Simulator,id=$SIM_UDID] [-parallel-testing-enabled] [NO] [-resultBundlePath] [$work/xcodebuild-result."
assert_contains "the real run ends with the selector" "$real" "/Intent.xcresult] [-only-testing:IntentTests]"
assert_contains "target-wide selector reports its resolved count" "$(cat "$work/target.out")" "ONLY_TESTING: IntentTests -> 5 test(s)"
assert_lock_free "lock released after a resolved filtered run"
assert_eq "enumeration scratch files are removed" "$(ls "$work" | grep -c '^xcodebuild-enumerate\.')" 0
assert_eq "the result bundle is read once" "$(xcresulttool_count target)" 1
assert_contains "the result bundle is read with xcresulttool" "$(cat "$work/target.args")" \
  "xcrun: [xcresulttool] [get] [test-results] [tests] [--path] [$work/xcodebuild-result."
assert_contains "the summary table names the selector" "$(cat "$work/target.out")" "ONLY_TESTING summary (6 test case(s) in $work/xcodebuild-result."
assert_contains "the summary table row shows requested/resolved/executed/skipped/failed" "$(cat "$work/target.out")" \
  "  IntentTests         5         5        0       0"
assert_contains "the summary table has a header" "$(cat "$work/target.out")" "  requested    resolved  executed  skipped  failed"
assert_eq "the temporary result bundle is removed after a passing run" "$(temp_bundles)" 0
assert_eq "results scratch files are removed" "$(ls "$work" | grep -c '^xcodebuild-results\.')" 0
assert_lacks "a passing filtered run keeps no bundle" "$(cat "$work/target.out")" "Result bundle kept at"

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
  "/Intent.xcresult] [-only-testing:IntentTests/DemoFixturesTests] [-skip-testing:IntentUITests]"
assert_contains "test-ios-unit summary row counts the selector's tests" "$(cat "$work/unitok.out")" \
  "  IntentTests/DemoFixturesTests         2         2        0       0"

echo "# explicit configuration: default argv is unchanged; Release is not DEBUG"
status=$(run_filtered defaultbuild "" build-ios)
assert_eq "default iOS build exits 0" "$status" 0
assert_eq "default iOS build keeps its exact destination and signing argv" "$(argv_line defaultbuild 1)" \
  'argv: [build] [-project] [Intent.xcodeproj] [-scheme] [Intent] [-destination] [generic/platform=iOS Simulator] [CODE_SIGN_IDENTITY=] [CODE_SIGNING_REQUIRED=NO] [CODE_SIGNING_ALLOWED=NO]'
status=$(run_filtered emptyconfig "" build-ios BUILD_CONFIGURATION=)
assert_eq "empty configuration keeps the default argv" "$(argv_line emptyconfig 1)" "$(argv_line defaultbuild 1)"
status=$(run_filtered debugbuild "" build-ios BUILD_CONFIGURATION=Debug)
assert_eq "explicit Debug build exits 0" "$status" 0
assert_eq "explicit Debug adds only the configuration" "$(argv_line debugbuild 1)" \
  "$(argv_line defaultbuild 1) [-configuration] [Debug]"
status=$(run_filtered releasebuild "" build-ios BUILD_CONFIGURATION=Release)
assert_eq "explicit Release build exits 0" "$status" 0
assert_eq "production Release build adds only the configuration, not testability" "$(argv_line releasebuild 1)" \
  "$(argv_line defaultbuild 1) [-configuration] [Release]"
status=$(run_filtered releasevision "" build-visionos BUILD_CONFIGURATION=Release)
assert_eq "Release visionOS build exits 0" "$status" 0
assert_eq "Release visionOS still checks the SDK first" "$(argv_line releasevision 1)" 'argv: [-showsdks]'
assert_eq "Release visionOS keeps its destination and signing, without testability" "$(argv_line releasevision 2)" \
  'argv: [build] [-project] [Intent.xcodeproj] [-scheme] [Intent] [-destination] [generic/platform=visionOS Simulator] [CODE_SIGN_IDENTITY=] [CODE_SIGNING_REQUIRED=NO] [CODE_SIGNING_ALLOWED=NO] [-configuration] [Release]'
for sub in build-for-testing test-ios test-ios-unit test-without-building test-without-building-unit; do
  status=$(run_filtered "release-$sub" "IntentTests/DemoFixturesTests" "$sub" BUILD_CONFIGURATION=Release)
  assert_eq "Release $sub exits 0" "$status" 0
  args=$(grep '^argv:' "$work/release-$sub.args")
  while IFS= read -r line; do
    assert_contains "Release $sub uses Release and testability on each invocation" "$line" \
      '[-configuration] [Release] [ENABLE_TESTABILITY=YES]'
    assert_contains "Release $sub keeps the simulator destination" "$line" \
      "[-destination] [platform=iOS Simulator,id=$SIM_UDID]"
  done <<< "$args"
  assert_lacks "Release $sub never defines DEBUG" "$args" DEBUG
  assert_lacks "Release $sub never changes compilation conditions" "$args" SWIFT_ACTIVE_COMPILATION_CONDITIONS
  assert_lacks "Release $sub never changes optimization" "$args" SWIFT_OPTIMIZATION_LEVEL
done
assert_contains "Release test build preserves signing policy" "$(argv_line release-test-ios-unit 1)" \
  '[CODE_SIGN_IDENTITY=] [CODE_SIGNING_REQUIRED=NO] [CODE_SIGNING_ALLOWED=NO]'
assert_contains "Release unit run preserves UI exclusion" "$(argv_line release-test-ios-unit 3)" '[-skip-testing:IntentUITests]'
status=$(run_filtered debugtest "IntentTests/DemoFixturesTests" test-ios-unit BUILD_CONFIGURATION=Debug)
assert_eq "explicit Debug tests exit 0" "$status" 0
assert_contains "explicit Debug tests select Debug" "$(argv_line debugtest 3)" '[-configuration] [Debug]'
assert_lacks "explicit Debug tests need no testability override" "$(cat "$work/debugtest.args")" ENABLE_TESTABILITY
status=$(run_filtered releasecrash "" test-without-building-unit BUILD_CONFIGURATION=Release \
  STUB_MODE=crash STUB_THEN=pass STUB_STATE="$work/releasecrash.state")
assert_eq "Release crash retry recovers" "$status" 0
assert_eq "Release crash retries exactly once" "$(argv_count releasecrash)" 2
assert_contains "Release retry preserves configuration and testability" "$(argv_line releasecrash 2)" \
  '[-configuration] [Release] [ENABLE_TESTABILITY=YES]'
assert_contains "Release retry preserves UI exclusion" "$(argv_line releasecrash 2)" '[-skip-testing:IntentUITests]'
assert_lock_free "Release retry releases the simulator lock"
status=$(run_filtered releasetypo "IntentTests/NotASuite" test-without-building BUILD_CONFIGURATION=Release)
assert_eq "Release still rejects unknown selectors" "$status" 82
assert_eq "Release unknown selector never starts tests" "$(argv_count releasetypo)" 1
for config in Profile release 'Release -sdk iphoneos'; do
  status=$(run_filtered badconfig "" build-ios BUILD_CONFIGURATION="$config")
  assert_eq "invalid configuration $config exits 1" "$status" 1
  assert_contains "invalid configuration is explained" "$(cat "$work/badconfig.out")" \
    'BUILD_CONFIGURATION must be Debug or Release'
  assert_eq "invalid configuration never invokes xcodebuild" "$(argv_count badconfig)" 0
done
for extra in -sdk -configuration; do
  status=0
  BUILD_CONFIGURATION=Release "$SCRIPT" build-ios "$extra" > "$work/extra.out" 2>&1 || status=$?
  assert_eq "Release still refuses extra argument $extra" "$status" 1
done
assert_contains "extra arguments remain explained" "$(cat "$work/extra.out")" 'subcommands take no extra arguments'

echo "# test-without-building-unit: split CI path skips IntentUITests without rebuilding"
status=$(run_filtered splitunitplain "" test-without-building-unit)
assert_eq "unfiltered split unit path exits 0" "$status" 0
assert_eq "unfiltered split unit path makes one call without enumeration" "$(argv_count splitunitplain)" 1
assert_eq "unfiltered split unit path carries only the UI skip" "$(argv_line splitunitplain 1)" \
  "argv: [test-without-building] [-project] [Intent.xcodeproj] [-scheme] [Intent] [-destination] [platform=iOS Simulator,id=$SIM_UDID] [-parallel-testing-enabled] [NO] [-skip-testing:IntentUITests]"
status=$(run_filtered splitunitskip "IntentUITests/ConversationTranscriptScrollUITests" test-without-building-unit)
out=$(cat "$work/splitunitskip.out")
assert_eq "UI selector under test-without-building-unit exits 82" "$status" 82
assert_contains "split unit path names the UI exclusion" "$out" \
  "ONLY_TESTING selector 'IntentUITests/ConversationTranscriptScrollUITests' is excluded by -skip-testing:IntentUITests on this subcommand"
assert_eq "split unit path only enumerates before rejecting the UI selector" "$(argv_count splitunitskip)" 1
assert_contains "split unit enumeration carries the UI skip" "$(argv_line splitunitskip 1)" \
  "] [-skip-testing:IntentUITests]"
status=$(run_filtered splitunitok "IntentTests/DemoFixturesTests" test-without-building-unit)
assert_eq "unit selector under test-without-building-unit exits 0" "$status" 0
assert_eq "split unit path enumerates and runs without building" "$(argv_count splitunitok)" 2
assert_contains "split unit real run carries the selector and UI skip" "$(argv_line splitunitok 2)" \
  "/Intent.xcresult] [-only-testing:IntentTests/DemoFixturesTests] [-skip-testing:IntentUITests]"

echo "# (a) a green Swift Testing run whose XCTest side executed 0 tests passes"
policy=()
for n in $(seq 1 71); do policy+=("IntentTests/ConversationTranscriptScrollPolicyTests/case$n()=Passed"); done
make_results "$work/policy.json" "${policy[@]}"
status=$(run_filtered swiftonly "IntentTests/ConversationTranscriptScrollPolicyTests" test-without-building \
  STUB_RESULTS="$work/policy.json" STUB_PREAMBLE="Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds")
out=$(cat "$work/swiftonly.out")
assert_eq "Swift Testing suite with an empty XCTest preamble exits 0" "$status" 0
assert_contains "the log still shows the XCTest preamble" "$out" "Executed 0 tests"
assert_contains "the table counts the 71 executed Swift Testing cases" "$out" \
  "  IntentTests/ConversationTranscriptScrollPolicyTests         2        71        0       0"
assert_lacks "no selector is reported as executing nothing" "$out" "records none executed"
assert_eq "temporary bundle removed after the green Swift Testing run" "$(temp_bundles)" 0

echo "# (b) a resolved selector absent from the result bundle exits 82"
make_results "$work/uionly.json" "IntentUITests/ConversationTranscriptScrollUITests/testGoToEndButtonAppears()=Passed"
status=$(run_filtered absent "IntentTests/ConversationTranscriptScrollPolicyTests IntentUITests/ConversationTranscriptScrollUITests" test-without-building \
  STUB_RESULTS="$work/uionly.json")
out=$(cat "$work/absent.out")
assert_eq "a selector that executed nothing exits 82 although xcodebuild exited 0" "$status" 82
assert_contains "the absent selector is named" "$out" \
  "ONLY_TESTING selector 'IntentTests/ConversationTranscriptScrollPolicyTests' resolved to 2 test(s) but the result bundle records none executed or skipped for it"
assert_contains "the absent selector's row shows zero executed" "$out" \
  "  IntentTests/ConversationTranscriptScrollPolicyTests         2         0        0       0"
assert_contains "the UI selector's row shows it ran" "$out" \
  "  IntentUITests/ConversationTranscriptScrollUITests           1         1        0       0"
assert_lacks "the UI selector is not blamed" "$out" "'IntentUITests/ConversationTranscriptScrollUITests' resolved to"
assert_contains "exit 82 is explained" "$out" "Exiting 82 (an ONLY_TESTING selector executed nothing although xcodebuild exited 0)"
assert_contains "the temporary bundle is kept and named" "$out" "Result bundle kept at: $work/xcodebuild-result."
[ -d "$(kept_bundle "$work/absent.out")" ] && pass "the kept bundle exists" || fail "the kept bundle is missing"
assert_eq "the real run was started" "$(argv_count absent)" 2
assert_lock_free "lock released after a zero-executed selector"
rm -rf -- "$work"/xcodebuild-result.*

echo "# (c) a selector whose tests were all skipped at runtime passes with a notice"
make_results "$work/skipped.json" "IntentTests/DemoFixturesTests/testFoo()=Skipped" "IntentTests/DemoFixturesTests/testBar()=Skipped"
status=$(run_filtered allskipped "IntentTests/DemoFixturesTests" test-without-building STUB_RESULTS="$work/skipped.json")
out=$(cat "$work/allskipped.out")
assert_eq "all-skipped selector exits 0" "$status" 0
assert_contains "all-skipped selector gets a notice" "$out" \
  "notice: ONLY_TESTING selector 'IntentTests/DemoFixturesTests': all 2 of its test(s) were skipped at runtime"
assert_contains "all-skipped row counts the skips" "$out" "  IntentTests/DemoFixturesTests         2         0        2       0"
assert_lacks "all-skipped selector is not an error" "$out" "error:"
assert_eq "temporary bundle removed after an all-skipped run" "$(temp_bundles)" 0

echo "# (d) failing tests keep xcodebuild's 65; the table is still printed"
make_results "$work/mixedresults.json" "IntentTests/DemoFixturesTests/testFoo()=Passed" \
  "IntentTests/DemoFixturesTests/testBar()=Failed" "IntentTests/DemoFixturesTests/testBaz()=Expected Failure"
status=$(run_filtered failedrun "IntentTests/DemoFixturesTests" test-without-building STUB_RESULTS="$work/mixedresults.json" STUB_MODE=fail)
out=$(cat "$work/failedrun.out")
assert_eq "failing filtered run keeps 65" "$status" 65
assert_contains "failing filtered run prints the table with the failure count" "$out" \
  "  IntentTests/DemoFixturesTests         2         3        0       1"
assert_contains "failing filtered run keeps the bundle" "$out" "Result bundle kept at: $work/xcodebuild-result."
assert_lacks "failing filtered run is not upgraded to 82" "$out" "Exiting 82"
rm -rf -- "$work"/xcodebuild-result.*
status=$(run_filtered failedabsent "IntentTests/ConversationTranscriptScrollPolicyTests" test-without-building STUB_RESULTS="$work/uionly.json" STUB_MODE=fail)
out=$(cat "$work/failedabsent.out")
assert_eq "65 wins over a zero-executed selector" "$status" 65
assert_contains "the zero-executed selector is still named" "$out" "'IntentTests/ConversationTranscriptScrollPolicyTests' resolved to 2 test(s) but the result bundle records none"
assert_contains "the warning says 65 is kept" "$out" "warning: the ONLY_TESTING selector(s) above executed nothing; keeping exit 65 from the test run"
rm -rf -- "$work"/xcodebuild-result.*

echo "# (e) a test-process crash keeps 80 over 82 and 83"
status=$(run_filtered crashfiltered "IntentTests/ConversationTranscriptScrollPolicyTests" test-without-building STUB_RESULTS="$work/uionly.json" STUB_MODE=crash)
out=$(cat "$work/crashfiltered.out")
assert_eq "crash with a selector exits 80" "$status" 80
assert_contains "crash with a selector prints the crash diagnostic" "$out" "crashed or was terminated (exit 65 is NOT a plain test failure)"
assert_contains "crash with a selector keeps 80 over the zero-executed selector" "$out" "keeping exit 80 from the test run"
assert_contains "crash with a selector keeps the bundle" "$out" "Result bundle kept at:"
rm -rf -- "$work"/xcodebuild-result.*
status=$(run_filtered crashunread "IntentTests/DemoFixturesTests" test-without-building STUB_RESULTS_FAIL=1 STUB_MODE=crash)
out=$(cat "$work/crashunread.out")
assert_eq "crash with an unreadable bundle exits 80" "$status" 80
assert_contains "crash with an unreadable bundle warns instead of exiting 83" "$out" \
  "warning: the ONLY_TESTING selection could not be verified from the result bundle; keeping exit 80 from the test run"
rm -rf -- "$work"/xcodebuild-result.*

echo "# an unreadable or missing result bundle on a green run exits 83"
status=$(run_filtered unreadable "IntentTests/DemoFixturesTests" test-without-building STUB_RESULTS_FAIL=1)
out=$(cat "$work/unreadable.out")
assert_eq "unreadable bundle on a green run exits 83" "$status" 83
assert_contains "unreadable bundle is reported" "$out" "could not verify the ONLY_TESTING selection: xcrun xcresulttool could not read $work/xcodebuild-result."
assert_contains "exit 83 is explained" "$out" "Exiting 83 (a run that exited 0 could not be verified from its result bundle)"
assert_contains "unreadable bundle is kept" "$out" "Result bundle kept at:"
assert_lock_free "lock released after an unreadable bundle"
rm -rf -- "$work"/xcodebuild-result.*
status=$(run_filtered nobundle "IntentTests/DemoFixturesTests" test-without-building STUB_NO_BUNDLE=1)
assert_eq "missing bundle on a green run exits 83" "$status" 83
assert_contains "missing bundle is reported" "$(cat "$work/nobundle.out")" "could not verify the ONLY_TESTING selection: no result bundle was written at $work/xcodebuild-result."
assert_eq "missing bundle makes no xcresulttool call" "$(xcresulttool_count nobundle)" 0
rm -rf -- "$work"/xcodebuild-result.*
echo "not json" > "$work/garbage-results.json"
status=$(run_filtered garbageresults "IntentTests/DemoFixturesTests" test-without-building STUB_RESULTS="$work/garbage-results.json")
assert_eq "unparsable results on a green run exit 83" "$status" 83
assert_contains "unparsable results are reported" "$(cat "$work/garbageresults.out")" "could not verify the ONLY_TESTING selection: the result bundle $work/xcodebuild-result."
rm -rf -- "$work"/xcodebuild-result.*
echo '{ "devices" : [ ] }' > "$work/noshape-results.json"
status=$(run_filtered noshape "IntentTests/DemoFixturesTests" test-without-building STUB_RESULTS="$work/noshape-results.json")
assert_eq "results without testNodes on a green run exit 83" "$status" 83
assert_contains "results without testNodes are reported" "$(cat "$work/noshape.out")" "has no testNodes list"
rm -rf -- "$work"/xcodebuild-result.*
status=$(run_filtered failunread "IntentTests/DemoFixturesTests" test-without-building STUB_RESULTS_FAIL=1 STUB_MODE=fail)
assert_eq "unreadable bundle on a failed run keeps 65" "$status" 65
assert_contains "unreadable bundle on a failed run warns" "$(cat "$work/failunread.out")" "keeping exit 65 from the test run"
rm -rf -- "$work"/xcodebuild-result.*

echo "# an unrecognised result string is unverifiable: 83 on a green run, 65 kept on a failed one"
make_results "$work/unknownresult.json" "IntentTests/DemoFixturesTests/testFoo()=Passed" "IntentTests/DemoFixturesTests/testBar()=Mysterious"
status=$(run_filtered unknownresult "IntentTests/DemoFixturesTests" test-without-building STUB_RESULTS="$work/unknownresult.json")
out=$(cat "$work/unknownresult.out")
assert_eq "unknown result on a green run exits 83" "$status" 83
assert_contains "unknown result is counted in the unknown column, not as executed" "$out" \
  "  IntentTests/DemoFixturesTests         2         1        0       0        1"
assert_contains "unknown result is reported with its string" "$out" \
  "could not verify the ONLY_TESTING selection: 1 test case(s) matching 'IntentTests/DemoFixturesTests' have a result the wrapper does not recognise ('Mysterious'"
assert_lacks "unknown result is not reported as executing nothing" "$out" "records none executed"
assert_contains "unknown result exit 83 is explained" "$out" "Exiting 83 (a run that exited 0 could not be verified from its result bundle)"
assert_contains "unknown result keeps the bundle" "$out" "Result bundle kept at:"
assert_lock_free "lock released after an unknown result"
rm -rf -- "$work"/xcodebuild-result.*
status=$(run_filtered unknownfail "IntentTests/DemoFixturesTests" test-without-building STUB_RESULTS="$work/unknownresult.json" STUB_MODE=fail)
out=$(cat "$work/unknownfail.out")
assert_eq "unknown result on a failed run keeps 65" "$status" 65
assert_contains "unknown result on a failed run warns" "$out" \
  "warning: the ONLY_TESTING selection could not be verified from the result bundle; keeping exit 65 from the test run"
assert_lacks "unknown result on a failed run is not upgraded to 83" "$out" "Exiting 83"
rm -rf -- "$work"/xcodebuild-result.*

echo "# RESULT_BUNDLE set: the given bundle is used, read, and left in place"
status=$(run_filtered ownbundle "IntentTests/DemoFixturesTests" test-without-building RESULT_BUNDLE="$work/own.xcresult")
assert_eq "RESULT_BUNDLE with a selector exits 0" "$status" 0
assert_contains "RESULT_BUNDLE is passed instead of a temporary bundle" "$(argv_line ownbundle 2)" \
  "[-parallel-testing-enabled] [NO] [-resultBundlePath] [$work/own.xcresult] [-only-testing:IntentTests/DemoFixturesTests]"
assert_contains "RESULT_BUNDLE is the bundle read back" "$(cat "$work/ownbundle.args")" "xcrun: [xcresulttool] [get] [test-results] [tests] [--path] [$work/own.xcresult]"
[ -d "$work/own.xcresult" ] && pass "RESULT_BUNDLE is left in place after a passing run" || fail "RESULT_BUNDLE was removed"
assert_eq "no temporary bundle when RESULT_BUNDLE is set" "$(temp_bundles)" 0

echo "# GITHUB_STEP_SUMMARY receives the Markdown table; a test counts for every selector it matches"
: > "$work/step-summary.md"
status=$(run_filtered summary "IntentTests IntentTests/DemoFixturesTests" test-without-building GITHUB_STEP_SUMMARY="$work/step-summary.md")
summary_md=$(cat "$work/step-summary.md")
assert_eq "run with GITHUB_STEP_SUMMARY exits 0" "$status" 0
assert_contains "step summary has a heading" "$summary_md" "### ONLY_TESTING selectors"
assert_contains "step summary has the table header" "$summary_md" "| Requested | Resolved | Executed | Skipped | Failed | Unknown |"
assert_contains "step summary has the target-wide row" "$summary_md" '| `IntentTests` | 5 | 5 | 0 | 0 | 0 |'
assert_contains "step summary has the nested selector's row" "$summary_md" '| `IntentTests/DemoFixturesTests` | 2 | 2 | 0 | 0 | 0 |'
assert_lacks "step summary flags nothing on a clean run" "$summary_md" ":x:"
: > "$work/step-summary2.md"
status=$(run_filtered summary82 "IntentTests/ConversationTranscriptScrollPolicyTests" test-without-building \
  GITHUB_STEP_SUMMARY="$work/step-summary2.md" STUB_RESULTS="$work/uionly.json")
assert_eq "zero-executed run with GITHUB_STEP_SUMMARY exits 82" "$status" 82
assert_contains "step summary flags the zero-executed selector" "$(cat "$work/step-summary2.md")" \
  ':x: `IntentTests/ConversationTranscriptScrollPolicyTests` executed nothing (exit 82).'
rm -rf -- "$work"/xcodebuild-result.*
status=$(run_filtered nosummary "IntentTests/DemoFixturesTests" test-without-building)
assert_eq "without GITHUB_STEP_SUMMARY the run exits 0" "$status" 0
assert_eq "without GITHUB_STEP_SUMMARY no summary file appears" "$(ls "$work" | grep -c 'step-summary')" 3

echo "# UI sharding rejects invalid or ambiguous configuration before touching Xcode"
for count in 2 6; do
  for shard in 0 "$((count + 1))" -1 01 abc 1/2 1.0 +1 ' 1' $'1\n' １ 18446744073709551617; do
    status=$(run_filtered shardinvalid "" test-without-building UI_TEST_SHARD="$shard" UI_TEST_SHARD_COUNT="$count")
    assert_eq "UI_TEST_SHARD=$shard of $count is refused" "$status" 1
    assert_eq "invalid shard makes no Xcode call" "$(argv_count shardinvalid)" 0
  done
done
for count in '' 0 -1 06 abc 1/6 6.0 +6 ' 6' $'6\n' ６; do
  status=$(run_filtered shardcountinvalid "" test-without-building UI_TEST_SHARD=1 UI_TEST_SHARD_COUNT="$count")
  assert_eq "UI_TEST_SHARD_COUNT=$count is refused" "$status" 1
  assert_eq "invalid count makes no Xcode call" "$(argv_count shardcountinvalid)" 0
done
status=$(run_filtered sharddefaultinvalid "" test-without-building UI_TEST_SHARD=3)
assert_eq "default count still rejects shard 3" "$status" 1
assert_eq "invalid default shard makes no Xcode call" "$(argv_count sharddefaultinvalid)" 0
status=$(run_filtered countonly "" test-without-building UI_TEST_SHARD_COUNT=6)
assert_eq "a shared count alone keeps the full gate" "$status" 0
assert_eq "count alone does not enumerate" "$(argv_count countonly)" 1
assert_lacks "count alone does not narrow selection" "$(argv_line countonly 1)" "-only-testing:"
status=$(run_filtered countfiltered "IntentTests/DemoFixturesTests" test-without-building UI_TEST_SHARD_COUNT=6)
assert_eq "a shared count preserves explicit filtered runs" "$status" 0
assert_contains "count does not replace the explicit selector" "$(argv_line countfiltered 2)" "[-only-testing:IntentTests/DemoFixturesTests]"
status=$(run_filtered shardfilter "IntentUITests" test-without-building UI_TEST_SHARD=1)
assert_eq "a shard cannot silently override ONLY_TESTING" "$status" 1
assert_eq "ambiguous selection makes no Xcode call" "$(argv_count shardfilter)" 0
for sub in resolve build-ios build-visionos build-for-testing test-ios test-ios-unit test-without-building-unit pick-simulator; do
  status=$(run_filtered shardcommand "" "$sub" UI_TEST_SHARD=1)
  assert_eq "sharding is refused for $sub" "$status" 1
  assert_eq "unsupported shard command makes no Xcode call" "$(argv_count shardcommand)" 0
done

# Synthetic catalogs are independent input, not an inventory of the app tests.
# One large class must split at method level; future classes need no list edit.
python3 - "$work" <<'EOF'
import json, pathlib, sys
work = pathlib.Path(sys.argv[1])
methods = ["IntentUITests/TranscriptUITests/test%s()" % letter for letter in "ABCDEF"]
def catalog(name, enabled, disabled=None, errors=None):
    (work / (name + ".json")).write_text(json.dumps({"errors": errors or [], "values": [{
        "enabledTests": enabled, "disabledTests": disabled or []}]}))
entries = [{"identifier": ident} for ident in methods + ["IntentTests/UnitTests/testUnit()"]]
disabled = [{"identifier": "IntentUITests/Screenshots/testDisabled()"}]
catalog("shardcatalog", entries, disabled)
catalog("shardreordered", list(reversed(entries)), disabled)
catalog("shardnew", entries + [{"identifier": "IntentUITests/ZNewUITests/testNew()"}], disabled)
catalog("sharderrors", entries, errors=["A test bundle could not be loaded"])
catalog("shardmalformed", entries + [{"name": "missing identifier"}])
catalog("shardsuite", entries + [{"identifier": "IntentUITests/UnexpandedSuite"}])
catalog("shardlist", {"identifier": methods[0]})
catalog("shardempty", [{"identifier": "IntentTests/UnitTests/testUnit()"}], disabled)
catalog("shardsingle", entries[:1])
catalog("shardconflict", entries, [entries[0]])
catalog("shardfew", entries[:5])
catalog("shardlarge", [{"identifier": "IntentUITests/TranscriptUITests/test%s()" % c}
                       for c in "ABCDEFGHIJKLMNOPQR"])
EOF
ui=IntentUITests/TranscriptUITests

echo "# all groups are deterministic, disjoint, complete, and split at method level"
# Independent expectations for the synthetic six-method catalog, not app inventory
# or values computed by the resolver. "default" also proves legacy two-way callers.
while read -r config shard letters; do
  count=$config; knobs=()
  if [ "$config" = default ]; then count=2; else knobs+=("UI_TEST_SHARD_COUNT=$count"); fi
  for variant in catalog reordered new; do
    name=shard$variant$config-$shard
    cases=()
    for letter in $letters; do cases+=("$ui/test$letter()=Passed"); done
    if [ "$variant" = new ]; then
      case "$count/$shard" in
        1/1|2/1|4/3|6/1) cases+=("IntentUITests/ZNewUITests/testNew()=Passed") ;;
      esac
    fi
    printf '%s\n' "${cases[@]}" | sed 's/=Passed$//' > "$work/$name.want"
    make_results "$work/$name.json" "${cases[@]}"
    status=$(run_filtered "$name" "" test-without-building UI_TEST_SHARD="$shard" ${knobs+"${knobs[@]}"} \
      STUB_CATALOG="$work/shard$variant.json" STUB_RESULTS="$work/$name.json" GITHUB_STEP_SUMMARY="$work/sharding-summary.md")
    assert_eq "$variant shard $shard/$config succeeds" "$status" 0
    assert_eq "$variant shard $shard/$config enumerates then runs" "$(argv_count "$name")" 2
    assert_eq "$variant shard $shard/$config verifies its results" "$(xcresulttool_count "$name")" 1
    assert_contains "shard execution stays serial" "$(argv_line "$name" 2)" "[-parallel-testing-enabled] [NO]"
    assert_lacks "shard enumeration is not narrowed" "$(argv_line "$name" 1)" "-only-testing:"
  done
done <<'EOF'
default 1 A C E
default 2 B D F
1 1 A B C D E F
2 1 A C E
2 2 B D F
4 1 A E
4 2 B F
4 3 C
4 4 D
6 1 A
6 2 B
6 3 C
6 4 D
6 5 E
6 6 F
EOF
if python3 - "$work" <<'EOF'
import pathlib, re, sys
work = pathlib.Path(sys.argv[1])
def selected(name):
    lines = [line for line in (work / (name + ".args")).read_text().splitlines()
             if line.startswith("argv:") and "-enumerate-tests" not in line]
    assert len(lines) == 1, lines
    return re.findall(r"\[-only-testing:([^\]]+)\]", lines[0])
expected = {"IntentUITests/TranscriptUITests/test%s()" % letter for letter in "ABCDEF"}
for config, count in (("default", 2), ("1", 1), ("2", 2), ("4", 4), ("6", 6)):
    for variant in ("catalog", "reordered", "new"):
        groups = []
        for shard in range(1, count + 1):
            name = "shard%s%s-%d" % (variant, config, shard)
            group = selected(name)
            assert group == (work / (name + ".want")).read_text().splitlines(), (name, group)
            assert group
            if variant == "reordered":
                assert group == selected("shardcatalog%s-%d" % (config, shard))
            groups.append(group)
        flat = [ident for group in groups for ident in group]
        want = expected | ({"IntentUITests/ZNewUITests/testNew()"} if variant == "new" else set())
        assert len(flat) == len(set(flat)) and set(flat) == want, (config, variant, groups)
        assert max(map(len, groups)) - min(map(len, groups)) <= 1
EOF
then pass "shard selections cover exactly all enabled UI methods and ignore enumeration order"
else fail "shard selections overlap, omit methods, or depend on enumeration order"; fi
assert_contains "job summary identifies the shard" "$(cat "$work/sharding-summary.md")" "UI test shard 1/2"
assert_contains "job summary identifies all six shards" "$(cat "$work/sharding-summary.md")" "UI test shard 6/6"
assert_contains "job summary includes method-level verification" "$(cat "$work/sharding-summary.md")" '| `IntentUITests/TranscriptUITests/testC()` | 1 | 1 | 0 | 0 | 0 |'
assert_lock_free "lock released after shard execution"

echo "# partial, malformed, or empty catalogs cannot silently omit UI tests"
for bad in errors malformed suite list empty single conflict; do
  status=$(run_filtered shardbad "" test-without-building UI_TEST_SHARD=1 STUB_CATALOG="$work/shard$bad.json")
  assert_eq "$bad shard catalog fails closed" "$status" 83
  assert_eq "$bad shard catalog never starts tests" "$(argv_count shardbad)" 1
  assert_lock_free "lock released after $bad shard catalog"
done
for spec in 4:single 6:few 7:catalog 18446744073709551617:catalog; do
  count=${spec%:*}; kind=${spec#*:}
  status=$(run_filtered shardfew "" test-without-building UI_TEST_SHARD=1 UI_TEST_SHARD_COUNT="$count" \
    STUB_CATALOG="$work/shard$kind.json")
  assert_eq "too few methods for $count groups fails even for nonempty shard 1" "$status" 83
  assert_eq "too few methods never starts tests" "$(argv_count shardfew)" 1
  assert_lock_free "lock released after too-few-method catalog"
done
status=$(run_filtered shardenumfail "" test-without-building UI_TEST_SHARD=1 STUB_ENUMERATE_FAIL=1)
assert_eq "shard enumeration failure exits 83" "$status" 83

echo "# every shard method needs a known result; duplicates cannot replace missing methods"
for count in 2 6; do
  catalog=$work/shardcatalog.json; middle=C; last=E
  if [ "$count" = 6 ]; then catalog=$work/shardlarge.json; middle=G; last=M; fi
  make_results "$work/shardpass.json" "$ui/testA()=Passed" "$ui/test$middle()=Passed" "$ui/test$last()=Passed"
  make_results "$work/shardmissing.json" "$ui/testA()=Passed" "$ui/testA()=Passed" "$ui/test$last()=Passed"
  make_results "$work/shardunknown.json" "$ui/testA()=Passed" "$ui/test$middle()=Mysterious" "$ui/test$last()=Passed"
  make_results "$work/shardfailed.json" "$ui/testA()=Passed" "$ui/test$middle()=Failed" "$ui/test$last()=Passed"
  make_results "$work/shardskipped.json" "$ui/testA()=Passed" "$ui/test$middle()=Skipped" "$ui/test$last()=Expected Failure"
  make_results "$work/shardextra.json" "$ui/testA()=Passed" "$ui/test$middle()=Passed" "$ui/test$last()=Passed" "$ui/testB()=Passed"
  make_results "$work/shardnewresult.json" "$ui/testA()=Passed" "$ui/test$middle()=Passed" "$ui/test$last()=Passed" \
    "IntentUITests/UnknownUITests/testNew()=Passed"
  for spec in missing:82 unknown:83 failed:65 skipped:0 extra:83 newresult:83; do
    kind=${spec%:*}; expected=${spec#*:}
    status=$(run_filtered shardresult "" test-without-building UI_TEST_SHARD=1 UI_TEST_SHARD_COUNT="$count" \
      STUB_CATALOG="$catalog" STUB_RESULTS="$work/shard$kind.json")
    assert_eq "$kind result for 1/$count exits $expected even when Xcode exits 0" "$status" "$expected"
  done
  for spec in STUB_NO_BUNDLE=1 STUB_RESULTS_FAIL=1; do
    status=$(run_filtered shardunread "" test-without-building UI_TEST_SHARD=1 UI_TEST_SHARD_COUNT="$count" STUB_CATALOG="$catalog" "$spec")
    assert_eq "$spec cannot leave a shard green" "$status" 83
  done
  status=$(run_filtered shardfail "" test-without-building UI_TEST_SHARD=1 UI_TEST_SHARD_COUNT="$count" STUB_CATALOG="$catalog" STUB_MODE=fail STUB_RESULTS_FAIL=1)
  assert_eq "shard test failure wins over unreadable results" "$status" 65

  echo "# a shard crash retries only its assigned methods and verifies every retry result"
  make_results "$work/shardretrymissing.json" "$ui/testA()=Passed" "$ui/test$last()=Passed"
  for spec in recovered:0 missing:82 unknown:83 extra:83 recordedfailure:65 failed:65 crashed:80; do
    kind=${spec%:*}; expected=${spec#*:}
    results=$work/shardpass.json; mode=pass
    case "$kind" in
      missing) results=$work/shardretrymissing.json ;;
      unknown|extra) results=$work/shard$kind.json ;;
      recordedfailure) results=$work/shardfailed.json ;;
      failed) mode=fail ;;
      crashed) mode=marker ;;
    esac
    status=$(run_filtered shardretry$kind "" test-without-building UI_TEST_SHARD=1 UI_TEST_SHARD_COUNT="$count" \
      STUB_CATALOG="$catalog" STUB_RESULTS="$work/shardfailed.json" STUB_RESULTS_RETRY="$results" \
      STUB_MODE=marker STUB_THEN="$mode" STUB_STATE="$work/shardretry$count-$kind.state" STUB_NO_FAILING=1 \
      STUB_MARKER="Restarting after unexpected exit, crash, or test timeout in IntentUITests.TranscriptUITests/test$middle(); summary will include totals from previous launches.")
    assert_eq "$kind crash outcome for 1/$count exits $expected" "$status" "$expected"
    assert_eq "shard crash enumerates once and retries exactly once" "$(argv_count shardretry$kind)" 3
    assert_contains "retry stays serial" "$(retry_argv shardretry$kind)" "[-parallel-testing-enabled] [NO]"
    assert_eq "retry contains exactly the assigned methods, not the whole suite or another shard" \
      "$(retry_argv shardretry$kind | grep -o -- '-only-testing:[^]]*')" \
      "$(printf '%s\n' "-only-testing:$ui/testA()" "-only-testing:$ui/test$middle()" "-only-testing:$ui/test$last()")"
    assert_lock_free "lock released after $kind shard retry"
  done
done

echo
if [ "$failures" -eq 0 ]; then
  python3 scripts/test-test-build-artifact.py
  echo "all xcodebuild.sh self-tests passed"
else
  echo "$failures xcodebuild.sh self-test(s) FAILED" >&2
  exit 1
fi
