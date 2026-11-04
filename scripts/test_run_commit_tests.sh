#!/usr/bin/env bash
# Self-tests for scripts/run_commit_tests.sh. A throwaway origin repository
# holds a fake scripts/xcodebuild.sh that records what it was given and writes
# canned results; xcrun and xcodebuild are stubs on PATH. Needs only bash
# (including the stock macOS Bash 3.2), git and python3, and never touches
# Xcode or a simulator. When zsh is installed, the recorded rerun command is
# also replayed under zsh.
#
# Usage: scripts/test_run_commit_tests.sh
set -euo pipefail

cd "$(dirname "$0")/.."
SCRIPT=$PWD/scripts/run_commit_tests.sh

work=$(mktemp -d "${TMPDIR:-/tmp}/run-commit-tests-selftest.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
export TMPDIR=$work
unset BUILD_CONFIGURATION SIM_UDID SPM_CLONE_DIR TEST_CRASH_RETRY SIM_LOCK_TIMEOUT SIM_LOCK_DIR
unset TAILCATKIT_AUTOBUILD KEEP_CHECKOUT ONLY_TESTING RESULT_BUNDLE DERIVED_DATA_DIR
for name in $(env | sed -n 's/^\(TEST_RUNNER_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$name"; done
export GIT_AUTHOR_NAME=selftest GIT_AUTHOR_EMAIL=selftest@example.invalid
export GIT_COMMITTER_NAME=selftest GIT_COMMITTER_EMAIL=selftest@example.invalid
export GIT_CONFIG_NOSYSTEM=1 HOME=$work/home
mkdir -p "$HOME"
git config --global init.defaultBranch main
git config --global advice.detachedHead false

# xcrun prints <bundle>/tests.json for an xcresulttool query; xcodebuild only
# answers -version.
stubs=$work/bin
mkdir -p "$stubs"
cat > "$stubs/xcrun" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" xcresulttool get test-results tests --path "*)
    for last in "$@"; do :; done
    cat "$last/tests.json" ;;
esac
EOF
cat > "$stubs/xcodebuild" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -version ] && { echo "Xcode 99.0"; echo "Build version 99A1"; exit 0; }
exit 1
EOF
chmod +x "$stubs/xcrun" "$stubs/xcodebuild"
export PATH="$stubs:$PATH"

# The fake wrapper writes what it saw to $STUB_RECORD, builds a stand-in
# TailcatKit.xcframework when none exists (without its final LICENSE.tailcat
# under STUB_TAILCAT_PARTIAL=1), then acts out $STUB_OUTCOME: pass/fail copy
# $STUB_RESULTS into the result bundle (fail exits 65 with an error line),
# buildfail exits 65 without a bundle, crash also writes $STUB_RETRY_RESULTS
# to the re-run bundle and exits 0, and sleep waits on a foreground pipeline
# like the real wrapper's xcodebuild call: it writes the sleeping process's PID
# to $STUB_SLEEP_PID, touches $STUB_STARTED, and with STUB_IGNORE_TERM=1
# ignores TERM (as does the sleep). STUB_STRAY=<pidfile> first starts a
# "compiler" in its own session (outside the wrapper's process group, like
# Xcode's swift-frontend) that keeps writing into the checkout for 30s.
# STUB_LOCKED=1 leaves a read-only directory that cannot be deleted.
origin=$work/origin
mkdir -p "$origin/scripts" "$origin/TailcatKit"
cat > "$origin/scripts/xcodebuild.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
{
  echo "argv: $*"
  echo "only: ${ONLY_TESTING:-}"
  echo "bundle: ${RESULT_BUNDLE:-}"
  echo "derived: ${DERIVED_DATA_DIR:-}"
  echo "config: ${BUILD_CONFIGURATION:-}"
  echo "runner: ${TEST_RUNNER_FOO:-}"
  echo "pwd: $PWD"
  echo "head: $(git rev-parse HEAD)"
  echo "marker: $(cat marker.txt)"
  if [ -e dirty.txt ]; then echo "dirty: yes"; else echo "dirty: no"; fi
  if [ -d TailcatKit/build/TailcatKit.xcframework ]; then echo "tailcat: present"; else echo "tailcat: missing"; fi
} > "$STUB_RECORD"
if [ ! -d TailcatKit/build/TailcatKit.xcframework ]; then
  mkdir -p TailcatKit/build/TailcatKit.xcframework
  [ -n "${STUB_TAILCAT_PARTIAL:-}" ] || echo license > TailcatKit/build/TailcatKit.xcframework/LICENSE.tailcat
fi
echo "Building..."
if [ -n "${STUB_STRAY:-}" ]; then
  python3 -c '
import os, sys, time
if os.fork():
    sys.exit(0)
os.setsid()
out = sys.argv[1]
open(sys.argv[2], "w").write(str(os.getpid()))
end, i = time.time() + 30, 0
while time.time() < end:
    try:
        os.makedirs(out, exist_ok=True)
        open(os.path.join(out, "obj%d.o" % i), "w").close()
    except OSError:
        pass
    i += 1
    time.sleep(0.01)
' "$PWD/DerivedStray/Objects" "$STUB_STRAY" < /dev/null > /dev/null 2>&1
  tries=0
  while [ ! -s "$STUB_STRAY" ] && [ "$tries" -lt 100 ]; do sleep 0.05; tries=$((tries + 1)); done
fi
if [ -n "${STUB_LOCKED:-}" ]; then
  mkdir -p locked && : > locked/file && chmod 555 locked
fi
case "${STUB_OUTCOME:-pass}" in
  pass)
    mkdir -p "$RESULT_BUNDLE"; cp "$STUB_RESULTS" "$RESULT_BUNDLE/tests.json"
    echo "** TEST SUCCEEDED **" ;;
  fail)
    mkdir -p "$RESULT_BUNDLE"; cp "$STUB_RESULTS" "$RESULT_BUNDLE/tests.json"
    echo "/repo/IntentTests/FooTests.swift:12: error: -[IntentTests.FooTests testBar] : XCTAssertEqual failed"
    echo "** TEST FAILED **"
    exit 65 ;;
  buildfail)
    echo "/repo/Intent/Foo.swift:3:5: error: cannot find 'bar' in scope"
    echo "** BUILD FAILED **"
    exit 65 ;;
  crash)
    mkdir -p "$RESULT_BUNDLE" "${RESULT_BUNDLE%.xcresult}-retry.xcresult"
    cp "$STUB_RESULTS" "$RESULT_BUNDLE/tests.json"
    cp "$STUB_RETRY_RESULTS" "${RESULT_BUNDLE%.xcresult}-retry.xcresult/tests.json"
    echo "Restarting after unexpected exit, crash, or test timeout" ;;
  sleep)
    if [ -n "${STUB_IGNORE_TERM:-}" ]; then
      trap '' TERM
    else
      trap 'echo "terminated" >> "$STUB_RECORD"; exit 143' TERM
    fi
    ( exec sh -c 'echo $$ > "$STUB_SLEEP_PID"; : > "$STUB_STARTED"; exec sleep 30' ) 2>&1 | cat ;;
esac
EOF
chmod +x "$origin/scripts/xcodebuild.sh"
echo "module tailcatkit" > "$origin/TailcatKit/go.mod"
git -C "$origin" init --quiet
git -C "$origin" config uploadpack.allowAnySHA1InWant true
echo A > "$origin/marker.txt"
git -C "$origin" add -A
git -C "$origin" commit --quiet -m "commit A"
sha_a=$(git -C "$origin" rev-parse HEAD)
echo B > "$origin/marker.txt"
git -C "$origin" commit --quiet -am "commit B"
sha_b=$(git -C "$origin" rev-parse HEAD)

# The Mac's clone, with uncommitted changes that must not reach the run.
src=$work/src
git clone --quiet "$origin" "$src"
echo dirty > "$src/dirty.txt"
echo LOCAL > "$src/marker.txt"

# Commits that exist only on origin: one on a branch, one reachable only by SHA.
git -C "$origin" checkout --quiet -b feature
echo C > "$origin/marker.txt"
git -C "$origin" commit --quiet -am "commit C"
sha_c=$(git -C "$origin" rev-parse HEAD)
git -C "$origin" checkout --quiet -b other main
echo D > "$origin/marker.txt"
git -C "$origin" commit --quiet -am "commit D"
sha_d=$(git -C "$origin" rev-parse HEAD)
git -C "$origin" checkout --quiet main

# make_results <file> <Target/Suite/test=Result[=failure message]>...
make_results() {
  python3 - "$@" <<'EOF'
import json, sys
out, bundles = sys.argv[1], {}
for spec in sys.argv[2:]:
    parts = spec.split("=", 2)
    ident, result = parts[0], parts[1]
    message = parts[2] if len(parts) > 2 else None
    target, suite, test = ident.split("/", 2)
    bundles.setdefault(target, {}).setdefault(suite, []).append((test, result, message))
targets = []
for target, suites in bundles.items():
    kind = "UI test bundle" if target.endswith("UITests") else "Unit test bundle"
    children = []
    for suite, tests in suites.items():
        cases = []
        for test, result, message in tests:
            case = {"name": test, "nodeType": "Test Case", "nodeIdentifier": suite + "/" + test, "result": result}
            if message:
                case["children"] = [{"name": message, "nodeType": "Failure Message", "result": "Failed"}]
            cases.append(case)
        children.append({"name": suite, "nodeType": "Test Suite", "nodeIdentifier": suite, "result": "Passed", "children": cases})
    targets.append({"name": target, "nodeType": kind, "result": "Passed", "children": children})
doc = {"testNodes": [{"name": "Intent", "nodeType": "Test Plan", "result": "Passed", "children": targets}]}
with open(out, "w") as f:
    json.dump(doc, f, indent=2)
EOF
}
make_results "$work/pass.json" \
  "IntentTests/FooTests/testBar()=Passed" \
  "IntentTests/FooTests/testQux()=Passed" \
  "IntentTests/BarTests/testBaz()=Passed" \
  "IntentTests/BarTests/needsDevice()=Skipped"
make_results "$work/fail.json" \
  "IntentTests/FooTests/testBar()=Failed=FooTests.swift:12: XCTAssertEqual failed: (\"1\") is not equal to (\"2\")" \
  "IntentTests/FooTests/testQux()=Passed"
make_results "$work/crash.json" \
  "IntentTests/FooTests/testBar()=Passed" \
  "IntentTests/BarTests/testBaz()=Failed=crashed"
make_results "$work/crash-retry.json" \
  "IntentTests/BarTests/testBaz()=Passed"
# A parameterized Swift Testing case keeps its failure message under an
# argument node.
python3 - "$work/fail.json" "$work/param-fail.json" <<'EOF2'
import json, sys
doc = json.load(open(sys.argv[1]))
case = doc["testNodes"][0]["children"][0]["children"][0]["children"][0]
case["children"] = [{"name": "width: 320", "nodeType": "Arguments", "result": "Failed",
                     "children": [{"name": "Expectation failed: width == 375", "nodeType": "Failure Message"}]}]
json.dump(doc, open(sys.argv[2], "w"))
EOF2

export INTENT_IOS_TEST_RUN_DIR=$work/runs-main
export STUB_RECORD=$work/record
export STUB_RESULTS=$work/pass.json

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
# run <name> [env...] -- <args...>: exit status on stdout, output in $work/<name>.out.
run() {
  local name=$1 status=0
  shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  rm -f "$STUB_RECORD"
  env ${envs[@]+"${envs[@]}"} "$SCRIPT" --repo "$src" "$@" > "$work/$name.out" 2>&1 || status=$?
  echo "$status"
}
summary() { cat "$INTENT_IOS_TEST_RUN_DIR/summary.md"; }
record() { sed -n "s/^$1: //p" "$STUB_RECORD"; }
summary_field() { summary | sed -n "s/^- $1: //p"; }

# A passing focused run of a commit the clone already has.
status=$(run pass -- "$sha_a" 'IntentTests/FooTests' 'IntentTests/BarTests/testBaz() IntentTests/BarTests/needsDevice()')
assert_eq "passing run exits 0" "$status" 0
assert_contains "passing run is PASSED" "$(summary)" "# iOS test run: PASSED"
assert_contains "summary names the commit" "$(summary)" "- Commit: $sha_a (commit A)"
assert_contains "summary counts FooTests" "$(summary)" "| IntentTests/FooTests | 2 | 2 | 0 | 0 |"
assert_contains "summary counts BarTests with a skip" "$(summary)" "| IntentTests/BarTests | 1 | 1 | 0 | 1 |"
assert_contains "summary totals" "$(summary)" "| **Total** | 3 | 3 | 0 | 1 |"
assert_contains "summary records the Xcode version" "$(summary)" "Xcode 99.0"
assert_lacks "passing run lists no failing tests" "$(summary)" "Failing tests"
assert_contains "stdout ends with the summary" "$(cat "$work/pass.out")" "# iOS test run: PASSED"
assert_eq "unit selectors run test-ios-unit" "$(record argv)" "test-ios-unit"
assert_eq "selectors become ONLY_TESTING" "$(record only)" "IntentTests/FooTests IntentTests/BarTests/testBaz() IntentTests/BarTests/needsDevice()"
assert_eq "the run checks out the requested commit" "$(record head)" "$sha_a"
assert_eq "committed content is used, not the clone's working tree" "$(record marker)" "A"
assert_eq "untracked files do not leak into the checkout" "$(record dirty)" "no"
checkout=$(record pwd)
derived=$(record derived)
assert_lacks "derived data lives outside the checkout" "$derived" "$checkout/"
assert_eq "derived data is private to the run" "$(dirname "$derived")" "$(dirname "$checkout")"
if [ -e "$checkout" ]; then fail "the temporary checkout is removed"; else pass "the temporary checkout is removed"; fi
log=$(summary_field Log)
if [ -f "$log" ]; then pass "the log is kept"; else fail "the log is kept: $log"; fi
assert_contains "the log holds the wrapper output" "$(cat "$log")" "** TEST SUCCEEDED **"
if [ -e "$(record bundle)" ]; then fail "a passing run's bundle is deleted"; else pass "a passing run's bundle is deleted"; fi
if [ -f "$(dirname "$log")/summary.md" ]; then pass "the run directory keeps a summary copy"; else fail "the run directory keeps a summary copy"; fi
assert_eq "the clone's working tree is untouched" "$(cat "$src/marker.txt")" "LOCAL"

# The rerun command alone repeats the run, in bash and (when present) zsh.
rerun=$(summary_field Rerun)
assert_contains "rerun names the commit" "$rerun" "'$sha_a'"
assert_contains "rerun quotes a selector with parentheses" "$rerun" "'IntentTests/BarTests/testBaz()'"
rm -f "$STUB_RECORD"
status=0
(cd / && bash -c "$rerun") > "$work/rerun-bash.out" 2>&1 || status=$?
assert_eq "rerun under bash exits 0" "$status" 0
assert_eq "rerun under bash runs the same commit" "$(record head)" "$sha_a"
assert_eq "rerun under bash runs the same selectors" "$(record only)" "IntentTests/FooTests IntentTests/BarTests/testBaz() IntentTests/BarTests/needsDevice()"
anywhere=$(summary_field "Rerun from any iOS clone")
assert_contains "the portable rerun is relative to an iOS clone" "$anywhere" " scripts/run_commit_tests.sh '$sha_a' 'IntentTests/FooTests' 'IntentTests/BarTests/testBaz()' 'IntentTests/BarTests/needsDevice()'"
# Replayed from inside another clone that has the script (untracked here).
cp "$SCRIPT" "$src/scripts/run_commit_tests.sh"
rm -f "$STUB_RECORD"
status=0
(cd "$src" && bash -c "$anywhere") > "$work/rerun-anywhere.out" 2>&1 || status=$?
rm -f "$src/scripts/run_commit_tests.sh"
assert_eq "the portable rerun works from an iOS clone" "$status" 0
assert_eq "the portable rerun runs the same commit" "$(record head)" "$sha_a"
if command -v zsh >/dev/null 2>&1; then
  rm -f "$STUB_RECORD"
  status=0
  (cd / && zsh -c "$rerun") > "$work/rerun-zsh.out" 2>&1 || status=$?
  assert_eq "rerun under zsh exits 0" "$status" 0
  assert_eq "rerun under zsh runs the same selectors" "$(record only)" "IntentTests/FooTests IntentTests/BarTests/testBaz() IntentTests/BarTests/needsDevice()"
else
  echo "skip - zsh is not installed; the rerun command was replayed under bash only"
fi

# A failing suite: exit 65, the failing test and its message are named.
status=$(run fail STUB_OUTCOME=fail STUB_RESULTS="$work/fail.json" -- "$sha_b" 'IntentTests/FooTests')
assert_eq "failing run passes through exit 65" "$status" 65
assert_contains "failing run is FAILED" "$(summary)" "# iOS test run: FAILED (exit 65: build or test failure)"
assert_contains "failing run counts the failure" "$(summary)" "| IntentTests/FooTests | 2 | 1 | 1 | 0 |"
assert_contains "failing run names the failing test" "$(summary)" '- `IntentTests/FooTests/testBar()`: FooTests.swift:12: XCTAssertEqual failed: ("1") is not equal to ("2")'
assert_contains "failing run quotes the log's errors" "$(summary)" "error: -[IntentTests.FooTests testBar]"
bundle=$(summary_field "Result bundle")
if [ -d "$bundle" ]; then pass "a failing run keeps its bundle"; else fail "a failing run keeps its bundle: '$bundle'"; fi
assert_eq "commit B is checked out" "$(record marker)" "B"
status=$(run paramfail STUB_OUTCOME=fail STUB_RESULTS="$work/param-fail.json" -- "$sha_b" 'IntentTests/FooTests')
assert_contains "a parameterized failure shows its nested message" "$(summary)" '- `IntentTests/FooTests/testBar()`: Expectation failed: width == 375'

# A build failure: no results, the compiler error is quoted.
status=$(run buildfail STUB_OUTCOME=buildfail -- "$sha_b" 'IntentTests')
assert_eq "build failure exits 65" "$status" 65
assert_contains "build failure says no test ran" "$(summary)" "No test results: the build or the test setup failed before any test ran."
assert_contains "build failure quotes the compiler error" "$(summary)" "error: cannot find 'bar' in scope"
assert_contains "build failure quotes BUILD FAILED" "$(summary)" "** BUILD FAILED **"

# A crash the wrapper's re-run recovered from: re-run results win.
status=$(run crash STUB_OUTCOME=crash STUB_RESULTS="$work/crash.json" STUB_RETRY_RESULTS="$work/crash-retry.json" -- "$sha_b" 'IntentTests')
assert_eq "recovered crash exits 0" "$status" 0
assert_contains "recovered crash uses the re-run result" "$(summary)" "| IntentTests/BarTests | 1 | 1 | 0 | 0 |"
assert_contains "recovered crash is called out" "$(summary)" "re-ran the interrupted suites"

# A UI selector switches to test-ios.
status=$(run ui -- "$sha_b" 'IntentTests/FooTests' 'IntentUITests/WorkspaceChangesUITests')
assert_eq "UI run exits 0" "$status" 0
assert_eq "a UI selector runs test-ios" "$(record argv)" "test-ios"

# Recorded environment reaches the wrapper and the rerun command.
status=$(run env BUILD_CONFIGURATION=Release TEST_RUNNER_FOO=1 -- "$sha_b" 'IntentTests/FooTests')
assert_eq "run with environment exits 0" "$status" 0
assert_eq "BUILD_CONFIGURATION reaches the wrapper" "$(record config)" "Release"
assert_eq "TEST_RUNNER_* reaches the wrapper" "$(record runner)" "1"
assert_contains "rerun records BUILD_CONFIGURATION" "$(summary_field Rerun)" "BUILD_CONFIGURATION='Release' "
assert_contains "rerun records TEST_RUNNER_FOO" "$(summary_field Rerun)" "TEST_RUNNER_FOO='1' "

# Commits only origin has: by branch name and by bare SHA.
status=$(run branch -- feature 'IntentTests/FooTests')
assert_eq "a branch on origin is fetched" "$status" 0
assert_eq "the branch tip is checked out" "$(record head)" "$sha_c"
assert_contains "the summary records the resolved SHA" "$(summary)" "- Commit: $sha_c (commit C)"
assert_contains "the rerun command pins the resolved SHA" "$(summary_field Rerun)" "'$sha_c'"
assert_lacks "the rerun command does not name the moving branch" "$(summary_field Rerun)" "'feature'"
assert_eq "the private fetch ref is deleted" "$(git -C "$src" for-each-ref refs/run-commit-tests)" ""
status=$(run bysha -- "$sha_d" 'IntentTests/FooTests')
assert_eq "an unfetched SHA is fetched from origin" "$status" 0
assert_eq "the fetched SHA is checked out" "$(record head)" "$sha_d"

# An unknown commit is an ERROR summary, not a crash.
status=$(run unknown -- 0123456789012345678901234567890123456789 'IntentTests/FooTests')
assert_eq "unknown commit exits 1" "$status" 1
assert_contains "unknown commit writes an ERROR summary" "$(summary)" "# iOS test run: ERROR (exit 1)"
assert_contains "unknown commit explains why" "$(summary)" "could not resolve 0123456789012345678901234567890123456789"

# Bad arguments.
status=$(run noselector -- "$sha_a")
assert_eq "missing selectors exit 2" "$status" 2
status=$(run filename -- "$sha_a" 'FooTests.swift')
assert_eq "a file name selector exits 2" "$status" 2
assert_contains "a file name selector is explained" "$(cat "$work/filename.out")" "not file names"
status=$(run badoption -- --frobnicate "$sha_a" 'IntentTests')
assert_eq "an unknown option exits 2" "$status" 2

# TailcatKit: a complete build the wrapper made is cached and reused; a
# partial build is not cached; the clone's own (possibly stale) build is never
# used.
export INTENT_IOS_TEST_RUN_DIR=$work/runs-tailcat
mkdir -p "$src/TailcatKit/build/TailcatKit.xcframework"
status=$(run tailcat0 STUB_TAILCAT_PARTIAL=1 -- "$sha_a" 'IntentTests')
assert_eq "partial TailcatKit run exits 0" "$status" 0
assert_eq "the clone's TailcatKit build is not used" "$(record tailcat)" "missing"
assert_lacks "a partial TailcatKit build is not cached" "$(summary_field TailcatKit)" "cached for later runs"
rm -rf "$src/TailcatKit/build"
status=$(run tailcat1 -- "$sha_a" 'IntentTests')
assert_eq "first TailcatKit run exits 0" "$status" 0
assert_eq "an empty cache leaves TailcatKit to the wrapper" "$(record tailcat)" "missing"
assert_contains "the wrapper's TailcatKit build is cached" "$(summary_field TailcatKit)" "cached for later runs"
status=$(run tailcat2 -- "$sha_b" 'IntentTests')
assert_eq "second TailcatKit run exits 0" "$status" 0
assert_eq "the cached TailcatKit build is reused" "$(record tailcat)" "present"
assert_contains "the reuse is reported" "$(summary_field TailcatKit)" "reused the cached build"
assert_lacks "a reused build is not re-cached" "$(summary_field TailcatKit)" "cached for later runs"

# Interrupted: RUNNING with the PID while in progress, INTERRUPTED after a
# TERM that reaches the wrapper's foreground pipeline, the checkout removed
# only once the run's processes are gone, and a finished TailcatKit build
# cached.
export INTENT_IOS_TEST_RUN_DIR=$work/runs-interrupt
# start_sleeping [env...]: starts a run whose wrapper sleeps; sets $pid.
start_sleeping() {
  rm -f "$STUB_RECORD" "$work/started" "$work/sleep.pid"
  env STUB_OUTCOME=sleep STUB_STARTED="$work/started" STUB_SLEEP_PID="$work/sleep.pid" "$@" \
    "$SCRIPT" --repo "$src" "$sha_a" 'IntentTests' > "$work/interrupt.out" 2>&1 &
  pid=$!
  local tries=0
  while { [ ! -e "$work/started" ] || [ ! -s "$work/sleep.pid" ]; } && [ "$tries" -lt 300 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
}
# finish_sleeping <name>: waits for the run; sets $status and $elapsed and
# checks that the run's processes and checkout are gone.
finish_sleeping() {
  local started
  started=$(date +%s)
  status=0
  wait "$pid" || status=$?
  elapsed=$(( $(date +%s) - started ))
  if kill -0 "$(cat "$work/sleep.pid")" 2>/dev/null; then
    fail "$1: the run's processes are stopped before the runner exits"
    kill -KILL "$(cat "$work/sleep.pid")" 2>/dev/null || true
  else
    pass "$1: the run's processes are stopped before the runner exits"
  fi
  if [ -e "$(record pwd)" ]; then fail "$1: the checkout is removed"; else pass "$1: the checkout is removed"; fi
}

start_sleeping
assert_contains "an in-progress run says RUNNING" "$(summary)" "# iOS test run: RUNNING"
assert_contains "an in-progress run records its PID" "$(summary)" "- PID: $pid "
kill -TERM "$pid"
finish_sleeping "TERM"
assert_eq "an interrupted run exits 143" "$status" 143
assert_contains "an interrupted run says INTERRUPTED" "$(summary)" "# iOS test run: INTERRUPTED (exit 143)"
assert_contains "the wrapper was told to stop" "$(cat "$STUB_RECORD")" "terminated"
if [ "$elapsed" -lt 10 ]; then pass "TERM stops a foreground pipeline promptly"; else fail "TERM stops a foreground pipeline promptly (took ${elapsed}s)"; fi
tree=$(git -C "$src" rev-parse "$sha_a:TailcatKit")
if [ -f "$INTENT_IOS_TEST_RUN_DIR/tailcatkit/$tree/TailcatKit.xcframework/LICENSE.tailcat" ]; then
  pass "an interrupted run caches the finished TailcatKit build"
else
  fail "an interrupted run caches the finished TailcatKit build"
fi
assert_contains "the interrupted summary reports the cached build" "$(summary_field TailcatKit)" "cached for later runs"

# A wrapper that ignores TERM: a second signal escalates to KILL...
start_sleeping STUB_IGNORE_TERM=1 RUN_KILL_GRACE=600
kill -TERM "$pid"
sleep 1
if kill -0 "$pid" 2>/dev/null; then pass "the runner waits for a wrapper that ignores TERM"; else fail "the runner waits for a wrapper that ignores TERM"; fi
kill -TERM "$pid"
finish_sleeping "second TERM"
assert_eq "a doubly interrupted run exits 143" "$status" 143
if [ "$elapsed" -lt 10 ]; then pass "a second TERM kills the run promptly"; else fail "a second TERM kills the run promptly (took ${elapsed}s)"; fi
# ...and so does RUN_KILL_GRACE without a second signal.
start_sleeping STUB_IGNORE_TERM=1 RUN_KILL_GRACE=2
kill -TERM "$pid"
finish_sleeping "kill grace"
assert_eq "a run killed after the grace period exits 143" "$status" 143
if [ "$elapsed" -lt 10 ]; then pass "RUN_KILL_GRACE bounds the wait"; else fail "RUN_KILL_GRACE bounds the wait (took ${elapsed}s)"; fi

# A compiler outside the process group, still writing into the checkout, is
# stopped so the checkout can be deleted, and the exit status stays 143.
start_sleeping STUB_STRAY="$work/stray.pid"
kill -TERM "$pid"
finish_sleeping "stray compiler"
assert_eq "an interrupted run with a stray compiler exits 143" "$status" 143
if kill -0 "$(cat "$work/stray.pid")" 2>/dev/null; then
  fail "the stray compiler is stopped"
  kill -KILL "$(cat "$work/stray.pid")" 2>/dev/null || true
else
  pass "the stray compiler is stopped"
fi
assert_lacks "no cleanup problem is reported" "$(cat "$work/interrupt.out")" "could not be deleted"
# The same with a TMPDIR ending in "/", as on macOS: the compiler's command
# line names the normalized path (one slash), which must still match.
start_sleeping STUB_STRAY="$work/stray.pid" TMPDIR="$work/"
kill -TERM "$pid"
finish_sleeping "stray compiler, TMPDIR ending in /"
assert_eq "an interrupted run with TMPDIR ending in / exits 143" "$status" 143
if kill -0 "$(cat "$work/stray.pid")" 2>/dev/null; then
  fail "the stray compiler is stopped when TMPDIR ends in /"
  kill -KILL "$(cat "$work/stray.pid")" 2>/dev/null || true
else
  pass "the stray compiler is stopped when TMPDIR ends in /"
fi
leftover=$(ls -d "$work"/intent-ios-run.* 2>/dev/null || true)
assert_eq "no temporary checkout is left behind" "$leftover" ""
# The same after a normal exit: a passing run's leftover compiler is stopped.
rm -f "$work/stray.pid"
status=$(run straypass STUB_STRAY="$work/stray.pid" -- "$sha_a" 'IntentTests')
assert_eq "a passing run with a stray compiler exits 0" "$status" 0
if kill -0 "$(cat "$work/stray.pid")" 2>/dev/null; then
  fail "a passing run stops a stray compiler"
  kill -KILL "$(cat "$work/stray.pid")" 2>/dev/null || true
else
  pass "a passing run stops a stray compiler"
fi
if [ -e "$(record pwd)" ]; then fail "a passing run with a stray compiler removes its checkout"; else pass "a passing run with a stray compiler removes its checkout"; fi

# A checkout that cannot be deleted keeps the run's exit status, is noted in
# the summary, and is deleted by the next run once it can be.
if [ "$(id -u)" = 0 ]; then
  echo "skip - running as root, which can delete read-only directories"
else
  status=$(run locked STUB_OUTCOME=fail STUB_RESULTS="$work/fail.json" STUB_LOCKED=1 -- "$sha_a" 'IntentTests')
  assert_eq "an undeletable checkout keeps exit 65" "$status" 65
  assert_contains "an undeletable checkout is noted in the summary" "$(summary)" "could not be deleted"
  assert_contains "the summary keeps the verdict" "$(summary)" "# iOS test run: FAILED (exit 65"
  locked=$(record pwd)
  assert_contains "the checkout is listed for the next run" "$(cat "$INTENT_IOS_TEST_RUN_DIR/stale-checkouts")" "$(dirname "$locked")"
  chmod 755 "$locked/locked"
  status=$(run afterlocked -- "$sha_a" 'IntentTests')
  assert_eq "the next run exits 0" "$status" 0
  if [ -e "$(dirname "$locked")" ]; then fail "the next run deletes the stale checkout"; else pass "the next run deletes the stale checkout"; fi
  assert_eq "the stale list is emptied" "$(cat "$INTENT_IOS_TEST_RUN_DIR/stale-checkouts" 2>/dev/null)" ""
  assert_lacks "the next summary has no cleanup note" "$(summary)" "could not be deleted"
fi

# Only the newest 10 run directories are kept.
export INTENT_IOS_TEST_RUN_DIR=$work/runs-main
for i in 1 2 3 4 5 6 7 8 9 10 11; do
  run "prune$i" -- "$sha_a" 'IntentTests' > /dev/null
done
assert_eq "old run directories are pruned" "$(ls -1 "$INTENT_IOS_TEST_RUN_DIR/runs" | wc -l | tr -d ' ')" 10

echo
if [ "$failures" -eq 0 ]; then
  echo "all run_commit_tests.sh self-tests passed"
else
  echo "$failures run_commit_tests.sh self-test(s) FAILED" >&2
  exit 1
fi
