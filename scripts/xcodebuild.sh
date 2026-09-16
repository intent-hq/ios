#!/usr/bin/env bash
# The single blessed xcodebuild entry point for this repo.
#
# Local agents and CI run every xcodebuild build/test invocation through this
# script so destinations, signing flags, and SDK selection cannot diverge.
#
# Destinations are always -destination based, never -sdk: `-sdk xros` silently
# falls back to building for iphoneos when the visionOS platform component is
# not installed, producing a "green" build for the wrong platform.
# `-destination 'generic/platform=visionOS Simulator'` fails loudly instead,
# and build-visionos additionally checks the SDK is installed before building.
# This script refuses -sdk (and any other extra argument) outright.
#
# Usage: scripts/xcodebuild.sh <subcommand>
#
#   resolve                 Resolve SPM package dependencies
#   build-ios               Build for the generic iOS Simulator destination
#   build-visionos          Build for the generic visionOS Simulator destination
#   build-for-testing       Build the iOS test bundle (CI split step)
#   test-without-building   Run iOS unit tests against a prior build-for-testing
#   test-ios                build-for-testing then test-without-building
#   test-ios-unit           test-ios minus the IntentUITests bundle (-skip-testing)
#   pick-simulator          Print the chosen iPhone simulator UDID on stdout
#
# iOS builds (build-ios, build-for-testing, test-ios, test-ios-unit) link the prebuilt,
# gitignored TailcatKit/build/TailcatKit.xcframework. Those subcommands
# preflight it: when missing, it is built via TailcatKit/build_xcframework.sh
# if a Go toolchain is on PATH, otherwise the script exits naming that
# command. build-visionos skips the preflight (the framework is linked with
# platformFilter = ios only).
#
# Environment knobs (all optional; local runs need none):
#   SIM_UDID              Simulator UDID for test destinations; when unset the
#                         newest available iPhone simulator is picked automatically.
#   SPM_CLONE_DIR         Passed as -clonedSourcePackagesDirPath (CI caches it).
#   RESULT_BUNDLE         Passed as -resultBundlePath to test-without-building;
#                         an existing bundle at that path is removed first.
#   ONLY_TESTING          Whitespace-separated Target[/Class[/method]] identifiers;
#                         each becomes one -only-testing: argument on the test
#                         subcommands (test-without-building, test-ios,
#                         test-ios-unit). Entries starting with '-' are refused.
#   TAILCATKIT_AUTOBUILD  Set to 0 to never run TailcatKit/build_xcframework.sh
#                         from the preflight; a missing xcframework then fails fast.
#   SIM_LOCK_TIMEOUT      Seconds to wait for the simulator lock (below) before
#                         giving up; default 1800. 0 fails immediately when held.
#   SIM_LOCK_DIR          Directory holding simulator lock files; default $TMPDIR
#                         (falling back to /tmp). Must be a local filesystem.
#   SIM_LOCK_KILL_GRACE   Seconds an xcodebuild orphaned by this script's death
#                         (with every process under it) gets to exit after
#                         SIGTERM before the survivors are SIGKILLed; default 30.
#
# Simulator lock: test-without-building (and so test-ios / test-ios-unit) holds
# an exclusive lock on the chosen simulator for the duration of the xcodebuild
# test run. Two runs driving one device concurrently (two agents in one
# checkout, or two checkouts picking the same device) kill each other's test
# processes and produce disjoint, false "Failing tests" lists
# (intent-hq/intent#4563). The lock is a kernel flock(2) on
# <SIM_LOCK_DIR>/xcodebuild-sim-<UDID>.lock, taken by a small python3 keeper
# process (python3 ships with Xcode's Command Line Tools; stock macOS Bash 3.2
# has no flock) that holds it until this script's fd 9 closes, i.e. until the
# run ends by any means including SIGKILL. If the script dies while xcodebuild
# is still running, the keeper terminates that xcodebuild (and its helpers)
# first and only then releases, so the device is never handed to the next run
# while a test process is still driving it. There is therefore no stale-lock
# state and nothing is ever reclaimed: the file persists (empty when free,
# holding the owner's PID while held) and is harmless. A waiter prints who
# holds the lock and polls once a second. CI runs one job per VM, so the lock
# is never contended there.
#
# Exit codes: xcodebuild's own status is passed through (65 = build or test
# failure) except for these wrapper-specific codes, chosen outside sysexits(3)
# so they cannot be confused with xcodebuild's:
#   80  the test process crashed or was terminated (xcodebuild printed
#       "Restarting after unexpected exit, crash, or test timeout", "Test
#       crashed with signal ...", or a lost test-runner connection). xcodebuild
#       reports this as a plain 65 with a "Failing tests" list that names
#       whichever tests happened to be running; the wrapper prints the
#       distinguishing lines instead and keeps the full log (intent-hq/ios#238).
#   81  timed out waiting for the simulator lock.
set -euo pipefail

EXIT_TEST_PROCESS_CRASHED=80
EXIT_SIM_LOCK_TIMEOUT=81

cd "$(dirname "$0")/.."

PROJECT_ARGS=(-project Intent.xcodeproj -scheme Intent)
SIGNING_ARGS=(CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO)

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: scripts/xcodebuild.sh <subcommand>

  resolve                 Resolve SPM package dependencies
  build-ios               Build for the generic iOS Simulator destination
  build-visionos          Build for the generic visionOS Simulator destination
  build-for-testing       Build the iOS test bundle (CI split step)
  test-without-building   Run iOS unit tests against a prior build-for-testing
  test-ios                build-for-testing then test-without-building
  test-ios-unit           test-ios minus the IntentUITests bundle (-skip-testing)
  pick-simulator          Print the chosen iPhone simulator UDID on stdout

Optional env knobs: SIM_UDID, SPM_CLONE_DIR, RESULT_BUNDLE, ONLY_TESTING,
TAILCATKIT_AUTOBUILD, SIM_LOCK_TIMEOUT, SIM_LOCK_DIR (see script header).
Exit codes: xcodebuild's own, plus 80 (test process crashed/terminated) and
81 (timed out waiting for the simulator lock).
EOF
  exit 2
}

# Prefer the iPhone 16 simulator, else any available iPhone; fail early with a
# clear message if there is none. Select by UDID: it keeps parenthesized names
# (e.g. "iPhone SE (3rd generation)") intact, disambiguates duplicate names
# across runtimes, and pins the destination to one concrete device. tail -n 1
# prefers the newest installed runtime (simctl groups devices by runtime,
# oldest first). SIM_UDID overrides the pick (CI selects once, pre-boots, and
# reuses the same device here).
pick_simulator() {
  if [ -n "${SIM_UDID:-}" ]; then
    echo "$SIM_UDID"
    return
  fi
  local devices line udid name
  devices=$(xcrun simctl list devices available)
  line=$(echo "$devices" | grep -E '^[[:space:]]+iPhone 16 \(' | tail -n 1 || true)
  if [ -z "$line" ]; then
    line=$(echo "$devices" | grep -E '^[[:space:]]+iPhone' | tail -n 1 || true)
  fi
  udid=$(echo "$line" | grep -oE '[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}' | head -n 1 || true)
  if [ -z "$udid" ]; then
    die "no available iPhone simulator on this machine"
  fi
  name=$(echo "$line" | sed -E "s/^[[:space:]]*(.*) \($udid\).*/\1/")
  echo "Selected simulator: $name ($udid)" >&2
  echo "$udid"
}

ensure_visionos_sdk() {
  if ! xcodebuild -showsdks 2>/dev/null | grep -q 'xrsimulator'; then
    die "visionOS simulator SDK (xrsimulator) is not installed for the selected Xcode.
Install it with: xcodebuild -downloadPlatform visionOS
Refusing to build: without the platform, xcodebuild would silently fall back to iphoneos."
  fi
}

# The Xcode project links the prebuilt (gitignored) TailcatKit.xcframework
# for iOS. A fresh checkout has none, and xcodebuild only reports the gap deep
# into the build. Build it here when Go is available, else fail fast naming
# the fix. Silent no-op when the artifact is present.
TAILCATKIT_XCFRAMEWORK=TailcatKit/build/TailcatKit.xcframework
ensure_tailcatkit() {
  if [ -d "$TAILCATKIT_XCFRAMEWORK" ]; then
    return
  fi
  if [ "${TAILCATKIT_AUTOBUILD:-1}" != "0" ] && command -v go >/dev/null; then
    echo "notice: $TAILCATKIT_XCFRAMEWORK is missing; building it with TailcatKit/build_xcframework.sh" >&2
    TailcatKit/build_xcframework.sh
    return
  fi
  local reason="TAILCATKIT_AUTOBUILD=0 disables the automatic build."
  if [ "${TAILCATKIT_AUTOBUILD:-1}" != "0" ]; then
    reason="the automatic build requires a Go toolchain on PATH (none found)."
  fi
  die "$TAILCATKIT_XCFRAMEWORK is missing (it is gitignored; iOS builds link it).
Build it with: TailcatKit/build_xcframework.sh
Not building it automatically: $reason"
}

# Shared optional args appended to every xcodebuild invocation.
common_args() {
  if [ -n "${SPM_CLONE_DIR:-}" ]; then
    printf '%s\n' -clonedSourcePackagesDirPath "$SPM_CLONE_DIR"
  fi
}

run_xcodebuild() {
  local extra=()
  while IFS= read -r arg; do extra+=("$arg"); done < <(common_args)
  (
    set -x
    xcodebuild "$@" ${extra+"${extra[@]}"}
  )
}

# Same as run_xcodebuild, but stderr is merged into stdout and everything is
# tee'd to the log file at $1 so the test outcome can be classified afterwards.
# pipefail makes the pipeline report xcodebuild's own status. Only valid under
# the simulator lock: the subshell tells the keeper on fd 9 which PID is about
# to become xcodebuild (exec keeps the PID; Bash 3.2 has no $BASHPID, hence
# the sh -c trick) and then closes fd 9 so xcodebuild's helpers cannot hold
# the lock open, and the caller reports "done" once xcodebuild has returned.
run_xcodebuild_logged() {
  local log=$1 extra=()
  shift
  while IFS= read -r arg; do extra+=("$arg"); done < <(common_args)
  (
    echo "run $(sh -c 'echo $PPID')" >&9
    exec 9>&-
    set -x
    exec xcodebuild "$@" ${extra+"${extra[@]}"}
  ) 2>&1 | tee "$log" 9>&-
}

# Simulator lock (see the header). A python3 "keeper" process takes an
# exclusive flock(2) on the lock file, records the owning shell's PID in it,
# and then reads its stdin, which is this shell's fd 9, until EOF. The flock
# lives exactly as long as the keeper, and the keeper lives exactly as long as
# fd 9 has a writer: closing fd 9 (release_simulator_lock) or this shell
# dying by any means, SIGKILL included, ends both, so no stale lock can exist
# and nothing is ever reclaimed or deleted. Children that outlive a run must
# not inherit fd 9, which is why every command run under the lock closes it.
#
# The shell writes "run <pid>" on fd 9 when xcodebuild starts and "done" when
# it has returned. EOF between the two means the shell died mid-run while
# xcodebuild kept going: the keeper then SIGTERMs that process tree (parents
# before children, so a parent cannot outlive a child's exit and carry on), waits
# up to SIM_LOCK_KILL_GRACE seconds for every process in it to exit (tracking
# the PIDs it saw, so a descendant that outlives and reparents away from its
# parent is still waited for, plus any new descendants that appear meanwhile),
# SIGKILLs the survivors, and releases only once none is left, so the next run
# never shares the device with an orphaned test process (helpers that merely
# outlive a completed xcodebuild are never touched).
#
# Keeper protocol on stdout, one line each: "waiting <holder>" once if the
# lock was busy, then "acquired <keeper pid> <seconds waited>" or
# "timeout <holder>"; <holder> is the PID recorded in the file or "unknown".
SIM_LOCK_KEEPER_PY='
import errno, fcntl, os, signal, subprocess, sys, time
path, owner, timeout, grace = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
def holder():
    os.lseek(fd, 0, os.SEEK_SET)
    return os.read(fd, 64).decode("ascii", "replace").strip() or "unknown"
def say(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()
def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
def process_table():
    table = {}
    try:
        out = subprocess.run(["ps", "-axo", "pid=,ppid=,stat="], capture_output=True, text=True).stdout
    except Exception:
        return table
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0].isdigit() and parts[1].isdigit():
            table[int(parts[0])] = (int(parts[1]), parts[2])
    return table
def with_descendants(pids, table):
    children = {}
    for pid, (ppid, _) in table.items():
        children.setdefault(ppid, []).append(pid)
    ordered, queue = list(pids), list(pids)
    while queue:
        for child in children.get(queue.pop(0), []):
            if child not in ordered:
                ordered.append(child)
                queue.append(child)
    return ordered
def still_running(pids, table):
    if not table:
        return [pid for pid in pids if alive(pid)]
    return [pid for pid in pids if pid in table and not table[pid][1].startswith("Z")]
def signal_all(pids, sig):
    for pid in pids:
        try:
            os.kill(pid, sig)
        except (ProcessLookupError, PermissionError):
            pass
def terminate_orphaned_run(root):
    sys.stderr.write("xcodebuild.sh: PID %s died while xcodebuild PID %d was still running; terminating it before releasing the simulator lock\n" % (owner, root))
    sys.stderr.flush()
    tracked = with_descendants([root], process_table())
    signal_all(tracked, signal.SIGTERM)
    deadline = time.time() + grace
    while True:
        table = process_table()
        tracked = with_descendants(tracked, table)
        remaining = still_running(tracked, table)
        if not remaining or time.time() >= deadline:
            break
        time.sleep(0.2)
    if remaining:
        sys.stderr.write("xcodebuild.sh: %d process(es) of xcodebuild PID %d ignored SIGTERM for %ds; sending SIGKILL\n" % (len(remaining), root, grace))
        sys.stderr.flush()
        while remaining:
            signal_all(remaining, signal.SIGKILL)
            time.sleep(0.1)
            table = process_table()
            tracked = with_descendants(tracked, table)
            remaining = still_running(tracked, table)
start = time.time()
announced = False
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except OSError as e:
        if e.errno not in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK):
            raise
    if timeout == 0 or time.time() - start >= timeout:
        say("timeout " + holder())
        sys.exit(0)
    if not announced:
        say("waiting " + holder())
        announced = True
    time.sleep(min(1, timeout - (time.time() - start)))
os.ftruncate(fd, 0)
os.write(fd, (owner + "\n").encode("ascii"))
say("acquired %d %d" % (os.getpid(), int(time.time() - start)))
running = None
for line in sys.stdin:
    words = line.split()
    if len(words) == 2 and words[0] == "run" and words[1].isdigit():
        running = int(words[1])
    elif words == ["done"]:
        running = None
if running is not None and alive(running):
    terminate_orphaned_run(running)
os.ftruncate(fd, 0)
'
SIM_LOCK_PATH=
SIM_LOCK_KEEPER=
acquire_simulator_lock() {
  local udid=$1 dir timeout grace fifo kind arg1 arg2 announced=0
  dir=${SIM_LOCK_DIR:-${TMPDIR:-/tmp}}
  timeout=${SIM_LOCK_TIMEOUT:-1800}
  grace=${SIM_LOCK_KILL_GRACE:-30}
  case "$timeout" in
    ''|*[!0-9]*) die "SIM_LOCK_TIMEOUT must be a non-negative integer number of seconds (got '$timeout')" ;;
  esac
  case "$grace" in
    ''|*[!0-9]*) die "SIM_LOCK_KILL_GRACE must be a non-negative integer number of seconds (got '$grace')" ;;
  esac
  command -v python3 >/dev/null 2>&1 \
    || die "python3 is required for the simulator lock (on macOS it ships with Xcode's Command Line Tools)"
  mkdir -p -- "$dir"
  SIM_LOCK_PATH="${dir%/}/xcodebuild-sim-$udid.lock"
  fifo=$(mktemp -d "${TMPDIR:-/tmp}/xcodebuild-lock.XXXXXX")/status
  mkfifo "$fifo"
  exec 9> >(python3 -c "$SIM_LOCK_KEEPER_PY" "$SIM_LOCK_PATH" "$$" "$timeout" "$grace" > "$fifo")
  exec 8< "$fifo"
  rm -rf -- "${fifo%/status}"
  while :; do
    if ! read -r kind arg1 arg2 <&8; then
      exec 8<&- 9>&-
      SIM_LOCK_PATH=
      die "the simulator lock keeper exited without reporting (see any python3 error above)"
    fi
    case "$kind" in
      waiting)
        echo "waiting for simulator $udid: lock $SIM_LOCK_PATH is held by PID $arg1 (another xcodebuild.sh test run); giving up after ${timeout}s" >&2
        announced=1 ;;
      acquired)
        SIM_LOCK_KEEPER=$arg1
        [ "$announced" -eq 0 ] || echo "acquired simulator lock after ${arg2}s" >&2
        break ;;
      timeout)
        exec 8<&- 9>&-
        echo "error: timed out after ${timeout}s waiting for simulator $udid: lock $SIM_LOCK_PATH is held by PID $arg1.
Wait for that run to finish (or raise SIM_LOCK_TIMEOUT), or pick another device with SIM_UDID." >&2
        SIM_LOCK_PATH=
        exit "$EXIT_SIM_LOCK_TIMEOUT" ;;
      *)
        exec 8<&- 9>&-
        SIM_LOCK_PATH=
        die "unexpected simulator lock keeper output: $kind $arg1 $arg2" ;;
    esac
  done
  exec 8<&-
}

# Closing fd 9 is the release; the flock drops when the keeper exits, which
# is waited for briefly so the next run never sees a lock in mid-release.
release_simulator_lock() {
  local i=0
  [ -n "$SIM_LOCK_PATH" ] || return 0
  exec 9>&-
  while [ -n "$SIM_LOCK_KEEPER" ] && kill -0 "$SIM_LOCK_KEEPER" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.05 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  SIM_LOCK_PATH=
  SIM_LOCK_KEEPER=
}

# The EXIT trap releases the lock on any exit path; the signal traps turn an
# interrupt into a normal exit so that the EXIT trap runs. (Neither is needed
# for correctness: a shell killed outright drops fd 9 and the lock with it.)
trap release_simulator_lock EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Lines xcodebuild prints when the test process itself died or the connection
# to it was lost, as opposed to a test assertion failing. In both cases
# xcodebuild exits 65 and lists whatever tests were in flight under "Failing
# tests", which is what makes a crash look like a test failure (ios#238) and
# a concurrent-run corruption look like flaky tests (intent#4563). Matched
# case-insensitively; the wording has varied across Xcode releases ("Lost
# connection to the test manager service" vs "Test operation failure: Lost
# connection to test manager service", "Lost connection to test runner").
TEST_CRASH_PATTERN='Restarting after unexpected exit, crash, or test timeout|Test crashed with signal|Early unexpected exit, operation never finished bootstrapping|Lost connection to (the )?test (manager service|runner)|Test runner (exited|never began executing|crashed)|The test runner exited with code'

# $1 = xcodebuild status, $2 = log path. Returns the status to exit with:
# EXIT_TEST_PROCESS_CRASHED when the log shows a test-process crash or
# termination (the log is kept and named), else xcodebuild's status unchanged.
report_test_outcome() {
  local status=$1 log=$2 crashes
  crashes=$(grep -iE "$TEST_CRASH_PATTERN" "$log" | awk '!seen[$0]++' | head -n 40 || true)
  if [ -z "$crashes" ]; then
    rm -f -- "$log"
    return "$status"
  fi
  if [ "$status" -eq 0 ]; then
    echo "notice: the test process was restarted at least once during this run (see below) although xcodebuild exited 0:" >&2
    echo "$crashes" >&2
    rm -f -- "$log"
    return 0
  fi
  cat >&2 <<EOF

error: the xcodebuild test process crashed or was terminated (exit $status is NOT a plain test failure).
The lines below name the test that was executing when the process died:
EOF
  echo "$crashes" | sed 's/^/  /' >&2
  cat >&2 <<EOF
Any "Failing tests" list above may name tests that were merely running at the time.
Full xcodebuild output kept at: $log
Next steps: re-run the named suite alone with ONLY_TESTING='Target/Class' scripts/xcodebuild.sh test-without-building;
if another test run may have shared this simulator, that is the cause the simulator lock exists to prevent (see the script header).
Exiting $EXIT_TEST_PROCESS_CRASHED (test-process crash), not $status.
EOF
  return "$EXIT_TEST_PROCESS_CRASHED"
}

cmd_resolve() {
  run_xcodebuild -resolvePackageDependencies "${PROJECT_ARGS[@]}"
}

cmd_build_ios() {
  ensure_tailcatkit
  run_xcodebuild build "${PROJECT_ARGS[@]}" \
    -destination 'generic/platform=iOS Simulator' "${SIGNING_ARGS[@]}"
}

cmd_build_visionos() {
  ensure_visionos_sdk
  run_xcodebuild build "${PROJECT_ARGS[@]}" \
    -destination 'generic/platform=visionOS Simulator' "${SIGNING_ARGS[@]}"
}

cmd_build_for_testing() {
  local udid
  ensure_tailcatkit
  udid=$(pick_simulator)
  run_xcodebuild build-for-testing "${PROJECT_ARGS[@]}" \
    -destination "platform=iOS Simulator,id=$udid" "${SIGNING_ARGS[@]}"
}

# SwiftUI hosting views only publish their accessibility tree when the
# simulator has accessibility enabled (the same switch Accessibility Inspector
# and XCUITest flip, persisted in the device's com.apple.Accessibility
# domain). A long-lived local simulator usually has it on already; an
# ephemeral CI simulator never does, so tests that read accessibility labels
# or frames out of a UIHostingController pass locally and fail on CI. Enable
# it explicitly on the test device so both environments see the same tree.
#
# bootstatus output is left visible: it shows how long the boot wait took,
# which otherwise disappears into a silent gap inside xcodebuild.
#
# Runs under the simulator lock, so fd 9 is closed on every command (see
# acquire_simulator_lock).
enable_simulator_accessibility() {
  local udid=$1
  xcrun simctl boot "$udid" 2>&1 9>&- | grep -v 'current state: Booted' || true
  xcrun simctl bootstatus "$udid" -b 9>&- || true
  xcrun simctl spawn "$udid" defaults write com.apple.Accessibility \
    ApplicationAccessibilityEnabled -bool true 9>&-
  xcrun simctl spawn "$udid" defaults write com.apple.Accessibility \
    AccessibilityEnabled -bool true 9>&-
}

# ONLY_TESTING narrows a test run: whitespace-separated Target[/Class[/method]]
# identifiers, each forwarded as one -only-testing: argument. Entries starting
# with '-' are refused so the knob cannot smuggle arbitrary xcodebuild flags
# past the extra-argument check. Parsed before any simulator or xcodebuild work
# so a typo fails fast. Unset/empty leaves the command line untouched.
ONLY_TESTING_ARGS=()
parse_only_testing() {
  local ids=() id
  ONLY_TESTING_ARGS=()
  read -r -d '' -a ids <<< "${ONLY_TESTING:-}" || true
  for id in ${ids+"${ids[@]}"}; do
    case "$id" in
      -*) die "ONLY_TESTING entry '$id' looks like a flag; entries must be Target[/Class[/method]] identifiers" ;;
    esac
    ONLY_TESTING_ARGS+=("-only-testing:$id")
  done
}

# xcodebuild refuses an existing result bundle path, so remove it first.
# Positional arguments are test-selection flags supplied by the subcommand
# dispatch below (test-ios-unit passes -skip-testing:IntentUITests); they are
# appended after the unconditional flags, as are the ONLY_TESTING arguments.
#
# The simulator lock is taken before the device is touched (boot, defaults,
# tests) and released as soon as xcodebuild returns; the outcome is then
# classified from the captured log (see report_test_outcome).
cmd_test_without_building() {
  local udid extra=() log status=0
  parse_only_testing
  udid=$(pick_simulator)
  acquire_simulator_lock "$udid"
  enable_simulator_accessibility "$udid"
  if [ -n "${RESULT_BUNDLE:-}" ]; then
    rm -rf -- "${RESULT_BUNDLE:?}"
    extra+=(-resultBundlePath "$RESULT_BUNDLE")
  fi
  log=$(mktemp "${TMPDIR:-/tmp}/xcodebuild-test.XXXXXX")
  run_xcodebuild_logged "$log" test-without-building "${PROJECT_ARGS[@]}" \
    -destination "platform=iOS Simulator,id=$udid" \
    -parallel-testing-enabled NO ${extra+"${extra[@]}"} \
    ${ONLY_TESTING_ARGS+"${ONLY_TESTING_ARGS[@]}"} "$@" || status=$?
  echo done >&9
  release_simulator_lock
  report_test_outcome "$status" "$log"
}

[ $# -ge 1 ] || usage
subcommand=$1
shift
for arg in "$@"; do
  case "$arg" in
    -sdk) die "-sdk is refused: it silently falls back to the wrong platform when the requested one is missing. Destinations are fixed by this script." ;;
    *) die "unexpected argument '$arg': subcommands take no extra arguments" ;;
  esac
done

case "$subcommand" in
  resolve)               cmd_resolve ;;
  build-ios)             cmd_build_ios ;;
  build-visionos)        cmd_build_visionos ;;
  build-for-testing)     cmd_build_for_testing ;;
  test-without-building) cmd_test_without_building ;;
  test-ios)              parse_only_testing && cmd_build_for_testing && cmd_test_without_building ;;
  test-ios-unit)         parse_only_testing && cmd_build_for_testing && cmd_test_without_building -skip-testing:IntentUITests ;;
  pick-simulator)        pick_simulator ;;
  *)                     usage ;;
esac
