#!/usr/bin/env bash
# Self-tests for scripts/xcodebuild.sh: the simulator lock, the
# crash-vs-failure classification of a test run, the launch watchdog, the resolution of
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
# STUB_RESULTS_FAIL=1; `simctl list devices available -j` prints
# $STUB_SIMCTL_DEVICES or fails under STUB_SIMCTL_FAIL=1; `--show-sdk-version` prints $STUB_SDK_VERSION, or fails
# when it is unset; every other invocation (simctl) exits 0.
cat > "$stubs/xcrun" <<'EOF'
#!/usr/bin/env bash
if [ -n "${STUB_ARGS:-}" ]; then
  { printf 'xcrun:'; printf ' [%s]' "$@"; echo; } >> "$STUB_ARGS"
fi
case " $* " in
  *" simctl list devices available -j "*)
    [ -z "${STUB_SIMCTL_FAIL:-}" ] || exit 1
    [ -z "${STUB_SIMCTL_DEVICES:-}" ] || cat "$STUB_SIMCTL_DEVICES" ;;
  *" --sdk iphonesimulator --show-sdk-version "*)
    [ -n "${STUB_SDK_VERSION:-}" ] || exit 1
    echo "$STUB_SDK_VERSION" ;;
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
# outcome; STUB_ENUM_DYLD=1 makes it print dyld's launch abort first and take
# three seconds, like a hosted enumeration whose host app cannot launch.
# Launch failures (ios#905): STUB_REPORT=<file> copies that crash report into
# $LAUNCH_CRASH_REPORTS_DIR STUB_REPORT_DELAY seconds (default 1) after a test
# invocation starts, without delaying it; STUB_LOG_DYLD=1 prints dyld's
# abort lines; mode "hang" waits on "Launch dev.intentapp.ios" for
# STUB_HANG seconds (default 60), as XCUITest does.
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
    if [ -n "${STUB_ENUM_DYLD:-}" ]; then
      echo "dyld[4242]: Library not loaded: /usr/lib/swift/libswiftWebKit.dylib"
      echo "  Referenced from: <UUID> /stub/Intent.app/Intent.debug.dylib"
      sleep 3
    fi
    cp "$STUB_CATALOG" "$out"
    exit 0 ;;
esac
if [ -n "${STUB_REPORT:-}" ]; then
  (sleep "${STUB_REPORT_DELAY:-1}"; cp "$STUB_REPORT" "$LAUNCH_CRASH_REPORTS_DIR/Intent-stub-$$.ips") > /dev/null 2>&1 &
fi
if [ -n "${STUB_LOG_DYLD:-}" ]; then
  echo "dyld[4242]: Library not loaded: /usr/lib/swift/libswiftWebKit.dylib"
  echo "  Referenced from: <UUID> /stub/Intent.app/Intent.debug.dylib"
fi
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
  hang)
    echo "    t =     0.03s     Launch dev.intentapp.ios"
    exec sleep "${STUB_HANG:-60}" ;;
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
unset GITHUB_STEP_SUMMARY RESULT_BUNDLE ONLY_TESTING BUILD_CONFIGURATION DERIVED_DATA_DIR
unset UI_TEST_SHARD UI_TEST_SHARD_PLAN_PATH ONLY_TESTING_IDENTITIES_PATH
export SIM_UDID=00000000-0000-0000-0000-000000000001
export SIM_LOCK_DIR=$work/locks
# Never read this machine's real crash reports.
export LAUNCH_CRASH_REPORTS_DIR=$work/reports
mkdir -p "$LAUNCH_CRASH_REPORTS_DIR"
unset LAUNCH_CRASH_WATCH
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

echo "# launch failures (ios#905): a dyld abort stops the run with exit 84 and is never re-run"
# make_report <file> <udid> <namespace>: an .ips crash report (JSON header
# line plus JSON body) for the app on that simulator.
make_report() {
  python3 - "$@" <<'EOF'
import json, sys
out, udid, namespace = sys.argv[1:4]
header = {"app_name": "Intent", "bundleID": "dev.intentapp.ios", "bug_type": "309", "name": "Intent"}
dyld = namespace == "DYLD"
body = {"procName": "Intent", "bundleInfo": {"CFBundleIdentifier": "dev.intentapp.ios"},
        "procPath": "/Users/USER/Library/Developer/CoreSimulator/Devices/%s/data/Containers/Bundle/Application/X/Intent.app/Intent" % udid,
        "termination": {"namespace": namespace, "indicator": "Library missing" if dyld else "Abort trap: 6",
                        "reasons": ["Library not loaded: /usr/lib/swift/libswiftWebKit.dylib",
                                    "Referenced from: <UUID> /x/Intent.debug.dylib"] if dyld else []}}
with open(out, "w") as f:
    f.write(json.dumps(header) + "\n" + json.dumps(body, indent=2) + "\n")
EOF
}
make_report "$work/report-dyld.ips" "$SIM_UDID" DYLD
make_report "$work/report-other-device.ips" 11111111-2222-3333-4444-555555555555 DYLD
make_report "$work/report-signal.ips" "$SIM_UDID" SIGNAL
cat > "$work/sims-launch.json" <<EOF
{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-4": [
  {"name": "iPhone 16", "udid": "$SIM_UDID", "isAvailable": true}]}}
EOF
reset_reports() { rm -f -- "$LAUNCH_CRASH_REPORTS_DIR"/*; }
# scratch_count <prefix>: entries of $work whose name starts with <prefix>.
scratch_count() { find "$work" -maxdepth 1 -name "$1*" | wc -l | tr -d ' '; }
launch_dirs=$(scratch_count xcodebuild-launch.)
launch_started=$(date +%s)
: > "$work/launch-summary.md"
status=$(run_filtered launchhang "" test-without-building STUB_MODE=hang STUB_REPORT="$work/report-dyld.ips" \
  STUB_SIMCTL_DEVICES="$work/sims-launch.json" GITHUB_STEP_SUMMARY="$work/launch-summary.md")
launch_elapsed=$(( $(date +%s) - launch_started ))
out=$(cat "$work/launchhang.out")
assert_eq "a hung launch with a dyld crash report exits 84" "$status" 84
if [ "$launch_elapsed" -lt 20 ]; then pass "a hung launch fails fast (${launch_elapsed}s)"; else fail "a hung launch took ${launch_elapsed}s"; fi
assert_contains "the launch failure names the process and dyld's indicator" "$out" \
  "dyld terminated Intent (dev.intentapp.ios) before main (Library missing)"
assert_contains "the launch failure names the simulator and runtime" "$out" "on iPhone 16 (iOS 18.4) $SIM_UDID"
assert_contains "the launch failure quotes the missing library" "$out" "  Library not loaded: /usr/lib/swift/libswiftWebKit.dylib"
assert_contains "the launch failure names the crash report" "$out" "Seen in the crash report $LAUNCH_CRASH_REPORTS_DIR/Intent-stub-"
assert_contains "the launch failure keeps the log" "$out" "Full xcodebuild output kept at: $work/xcodebuild-test."
assert_contains "the launch failure says why it exits" "$out" "Exiting 84 (app launch failure)."
assert_lacks "a launch failure is not reported as a test-process crash" "$out" "crashed or was terminated"
assert_eq "a launch failure is not re-run" "$(argv_count launchhang)" 1
assert_contains "the job summary records the launch failure" "$(cat "$work/launch-summary.md")" \
  "### App launch failure (the test run)"
assert_lock_free "lock released after a launch failure"
assert_eq "no launch-watch state is left behind" "$(scratch_count xcodebuild-launch.)" "$launch_dirs"

echo "# a SIGTERM-immune hung xcodebuild is SIGKILLed after the grace period"
reset_reports
status=$(run_filtered launchresist "" test-without-building STUB_MODE=hang STUB_RESIST_ROOT=1 SIM_LOCK_KILL_GRACE=1 \
  STUB_REPORT="$work/report-dyld.ips")
assert_eq "a SIGTERM-immune hung launch still exits 84" "$status" 84
assert_lock_free "lock released after killing a SIGTERM-immune launch"

echo "# dyld's abort lines in the xcodebuild output suffice without a crash report"
reset_reports
status=$(run_filtered launchlog "" test-without-building STUB_MODE=hang STUB_LOG_DYLD=1)
out=$(cat "$work/launchlog.out")
assert_eq "a dyld abort in the log exits 84" "$status" 84
assert_contains "the log-only launch failure names dyld's process and reason" "$out" \
  "dyld terminated the launched process (pid 4242) before main (Library not loaded)"
assert_contains "the log-only launch failure quotes the referencing image" "$out" \
  "  Referenced from: <UUID> /stub/Intent.app/Intent.debug.dylib"
assert_contains "the log-only launch failure names the log" "$out" "Seen in the xcodebuild output, "

echo "# a hosted run that exits as a crash before the report lands is a launch failure, not 80"
reset_reports
status=$(run_filtered launchhosted "" test-without-building STUB_MODE=marker STUB_THEN=pass STUB_STATE="$work/launchhosted.state" \
  STUB_MARKER="Intent (4242) encountered an error (Test crashed with signal abrt before establishing connection.)" \
  STUB_NO_FAILING=1 STUB_REPORT="$work/report-dyld.ips" STUB_REPORT_DELAY=2)
assert_eq "a hosted launch crash exits 84" "$status" 84
assert_eq "a hosted launch crash is not re-run" "$(argv_count launchhosted)" 1
assert_lacks "a hosted launch crash is not classified as 80" "$(cat "$work/launchhosted.out")" "Exiting 80"

echo "# a hosted enumeration whose host cannot launch exits 84 before any test runs, not 82"
reset_reports
status=$(run_filtered launchenum "IntentTests/DemoFixturesTests" test-without-building STUB_ENUM_DYLD=1)
out=$(cat "$work/launchenum.out")
assert_eq "an enumeration launch failure exits 84" "$status" 84
assert_contains "the enumeration launch failure names the phase" "$out" "into test enumeration"
assert_eq "an enumeration launch failure starts no test run" "$(argv_count launchenum)" 1
assert_lacks "an enumeration launch failure is not an unmatched selector" "$out" "matched no test"
assert_lock_free "lock released after an enumeration launch failure"
assert_eq "an enumeration launch failure leaves no enumeration scratch files" "$(scratch_count xcodebuild-enumerate.)" 0
assert_contains "an enumeration launch failure keeps its log" "$out" "Full xcodebuild output kept at: $work/xcodebuild-test."

echo "# no false positives: old, other-device, and non-dyld crash reports"
reset_reports
cp "$work/report-dyld.ips" "$LAUNCH_CRASH_REPORTS_DIR/Intent-old.ips"
touch -t 202001010000 "$LAUNCH_CRASH_REPORTS_DIR/Intent-old.ips"
status=$(run_filtered launchold "" test-without-building STUB_MODE=pass STUB_SLEEP=2)
assert_eq "a dyld report from before the run is ignored" "$status" 0
status=$(run_filtered launchotherdev "" test-without-building STUB_MODE=pass STUB_SLEEP=3 STUB_REPORT="$work/report-other-device.ips")
assert_eq "another simulator's dyld report is ignored" "$status" 0
status=$(run_filtered launchsignal "" test-without-building STUB_MODE=pass STUB_SLEEP=3 STUB_REPORT="$work/report-signal.ips")
assert_eq "a non-dyld crash report during a passing run is ignored" "$status" 0
status=$(run_filtered launchfailtests "" test-without-building STUB_MODE=fail STUB_REPORT="$work/report-signal.ips" STUB_REPORT_DELAY=0)
assert_eq "failing tests with a non-dyld crash report keep 65" "$status" 65
status=$(run_filtered launchcrash "" test-without-building STUB_MODE=crash STUB_THEN=pass STUB_STATE="$work/launchcrash.state" \
  STUB_REPORT="$work/report-signal.ips" STUB_REPORT_DELAY=0)
assert_eq "an ordinary test-process crash keeps the re-run" "$(argv_count launchcrash)" 2
assert_eq "an ordinary test-process crash recovered by the re-run exits 0" "$status" 0
assert_lacks "an ordinary crash is not a launch failure" "$(cat "$work/launchcrash.out")" "could not launch"

echo "# LAUNCH_CRASH_WATCH=0 disables the watchdog"
reset_reports
status=$(run_filtered launchoff "" test-without-building STUB_MODE=marker STUB_THEN=pass STUB_STATE="$work/launchoff.state" \
  STUB_MARKER="Test crashed with signal abrt." STUB_REPORT="$work/report-dyld.ips" STUB_REPORT_DELAY=0 STUB_SLEEP=2 \
  LAUNCH_CRASH_WATCH=0)
assert_eq "with the watchdog off a launch crash takes the ordinary crash path" "$(argv_count launchoff)" 2
assert_lacks "with the watchdog off nothing reports a launch failure" "$(cat "$work/launchoff.out")" "could not launch"
reset_reports

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

echo "# optional resolved identity evidence leaves default selection unchanged"
status=$(run_filtered identityexport "IntentTests/DemoFixturesTests" test-without-building ONLY_TESTING_IDENTITIES_PATH="$work/identities.json")
assert_eq "requested identity export exits 0" "$status" 0
assert_eq "identity export adds no xcodebuild invocation" "$(argv_count identityexport)" 2
assert_eq "identity export retains the actual resolver matches" \
  "$(python3 -c 'import json, sys; d=json.load(open(sys.argv[1])); print(d["version"]); print("\n".join(d["selectors"]["IntentTests/DemoFixturesTests"]))' "$work/identities.json")" \
  $'1\nIntentTests/DemoFixturesTests/testFoo()\nIntentTests/DemoFixturesTests/testBar()'
status=$(run_filtered identityfailure "IntentTests/DemoFixturesTests" test-without-building ONLY_TESTING_IDENTITIES_PATH="$work")
assert_eq "failed requested identity export exits 83" "$status" 83
assert_eq "failed identity export never starts tests" "$(argv_count identityfailure)" 1
assert_lock_free "failed identity export releases the simulator lock"
status=$(run_filtered identityempty "" test-without-building ONLY_TESTING_IDENTITIES_PATH="$work/empty-identities.json")
assert_eq "unfiltered identity knob does not change the exit" "$status" 0
assert_eq "unfiltered identity knob adds no enumeration" "$(argv_count identityempty)" 1
[ ! -e "$work/empty-identities.json" ] && pass "unfiltered run writes no identity evidence" || fail "unfiltered run exported identities"

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

echo "# UI-only builds and runs exclude unit tests without bypassing selector validation"
status=$(run_filtered uibuild "" build-for-testing-ui)
assert_eq "UI-only build exits 0" "$status" 0
assert_eq "UI-only build compiles once without launching tests" "$(argv_count uibuild)" 1
assert_contains "UI-only build uses the UI scheme" "$(argv_line uibuild 1)" '[-scheme] [IntentUI]'
assert_contains "UI-only build preserves signing" "$(argv_line uibuild 1)" \
  '[CODE_SIGN_IDENTITY=] [CODE_SIGNING_REQUIRED=NO] [CODE_SIGNING_ALLOWED=NO]'
status=$(run_filtered ui "" test-without-building-ui)
assert_eq "UI-only run defaults to the whole UI bundle" "$status" 0
assert_eq "UI-only run enumerates then executes" "$(argv_count ui)" 2
assert_contains "UI enumeration excludes unit tests" "$(argv_line ui 1)" '[-skip-testing:IntentTests]'
assert_contains "UI enumeration uses the UI scheme" "$(argv_line ui 1)" '[-scheme] [IntentUI]'
assert_lacks "UI enumeration preserves the unfiltered UI catalog" "$(argv_line ui 1)" '-only-testing:'
assert_contains "UI run remains serial" "$(argv_line ui 2)" '[-parallel-testing-enabled] [NO]'
assert_contains "UI run uses the same scheme as its build" "$(argv_line ui 2)" '[-scheme] [IntentUI]'
assert_contains "UI run selects all UI tests and excludes units" "$(argv_line ui 2)" \
  '[-only-testing:IntentUITests] [-skip-testing:IntentTests]'
assert_contains "UI run validates execution from the result bundle" "$(cat "$work/ui.out")" \
  '  IntentUITests         1         1        0       0'
assert_lock_free "UI-only run releases the simulator lock"
status=$(run_filtered uisubset 'IntentUITests/ConversationTranscriptScrollUITests' test-without-building-ui)
assert_eq "UI-only run supports a narrower UI selector" "$status" 0
assert_contains "UI subset is forwarded" "$(argv_line uisubset 2)" \
  '[-only-testing:IntentUITests/ConversationTranscriptScrollUITests] [-skip-testing:IntentTests]'
status=$(run_filtered uiunits 'IntentTests/DemoFixturesTests' test-without-building-ui)
assert_eq "UI-only run rejects unit selectors" "$status" 82
assert_eq "excluded unit selector never runs tests" "$(argv_count uiunits)" 1
assert_contains "UI-only rejection explains the command restriction" "$(cat "$work/uiunits.out")" \
  'UI-only subcommands skip the IntentTests bundle'
status=$(run_filtered uitypo 'IntentUITests/MissingTests' test-without-building-ui)
assert_eq "UI-only run rejects a missing selector" "$status" 82
assert_eq "missing UI selector never runs tests" "$(argv_count uitypo)" 1
status=$(run_filtered uinobundle '' test-without-building-ui STUB_NO_BUNDLE=1 RESULT_BUNDLE="$work/ui-missing.xcresult")
assert_eq "UI-only run cannot pass without result evidence" "$status" 83
status=$(run_filtered uicrash '' test-without-building-ui STUB_MODE=marker STUB_THEN=pass \
  STUB_STATE="$work/uicrash.state" STUB_NO_FAILING=1 DERIVED_DATA_DIR="$work/UI Derived Data" \
  STUB_MARKER='Restarting after unexpected exit, crash, or test timeout in IntentUITests.ConversationTranscriptScrollUITests/testGoToEndButtonAppears(); summary will include totals from previous launches.')
assert_eq "UI-only crash retry recovers" "$status" 0
assert_eq "UI-only crash makes one enumeration and exactly two test calls" "$(argv_count uicrash)" 3
assert_contains "UI retry stays serial and scoped to the interrupted suite" "$(retry_argv uicrash)" \
  '[-only-testing:IntentUITests/ConversationTranscriptScrollUITests] [-skip-testing:IntentTests]'
assert_contains "UI retry stays serial" "$(retry_argv uicrash)" '[-parallel-testing-enabled] [NO]'
assert_contains "UI retry uses the same scheme" "$(retry_argv uicrash)" '[-scheme] [IntentUI]'
while IFS= read -r line; do
  assert_contains "UI enumeration, execution and retry share derived data" "$line" \
    "[-derivedDataPath] [$work/UI Derived Data]"
done < <(grep '^argv:' "$work/uicrash.args")
assert_lock_free "UI-only crash retry releases the simulator lock"
if python3 - <<'PY'
from pathlib import Path
import xml.etree.ElementTree as ET

schemes = Path("Intent.xcodeproj/xcshareddata/xcschemes")
full = ET.parse(schemes / "Intent.xcscheme").getroot()
ui = ET.parse(schemes / "IntentUI.xcscheme").getroot()
def structure(element):
    return (element.tag, element.attrib, (element.text or "").strip(),
            [structure(child) for child in element])
def name(testable):
    return testable.find("BuildableReference").get("BlueprintName")
full_tests = full.findall("TestAction/Testables/TestableReference")
ui_tests = ui.findall("TestAction/Testables/TestableReference")
assert [name(t) for t in ui_tests] == ["IntentUITests"], "UI scheme must contain only the UI bundle"
original = next(t for t in full_tests if name(t) == "IntentUITests")
assert structure(original) == structure(ui_tests[0]), "UI coverage/skips must match the full scheme"
assert full.find("TestAction").attrib == ui.find("TestAction").attrib, "Test configurations must match"
app = full.find("BuildAction/BuildActionEntries/BuildActionEntry/BuildableReference")
ui_builds = ui.findall("BuildAction/BuildActionEntries/BuildActionEntry")
assert len(ui_builds) == 1 and ui_builds[0].get("buildForTesting") == "YES"
assert structure(app) == structure(ui_builds[0].find("BuildableReference")), "Both schemes must build the same app"
PY
then
  pass "UI scheme preserves full-scheme coverage and excludes unit build inputs"
else
  fail "UI scheme differs from the full scheme's UI test contract"
fi
for sub in build-for-testing-ui test-without-building-ui; do
  status=$(run_filtered "release-$sub" '' "$sub" BUILD_CONFIGURATION=Release)
  assert_eq "Release $sub exits 0" "$status" 0
  while IFS= read -r line; do
    assert_contains "Release $sub preserves configuration and testability" "$line" \
      '[-configuration] [Release] [ENABLE_TESTABILITY=YES]'
  done < <(grep '^argv:' "$work/release-$sub.args")
done

echo "# explicit configuration: default argv is unchanged; Release is not DEBUG"
status=$(run_filtered defaultbuild "" build-ios)
assert_eq "default iOS build exits 0" "$status" 0
assert_eq "default iOS build keeps its exact destination and signing argv" "$(argv_line defaultbuild 1)" \
  'argv: [build] [-project] [Intent.xcodeproj] [-scheme] [Intent] [-destination] [generic/platform=iOS Simulator] [CODE_SIGN_IDENTITY=] [CODE_SIGNING_REQUIRED=NO] [CODE_SIGNING_ALLOWED=NO]'
status=$(run_filtered devicebuild "" build-ios-device DEVICE_UDID=00008160-000925E83EC0000A)
assert_eq "device build exits 0" "$status" 0
assert_eq "device build pins its destination and preserves project signing" "$(argv_line devicebuild 1)" \
  'argv: [build] [-project] [Intent.xcodeproj] [-scheme] [Intent] [-destination] [platform=iOS,id=00008160-000925E83EC0000A]'
status=$(run_filtered missingdevice "" build-ios-device DEVICE_UDID=)
assert_eq "device build refuses missing identifier" "$status" 1
assert_eq "missing device never invokes Xcode" "$(wc -l < "$work/missingdevice.args" | tr -d ' ')" 0
status=$(run_filtered invaliddevice "" build-ios-device 'DEVICE_UDID=device,platform=iOS Simulator')
assert_eq "device build refuses destination injection" "$status" 1
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
echo "# derived data is shared within a job, including enumeration and retries"
derived_data="$work/Derived Data"
for sub in resolve build-ios build-visionos build-for-testing build-for-testing-ui test-ios test-ios-unit test-without-building test-without-building-unit test-without-building-ui; do
  derived_selector=IntentTests/DemoFixturesTests
  case "$sub" in
    build-for-testing-ui|test-without-building-ui) derived_selector=IntentUITests ;;
  esac
  status=$(run_filtered "derived-$sub" "$derived_selector" "$sub" DERIVED_DATA_DIR="$derived_data")
  assert_eq "$sub with explicit derived data exits 0" "$status" 0
  args=$(grep '^argv:' "$work/derived-$sub.args" | grep -v -F '[-showsdks]')
  while IFS= read -r line; do
    assert_contains "$sub forwards the derived data path as one argument" "$line" \
      "[-derivedDataPath] [$derived_data]"
  done <<< "$args"
done
assert_eq "derived data test run covers build, enumeration, and execution" "$(argv_count derived-test-ios-unit)" 3
status=$(run_filtered emptyderived "" build-ios DERIVED_DATA_DIR=)
assert_eq "empty derived data keeps the default argv" "$(argv_line emptyderived 1)" "$(argv_line defaultbuild 1)"
status=$(run_filtered derivedcrash "" test-without-building-unit DERIVED_DATA_DIR="$derived_data" \
  STUB_MODE=crash STUB_THEN=pass STUB_STATE="$work/derivedcrash.state")
assert_eq "derived data crash retry recovers" "$status" 0
assert_eq "derived data crash retries exactly once" "$(argv_count derivedcrash)" 2
assert_contains "initial test uses the requested derived data" "$(argv_line derivedcrash 1)" \
  "[-derivedDataPath] [$derived_data]"
assert_contains "crash retry uses the same derived data" "$(argv_line derivedcrash 2)" \
  "[-derivedDataPath] [$derived_data]"

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

echo "# full UI shards use one built inventory, exact selectors, and verified identities"
cat > "$work/full-catalog.json" <<'EOF'
{"values":[{"enabledTests":[
  {"identifier":"IntentUITests/Alpha/testOne()"},
  {"identifier":"IntentUITests/Beta/testTwo()"}],
  "disabledTests":[{"identifier":"IntentUITests/AppStoreScreenshotTests/testCapture()"}]}]}
EOF
make_results "$work/full-results.json" \
  "IntentUITests/Alpha/testOne()=Passed" "IntentUITests/Beta/testTwo()=Passed"
for shard in 1 2; do
  mkdir -p "$work/plans/$shard"
  status=$(run_filtered "fullshard$shard" "" test-without-building-ui \
    UI_TEST_SHARD="$shard" STUB_CATALOG="$work/full-catalog.json" STUB_RESULTS="$work/full-results.json" \
    UI_TEST_SHARD_PLAN_PATH="$work/plans/$shard/ui-test-shard-plan.json" \
    ONLY_TESTING_IDENTITIES_PATH="$work/plans/$shard/ui-test-identities.json" GITHUB_SHA=fixture)
  assert_eq "full shard $shard passes" "$status" 0
  assert_eq "full shard $shard enumerates once then tests" "$(argv_count "fullshard$shard")" 2
done
assert_contains "first shard only selects Alpha" "$(argv_line fullshard1 2)" "[-only-testing:IntentUITests/Alpha/testOne]"
assert_lacks "first shard does not select Beta" "$(argv_line fullshard1 2)" "-only-testing:IntentUITests/Beta"
assert_contains "second shard only selects Beta" "$(argv_line fullshard2 2)" "[-only-testing:IntentUITests/Beta/testTwo]"
status=0
python3 scripts/ui_full_tests.py --verify-plans "$work/plans" --revision fixture > "$work/plan-verification.out" 2>&1 || status=$?
assert_eq "both actual resolved identity exports agree with the plans" "$status" 0

for mode in invalid narrow wrongcommand; do
  case "$mode" in
    invalid) shard=3; only=; command=test-without-building-ui ;;
    narrow) shard=1; only=IntentUITests/Alpha; command=test-without-building-ui ;;
    wrongcommand) shard=1; only=; command=test-without-building-unit ;;
  esac
  status=$(run_filtered "full-$mode" "$only" "$command" UI_TEST_SHARD="$shard")
  assert_eq "invalid full-shard mode $mode fails before native work" "$status" 1
  assert_eq "invalid full-shard mode $mode makes no native calls" "$(argv_count "full-$mode")" 0
done
status=$(run_filtered fullplanfailure "" test-without-building-ui UI_TEST_SHARD=1 \
  STUB_CATALOG="$work/full-catalog.json" UI_TEST_SHARD_PLAN_PATH="$work/missing/plan.json")
assert_eq "failed full-shard evidence export exits 83" "$status" 83
assert_eq "failed full-shard evidence export never runs tests" "$(argv_count fullplanfailure)" 1
status=$(run_filtered fullinventoryfailure "" test-without-building-ui UI_TEST_SHARD=1)
assert_eq "incomplete full inventory exits 83" "$status" 83
assert_eq "incomplete full inventory never runs tests" "$(argv_count fullinventoryfailure)" 1
status=$(run_filtered fullnativefailure "" test-without-building-ui UI_TEST_SHARD=1 \
  STUB_CATALOG="$work/full-catalog.json" STUB_RESULTS="$work/full-results.json" STUB_MODE=fail)
assert_eq "full shard preserves native failure exit 65" "$status" 65

# pick-simulator without SIM_UDID: the newest iOS runtime the selected Xcode's
# SDK can run wins over an "iPhone 16" on an older runtime (ios#905).
cat > "$work/sims.json" <<'EOF'
{"devices": {
  "com.apple.CoreSimulator.SimRuntime.watchOS-12-0": [
    {"name": "Apple Watch Series 11 (46mm)", "udid": "99999999-0000-0000-0000-000000000001", "isAvailable": true}],
  "com.apple.CoreSimulator.SimRuntime.iOS-18-2": [
    {"name": "iPhone 16", "udid": "18181818-0000-0000-0000-000000000016", "isAvailable": true},
    {"name": "iPhone 16 Pro", "udid": "18181818-0000-0000-0000-000000000017", "isAvailable": true}],
  "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
    {"name": "iPad Pro 13-inch (M5)", "udid": "26262626-0000-0000-0000-00000000000a", "isAvailable": true},
    {"name": "iPhone 17 Pro", "udid": "26262626-0000-0000-0000-000000000171", "isAvailable": true},
    {"name": "iPhone 17", "udid": "26262626-0000-0000-0000-000000000170", "isAvailable": true}],
  "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
    {"name": "iPhone 18 Pro", "udid": "27272727-0000-0000-0000-000000000181", "isAvailable": true},
    {"name": "iPhone 18", "udid": "27272727-0000-0000-0000-000000000180", "isAvailable": true},
    {"name": "iPhone 18 Pro Max", "udid": "27272727-0000-0000-0000-000000000182", "isAvailable": true}]
}}
EOF
cat > "$work/sims-iphone16.json" <<'EOF'
{"devices": {
  "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
    {"name": "iPhone 17", "udid": "26262626-0000-0000-0000-000000000170", "isAvailable": true},
    {"name": "iPhone 16", "udid": "26262626-0000-0000-0000-000000000160", "isAvailable": true}]
}}
EOF
cat > "$work/sims-numeric.json" <<'EOF'
{"devices": {
  "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
    {"name": "iPhone 17", "udid": "26262626-0000-0000-0000-000000000170", "isAvailable": true}],
  "com.apple.CoreSimulator.SimRuntime.iOS-26-10": [
    {"name": "iPhone 17 Pro", "udid": "2626260a-0000-0000-0000-000000000171", "isAvailable": true},
    {"name": "iPhone 17 Pro Max", "udid": "2626260a-0000-0000-0000-000000000172", "isAvailable": true}]
}}
EOF
cat > "$work/sims-none.json" <<'EOF'
{"devices": {
  "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
    {"name": "iPad Air 11-inch (M4)", "udid": "27272727-0000-0000-0000-0000000000a1", "isAvailable": true}]
}}
EOF
# pick <name> <fixture> [env...]: the picked UDID on stdout, stderr in $work/<name>.err,
# exit status in $work/<name>.status.
pick() {
  local name=$1 fixture=$2 status=0
  shift 2
  env -u SIM_UDID STUB_SIMCTL_DEVICES="$fixture" "$@" "$SCRIPT" pick-simulator \
    2> "$work/$name.err" || status=$?
  echo "$status" > "$work/$name.status"
}
assert_eq "pick prefers the newest runtime over an older iPhone 16" \
  "$(pick newest "$work/sims.json" STUB_SDK_VERSION=27.2)" 27272727-0000-0000-0000-000000000180
assert_contains "pick names the device and its runtime" "$(cat "$work/newest.err")" \
  "Selected simulator: iPhone 18 (iOS 27.0) (27272727-0000-0000-0000-000000000180)"
assert_eq "pick skips runtimes newer than the selected Xcode's SDK" \
  "$(pick sdkcap "$work/sims.json" STUB_SDK_VERSION=26.2)" 26262626-0000-0000-0000-000000000170
assert_eq "pick falls back to the newest runtime when the SDK version is unknown" \
  "$(pick nosdk "$work/sims.json")" 27272727-0000-0000-0000-000000000180
assert_eq "pick compares runtime versions numerically and takes the first iPhone when no base model exists" \
  "$(pick numeric "$work/sims-numeric.json" STUB_SDK_VERSION=26.4)" 2626260a-0000-0000-0000-000000000171
assert_eq "pick keeps preferring iPhone 16 within the newest runtime" \
  "$(pick prefer16 "$work/sims-iphone16.json" STUB_SDK_VERSION=26.4)" 26262626-0000-0000-0000-000000000160
pick none "$work/sims-none.json" STUB_SDK_VERSION=27.2 > /dev/null
assert_eq "pick fails without an available iPhone" "$(cat "$work/none.status")" 1
assert_contains "pick explains the missing iPhone" "$(cat "$work/none.err")" "no available iPhone simulator"
pick capnone "$work/sims.json" STUB_SDK_VERSION=17.0 > /dev/null
assert_eq "pick fails when every iPhone runtime is newer than the SDK" "$(cat "$work/capnone.status")" 1
printf '{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [' > "$work/sims-truncated.json"
pick badjson "$work/sims-truncated.json" STUB_SDK_VERSION=27.2 > /dev/null
assert_eq "pick fails on an unreadable simulator list" "$(cat "$work/badjson.status")" 1
assert_contains "pick reports an unreadable list, not a missing iPhone" "$(cat "$work/badjson.err")" \
  "could not read the simulator list"
assert_lacks "pick does not blame a missing iPhone for an unreadable list" "$(cat "$work/badjson.err")" \
  "no available iPhone simulator"
pick simctlfail "$work/sims.json" STUB_SDK_VERSION=27.2 STUB_SIMCTL_FAIL=1 > /dev/null
assert_eq "pick fails when simctl fails" "$(cat "$work/simctlfail.status")" 1
assert_contains "pick names the failed simctl call" "$(cat "$work/simctlfail.err")" \
  "xcrun simctl list devices available -j failed"

echo
if [ "$failures" -eq 0 ]; then
  echo "all xcodebuild.sh self-tests passed"
else
  echo "$failures xcodebuild.sh self-test(s) FAILED" >&2
  exit 1
fi
