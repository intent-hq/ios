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
#   archive-ios             Signed Release archive for generic iOS devices
#   export-ios              Export that archive for App Store Connect (no upload)
#   archive-visionos        Signed Release archive for generic visionOS devices
#   export-visionos         Export that archive for App Store Connect (no upload)
#   build-visionos          Build for the generic visionOS Simulator destination
#   build-for-testing       Build the iOS test bundle (CI split step)
#   test-without-building   Run iOS tests against a prior build-for-testing
#   test-without-building-unit
#                           test-without-building minus IntentUITests
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
#   Release-only commands require RELEASE_ARCHIVE_PATH, ASC_KEY_PATH (a mode
#   0600 .p8 file), ASC_KEY_ID and ASC_ISSUER_ID. Both archive commands require
#   RELEASE_VERSION and RELEASE_BUILD_NUMBER; both export commands require
#   RELEASE_EXPORT_PATH and RELEASE_EXPORT_OPTIONS. Fastlane sets these after
#   checking App Store Connect. Build numbers are command-line overrides only.
#   BUILD_CONFIGURATION   Debug or Release; unset/empty preserves the scheme's
#                         existing defaults. Applied to every build/test call,
#                         including enumeration and crash retries. Release test
#                         commands enable @testable access (ENABLE_TESTABILITY=YES)
#                         but never define DEBUG or change optimization. Plain
#                         build-ios/build-visionos keep production testability.
#   SIM_UDID              Simulator UDID for test destinations; when unset the
#                         newest available iPhone simulator is picked automatically.
#   SPM_CLONE_DIR         Passed as -clonedSourcePackagesDirPath (CI caches it).
#   DERIVED_DATA_DIR      Passed as -derivedDataPath to every build/test call.
#                         CI uses a fresh directory per job and run attempt.
#   RESULT_BUNDLE         Passed as -resultBundlePath to test-without-building;
#                         an existing bundle at that path is removed first.
#                         A filtered run (ONLY_TESTING set) with no RESULT_BUNDLE
#                         writes a temporary bundle instead so its results can
#                         be read back; it is deleted after a passing run and
#                         kept and named (like the log) after a failing one.
#   ONLY_TESTING          Whitespace-separated Target[/Class[/method]] identifiers;
#                         each becomes one -only-testing: argument on the test
#                         subcommands (test-without-building and its unit
#                         variant, test-ios, test-ios-unit). Entries starting
#                         with '-' are refused;
#                         duplicates are collapsed. Before the filtered run the
#                         wrapper enumerates the built revision's tests
#                         (xcodebuild -enumerate-tests, under the simulator
#                         lock, with the subcommand's -skip-testing: flags but
#                         no -only-testing:) and resolves every selector against
#                         that catalog by exact path segments, so a file name or
#                         typo fails with exit 82 before any test runs. After
#                         the run it reads the result bundle (xcrun xcresulttool
#                         get test-results tests) and prints one table row per
#                         selector — requested, resolved, executed, skipped,
#                         failed, unknown — to stdout; a selector whose tests
#                         neither executed nor were skipped exits 82 even when
#                         xcodebuild exited 0 (so does a crash re-run that left
#                         an interrupted suite or failed test unrecovered), an
#                         all-skipped selector is a
#                         notice, and an unreadable bundle or an unrecognised
#                         result on a green run exits 83 (see the exit codes
#                         below). Unset/empty skips all of this and leaves the
#                         command line untouched.
#   ONLY_TESTING_IDENTITIES_PATH
#                         Optional JSON evidence of the resolver's matched test
#                         identities, used by the filtered iPad proof lane.
#                         Unset leaves output and selection unchanged. A failed
#                         requested export exits 83 before tests start.
#   GITHUB_STEP_SUMMARY   When set (GitHub Actions does), the per-selector table
#                         of a filtered run is also appended there as Markdown,
#                         as is every test-process crash or restart (the crash
#                         lines and the re-run's verdict, see exit code 80), so
#                         a crash that the re-run recovered from is never
#                         silently swallowed.
#   TEST_CRASH_RETRY      Set to 0 to never re-run the suites a test-process
#                         crash interrupted (see exit code 80); a crash then
#                         exits 80 at once.
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
# Release verification (intent-hq/ios#468):
#   BUILD_CONFIGURATION=Release scripts/xcodebuild.sh build-ios
#     Production-configuration build proof only, not runtime failure coverage.
#   BUILD_CONFIGURATION=Release ONLY_TESTING='IntentTests/ReleaseConfigurationTests' \
#     scripts/xcodebuild.sh test-ios-unit
#     Executes the Release branch checks. Add release-compatible diagnostic
#     suites to ONLY_TESTING as implemented; this does not prove producers that
#     do not exist yet. The full suite contains DEBUG-only plaintext fixtures:
#     using those in Release deliberately fails, rather than enabling insecure
#     app behavior or silently skipping coverage. NetworkCopyDiagnosticsTests
#     is DEBUG-only and will not resolve in Release.
#   For split runs use BUILD_CONFIGURATION=Release on BOTH build-for-testing
#   and test-without-building[-unit], and rebuild after changing configuration
#   (both use the scheme's generated xctestrun location). Do not reuse a Debug
#   build as Release evidence. ReleaseConfigurationTests is absent in Debug,
#   so selecting it there fails the existing selector gate.
#
# Simulator lock: test-without-building (and its unit/test-ios variants) holds
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
# Keyboard-resize UI test prerequisite (intent-hq/ios#385): the transcript
# test enters a draft and requires a hittable software keyboard. An absent
# keyboard skips; an existing off-screen keyboard or a visible keyboard
# without transcript shrink still fails. The separate quarantine requires
# TEST_RUNNER_INTENT_UITEST_FULL_GATE_REPRO=1 to exercise that test at all.
#
# Simulator.app's I/O > Keyboard > Connect Hardware Keyboard preference can
# affect presentation, but its value does not establish effective keyboard
# state. This wrapper leaves host and device preferences unchanged. The global
# preference can be inspected with
#   defaults read com.apple.iphonesimulator ConnectHardwareKeyboard
# and a device override can exist under DevicePreferences in the same domain.
# The supported menu can detach the hardware keyboard; simctl has no equivalent
# keyboard toggle. The hosted preference-on runs in #385 still showed a software
# keyboard, so an observed keyboard is required regardless of the setting.
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
#       Before settling on 80 the wrapper re-runs, exactly once and alone, the
#       suites the crash interrupted (Target/Suite taken from the restart
#       lines and from every "Failing tests" entry; narrowed to the
#       ONLY_TESTING selectors inside those suites when given), under the
#       simulator lock again and with a sibling result bundle
#       (<bundle>-retry) when a bundle is written. A green re-run merges: the
#       run exits 0, the crash lines stay on stderr and in the job summary,
#       the crash log is kept, and a filtered run's table reads the re-run's
#       results over the primary bundle's for the re-run tests
#       (intent-hq/intent#3931). A re-run that fails without a crash exits
#       65 (real failures); one that crashes again exits 80 and is not
#       retried; when no suite can be named, or TEST_CRASH_RETRY=0, the
#       crash exits 80 without a re-run.
#   81  timed out waiting for the simulator lock.
#   82  an ONLY_TESTING selector matched no runnable test in the enumerated
#       catalog (typo, file name instead of Target/Suite, only disabled tests,
#       or excluded by the subcommand's -skip-testing:) — every unmatched
#       selector is named with up to five look-alike suites and the test run
#       is not started even when other selectors resolved — or, after the run,
#       a resolved selector for which the result bundle records no executed or
#       skipped test although xcodebuild exited 0 (other selectors having run
#       does not rescue it), or a crash re-run (exit code 80 above) that
#       recorded nothing for an interrupted suite it re-ran or did not record a
#       test that failed in the crashed run (the crashed run's results are no
#       evidence, so the failure counts as unrecovered). A selector whose tests
#       were all skipped at runtime (XCTSkip, .disabled) is reported as a
#       notice and keeps exit 0.
#   83  the ONLY_TESTING selection could not be verified: test enumeration
#       failed or produced no parsable catalog, or the result bundle of a run
#       that exited 0 is missing, unreadable, or records a test result other
#       than Passed / Failed / Skipped / Expected Failure (counted in the
#       table's "unknown" column, never as executed). Never passed through
#       silently.
#   Precedence: 80 and xcodebuild's own nonzero status win over 82/83, which
#   only ever upgrade a 0 (the table and a warning are still printed).
set -euo pipefail

EXIT_TEST_PROCESS_CRASHED=80
EXIT_SIM_LOCK_TIMEOUT=81
EXIT_SELECTOR_UNMATCHED=82
EXIT_SELECTION_UNVERIFIED=83

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
  archive-ios             Signed Release archive for generic iOS devices
  export-ios              Export that archive for App Store Connect (no upload)
  archive-visionos        Signed Release archive for generic visionOS devices
  export-visionos         Export that archive for App Store Connect (no upload)
  build-visionos          Build for the generic visionOS Simulator destination
  build-for-testing       Build the iOS test bundle (CI split step)
  test-without-building   Run iOS tests against a prior build-for-testing
  test-without-building-unit
                          test-without-building minus IntentUITests
  test-ios                build-for-testing then test-without-building
  test-ios-unit           test-ios minus the IntentUITests bundle (-skip-testing)
  pick-simulator          Print the chosen iPhone simulator UDID on stdout

Optional env knobs: BUILD_CONFIGURATION (Debug or Release; unset keeps defaults),
SIM_UDID, SPM_CLONE_DIR, DERIVED_DATA_DIR, RESULT_BUNDLE, ONLY_TESTING,
TAILCATKIT_AUTOBUILD, TEST_CRASH_RETRY, SIM_LOCK_TIMEOUT, SIM_LOCK_DIR (see
script header).
Release tests enable @testable access, not DEBUG. Use focused release-compatible
suites; DEBUG-only plaintext fixtures fail in Release. See the script header
for production build proof and executable ReleaseConfigurationTests commands.
ONLY_TESTING selectors (Target[/Suite[/test]], not file names) are gated: each
is resolved against the enumerated tests before the run and checked against
the result bundle after it, with a per-selector table printed at the end.
A test-process crash re-runs the interrupted suites once, alone; a green
re-run keeps the run green (TEST_CRASH_RETRY=0 disables this).
Exit codes: xcodebuild's own, plus 80 (test process crashed/terminated, and
the re-run did not recover), 81 (timed out waiting for the simulator lock),
82 (an ONLY_TESTING selector matched or executed no test, or the crash re-run
left an interrupted suite or failed test unrecovered) and 83 (the
ONLY_TESTING selection could not be verified).
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
  # Consume the full stream: grep -q can SIGPIPE xcodebuild under pipefail (#673).
  if ! xcodebuild -showsdks 2>/dev/null | grep 'xrsimulator' >/dev/null; then
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
  if [ -n "${BUILD_CONFIGURATION:-}" ]; then
    printf '%s\n' -configuration "$BUILD_CONFIGURATION"
    if [ "$BUILD_CONFIGURATION" = Release ]; then
      case "$subcommand" in
        build-for-testing|test-without-building|test-without-building-unit|test-ios|test-ios-unit)
          printf '%s\n' ENABLE_TESTABILITY=YES ;;
      esac
    fi
  fi
  if [ -n "${SPM_CLONE_DIR:-}" ]; then
    printf '%s\n' -clonedSourcePackagesDirPath "$SPM_CLONE_DIR"
  fi
  if [ -n "${DERIVED_DATA_DIR:-}" ]; then
    printf '%s\n' -derivedDataPath "$DERIVED_DATA_DIR"
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

# Appends its arguments, one line each, to the GitHub job summary when there
# is one; a no-op otherwise. Never fails the run.
append_step_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null \
    || echo "warning: could not append to GITHUB_STEP_SUMMARY ($GITHUB_STEP_SUMMARY)" >&2
}

# $1 = xcodebuild status, $2 = log path, $3 = what the log is of (default
# "this run", the re-run passes "the re-run"). Returns the status to exit
# with: EXIT_TEST_PROCESS_CRASHED when the log shows a test-process crash or
# termination (the log is kept and named), else xcodebuild's status
# unchanged. The crash lines go to stderr and to the job summary in both the
# crash and the restarted-but-green case; the caller decides what to do next
# (retry_crashed_suites) and prints the final "Exiting" line.
report_test_outcome() {
  local status=$1 log=$2 label=${3:-this run} crashes
  crashes=$(grep -iE "$TEST_CRASH_PATTERN" "$log" | awk '!seen[$0]++' | head -n 40 || true)
  if [ -z "$crashes" ]; then
    rm -f -- "$log"
    return "$status"
  fi
  if [ "$status" -eq 0 ]; then
    echo "notice: the test process was restarted at least once during $label (see below) although xcodebuild exited 0:" >&2
    echo "$crashes" >&2
    append_step_summary "### Test-runner restart ($label)" "" \
      "The test process was restarted at least once although xcodebuild exited 0:" "" '```' "$crashes" '```' ""
    rm -f -- "$log"
    return 0
  fi
  cat >&2 <<EOF

error: the xcodebuild test process crashed or was terminated (exit $status is NOT a plain test failure) during $label.
The lines below name the test that was executing when the process died:
EOF
  echo "$crashes" | sed 's/^/  /' >&2
  cat >&2 <<EOF
Any "Failing tests" list above may name tests that were merely running at the time.
Full xcodebuild output kept at: $log
If another test run may have shared this simulator, that is the cause the simulator lock exists to prevent (see the script header).
EOF
  append_step_summary "### Test-runner restart ($label)" "" \
    "The xcodebuild test process crashed or was terminated (exit $status is NOT a plain test failure); the lines below name the test that was executing when the process died:" "" \
    '```' "$crashes" '```' "" "Full xcodebuild output kept at \`$log\`." ""
  return "$EXIT_TEST_PROCESS_CRASHED"
}

# Names the suites a test-process crash interrupted, from the log at argv[1]:
# every "Restarting after unexpected exit, crash, or test timeout in
# Target.Suite/test()" line plus every entry of every "Failing tests:" block,
# since xcodebuild lists whichever tests were in flight there. The block comes
# grouped (Target on its own tab-indented line, then Suite.test() or
# Suite/test() entries) or flat (one tab, fully qualified Target.Suite/test()
# or Target.Suite.test() entries, no target header).
# Prints the unique Target/Suite identifiers, space-separated, in order of
# first appearance; nothing when no suite can be named.
TEST_CRASH_SUITES_PY='
import re, sys
restart = re.compile(r"Restarting after unexpected exit, crash, or test timeout in ([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)[/.]", re.I)
suites = []
def add(target, suite):
    ident = target + "/" + suite
    if ident not in suites:
        suites.append(ident)
target, in_failing = None, False
with open(sys.argv[1], errors="replace") as f:
    for raw in f:
        line = raw.rstrip("\r\n")
        m = restart.search(line)
        if m:
            add(m.group(1), m.group(2))
        if line.strip() == "Failing tests:":
            target, in_failing = None, True
            continue
        if not in_failing:
            continue
        m = re.match(r"^\t([A-Za-z_][A-Za-z0-9_]*):$", line)
        if m:
            target = m.group(1)
            continue
        m = re.match(r"^\t\t([A-Za-z_][A-Za-z0-9_]*)[./]", line)
        if m and target:
            add(target, m.group(1))
            continue
        m = re.match(r"^\t([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)[./]", line)
        if m:
            add(m.group(1), m.group(2))
            continue
        in_failing = False
print(" ".join(suites))
'

# Re-runs, once and alone, the suites a test-process crash interrupted (see
# exit code 80 in the header). $1 = simulator UDID, $2 = the kept crash log,
# $3 = the primary result bundle path or "", the rest = the subcommand's
# -skip-testing: flags. The re-run carries one -only-testing: per interrupted
# Target/Suite, intersected with the caller's ONLY_TESTING selection: a
# selector naming the suite or its target keeps the whole suite, selectors
# inside the suite (with no such ancestor) narrow the re-run to them, and a
# suite no selector covers is left out (it was not selected, so it cannot have
# been running). RETRY_SELECTORS records the identifiers re-run
# (space-separated, for the ONLY_TESTING summary merge) and RETRY_BUNDLE
# (<bundle>-retry) is written when a bundle is written at all.
# Returns the merged status: 0 when the re-run is green (the crash stays
# reported), xcodebuild's status when it fails without a crash,
# EXIT_TEST_PROCESS_CRASHED when it crashes too, when no suite can be named,
# or when TEST_CRASH_RETRY=0. The verdict is printed and appended to the job
# summary in every case.
RETRY_BUNDLE=
RETRY_SELECTORS=
retry_crashed_suites() {
  local udid=$1 log=$2 bundle=$3 suites suite id whole covered kept= nested=() selectors=() extra=() retry_log status=0 outcome=0 verdict
  shift 3
  if [ "${TEST_CRASH_RETRY:-1}" = "0" ]; then
    echo "TEST_CRASH_RETRY=0: not re-running the interrupted suite(s). Exiting $EXIT_TEST_PROCESS_CRASHED (test-process crash)." >&2
    append_step_summary ":x: Not re-run (TEST_CRASH_RETRY=0); exit $EXIT_TEST_PROCESS_CRASHED." ""
    return "$EXIT_TEST_PROCESS_CRASHED"
  fi
  command -v python3 >/dev/null 2>&1 \
    || die "python3 is required to name the suites a test-process crash interrupted (on macOS it ships with Xcode's Command Line Tools)"
  suites=$(python3 -c "$TEST_CRASH_SUITES_PY" "$log")
  if [ -z "$suites" ]; then
    echo "error: neither a restart line nor a \"Failing tests\" entry names the interrupted suite, so there is nothing to re-run.
Exiting $EXIT_TEST_PROCESS_CRASHED (test-process crash), not 65." >&2
    append_step_summary ":x: No suite could be named as interrupted; nothing to re-run (exit $EXIT_TEST_PROCESS_CRASHED)." ""
    return "$EXIT_TEST_PROCESS_CRASHED"
  fi
  for suite in $suites; do
    whole=1
    nested=()
    covered=$(( ${#ONLY_TESTING_IDS[@]} == 0 ))
    for id in ${ONLY_TESTING_IDS+"${ONLY_TESTING_IDS[@]}"}; do
      case "$suite" in
        "$id" | "$id"/*) whole=1; covered=1; break ;;
      esac
      case "$id" in
        "$suite"/*) nested+=("$id"); whole=0; covered=1 ;;
      esac
    done
    if [ "$covered" -eq 0 ]; then
      echo "notice: $suite is named as interrupted but lies outside the ONLY_TESTING selection; not re-running it." >&2
      continue
    fi
    kept="$kept $suite"
    if [ "$whole" -eq 1 ]; then
      selectors+=("-only-testing:$suite")
      RETRY_SELECTORS="$RETRY_SELECTORS $suite"
    else
      for id in "${nested[@]}"; do
        selectors+=("-only-testing:$id")
        RETRY_SELECTORS="$RETRY_SELECTORS $id"
      done
    fi
  done
  RETRY_SELECTORS=${RETRY_SELECTORS# }
  suites=${kept# }
  if [ -z "$suites" ]; then
    echo "error: every suite named as interrupted lies outside the ONLY_TESTING selection, so there is nothing to re-run.
Exiting $EXIT_TEST_PROCESS_CRASHED (test-process crash), not 65." >&2
    append_step_summary ":x: Every suite named as interrupted lies outside the ONLY_TESTING selection; nothing to re-run (exit $EXIT_TEST_PROCESS_CRASHED)." ""
    return "$EXIT_TEST_PROCESS_CRASHED"
  fi
  if [ -n "$bundle" ]; then
    case "$bundle" in
      *.xcresult) RETRY_BUNDLE=${bundle%.xcresult}-retry.xcresult ;;
      *) RETRY_BUNDLE=$bundle-retry ;;
    esac
    rm -rf -- "$RETRY_BUNDLE"
    extra+=(-resultBundlePath "$RETRY_BUNDLE")
  fi
  echo "notice: re-running the interrupted suite(s) once, alone: $suites" >&2
  acquire_simulator_lock "$udid"
  retry_log=$(mktemp "${TMPDIR:-/tmp}/xcodebuild-retry.XXXXXX")
  run_xcodebuild_logged "$retry_log" test-without-building "${PROJECT_ARGS[@]}" \
    -destination "platform=iOS Simulator,id=$udid" \
    -parallel-testing-enabled NO ${extra+"${extra[@]}"} "${selectors[@]}" "$@" || status=$?
  echo done >&9
  release_simulator_lock
  report_test_outcome "$status" "$retry_log" "the re-run" || outcome=$?
  case "$outcome" in
    0)
      echo "notice: the re-run of $suites passed; the earlier crash is recorded above (log kept at $log) and in the job summary. Exiting 0." >&2
      verdict=":white_check_mark: Re-ran once, alone: \`$suites\` — passed; the run is green (exit 0). The crash is not a test failure but is recorded above." ;;
    "$EXIT_TEST_PROCESS_CRASHED")
      echo "error: the re-run of $suites crashed as well; not retrying again.
Exiting $EXIT_TEST_PROCESS_CRASHED (test-process crash), not $status." >&2
      verdict=":x: Re-ran once, alone: \`$suites\` — crashed again (exit $EXIT_TEST_PROCESS_CRASHED)." ;;
    *)
      echo "error: the re-run of $suites failed (exit $outcome) without a crash: these are real test failures. Exiting $outcome." >&2
      verdict=":x: Re-ran once, alone: \`$suites\` — failed (exit $outcome) without a crash; real test failures." ;;
  esac
  append_step_summary "$verdict" ""
  return "$outcome"
}

cmd_resolve() {
  run_xcodebuild -resolvePackageDependencies "${PROJECT_ARGS[@]}"
}

cmd_build_ios() {
  ensure_tailcatkit
  run_xcodebuild build "${PROJECT_ARGS[@]}" \
    -destination 'generic/platform=iOS Simulator' "${SIGNING_ARGS[@]}"
}

release_signing_args() {
  [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -s "${ASC_KEY_PATH:-}" ] \
    || die "Release signing requires ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH; run through bundle exec fastlane."
  [ -n "${RELEASE_ARCHIVE_PATH:-}" ] || die "RELEASE_ARCHIVE_PATH is required."
  RELEASE_SIGNING_ARGS=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
}

cmd_archive() {
  local platform=$1 destination
  release_signing_args
  [[ "${RELEASE_VERSION:-}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
    || die "RELEASE_VERSION must be the checked MARKETING_VERSION from fastlane."
  [[ "${RELEASE_BUILD_NUMBER:-}" =~ ^[0-9]+$ ]] \
    || die "RELEASE_BUILD_NUMBER must be the next App Store Connect build number from fastlane."
  [ ! -e "$RELEASE_ARCHIVE_PATH" ] || die "Archive already exists; choose a fresh RELEASE_ARCHIVE_PATH."
  [ "${BUILD_CONFIGURATION:-Release}" = Release ] || die "Release archives only support Release."
  if [ "$platform" = ios ]; then
    destination='generic/platform=iOS'
    ensure_tailcatkit
  else
    destination='generic/platform=visionOS'
    if ! xcodebuild -showsdks 2>/dev/null | grep -- '-sdk xros' >/dev/null; then
      die "visionOS device SDK (xros) is not installed. Install the visionOS platform in Xcode before archiving."
    fi
  fi
  local extra=()
  [ -z "${SPM_CLONE_DIR:-}" ] || extra+=(-clonedSourcePackagesDirPath "$SPM_CLONE_DIR")
  [ -z "${DERIVED_DATA_DIR:-}" ] || extra+=(-derivedDataPath "$DERIVED_DATA_DIR")
  # Do not trace signing arguments or inherit the simulator's no-signing flags.
  xcodebuild archive "${PROJECT_ARGS[@]}" -configuration Release \
    -destination "$destination" -archivePath "$RELEASE_ARCHIVE_PATH" \
    "${RELEASE_SIGNING_ARGS[@]}" CODE_SIGN_STYLE=Automatic \
    "MARKETING_VERSION=$RELEASE_VERSION" "CURRENT_PROJECT_VERSION=$RELEASE_BUILD_NUMBER" \
    ${extra+"${extra[@]}"}
}

cmd_export() {
  release_signing_args
  [ -d "$RELEASE_ARCHIVE_PATH" ] || die "Release archive does not exist."
  [ -n "${RELEASE_EXPORT_PATH:-}" ] && [ -s "${RELEASE_EXPORT_OPTIONS:-}" ] \
    || die "RELEASE_EXPORT_PATH and RELEASE_EXPORT_OPTIONS are required."
  [ ! -e "$RELEASE_EXPORT_PATH" ] || die "Export path already exists; choose a fresh RELEASE_EXPORT_PATH."
  xcodebuild -exportArchive -archivePath "$RELEASE_ARCHIVE_PATH" \
    -exportPath "$RELEASE_EXPORT_PATH" -exportOptionsPlist "$RELEASE_EXPORT_OPTIONS" \
    "${RELEASE_SIGNING_ARGS[@]}"
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
# identifiers, each forwarded as one -only-testing: argument (duplicates
# collapsed). Entries starting with '-' are refused so the knob cannot smuggle
# arbitrary xcodebuild flags past the extra-argument check. Parsed before any
# simulator or xcodebuild work so a flag-like entry fails fast; the selectors
# themselves are checked against the enumerated catalog under the lock (see
# resolve_only_testing). Unset/empty leaves the command line untouched.
ONLY_TESTING_IDS=()
ONLY_TESTING_ARGS=()
ONLY_TESTING_RESOLVED=
parse_only_testing() {
  local ids=() id seen
  ONLY_TESTING_IDS=()
  ONLY_TESTING_ARGS=()
  read -r -d '' -a ids <<< "${ONLY_TESTING:-}" || true
  for id in ${ids+"${ids[@]}"}; do
    case "$id" in
      -*) die "ONLY_TESTING entry '$id' looks like a flag; entries must be Target[/Class[/method]] identifiers" ;;
    esac
    for seen in ${ONLY_TESTING_IDS+"${ONLY_TESTING_IDS[@]}"}; do
      [ "$seen" != "$id" ] || continue 2
    done
    ONLY_TESTING_IDS+=("$id")
    ONLY_TESTING_ARGS+=("-only-testing:$id")
  done
}

# Selector matching shared by the pre-run resolver and the post-run summary
# (each python program below is run as this prelude plus its own body, so
# both attribute tests to selectors by the same rules). A selector matches an
# identifier (Target/Suite/test() as enumerated by xcodebuild and as recorded
# in the result bundle) when every one of its path segments equals the
# identifier's segment at that position; the test segment also matches with
# or without a "()" / parameter list, but a suite name never matches by
# substring, so IntentTests/FooTests does not resolve to IntentTests/FooViewTests.
# The trailing argv of both programs is the subcommand's -skip-testing: flags
# (recognised by prefix) plus the selectors.
ONLY_TESTING_MATCH_PY='
import sys
def split_skips(args):
    skips, selectors = [], []
    for arg in args:
        if arg.startswith("-skip-testing:"):
            skips.append(arg[len("-skip-testing:"):])
        elif arg not in selectors:
            selectors.append(arg)
    return skips, selectors
def bare(segment):
    return segment.split("(", 1)[0]
def matches(selector_parts, identifier):
    parts = identifier.split("/")
    if len(selector_parts) > len(parts):
        return False
    for i, want in enumerate(selector_parts):
        have = parts[i]
        if want == have:
            continue
        if i == len(parts) - 1 and bare(want) == bare(have) and ("(" not in want or "(" not in have):
            continue
        return False
    return True
def excluded_by(selector, skips):
    return [skip for skip in skips if matches(skip.split("/"), selector)]
def excluded_message(selector, skip):
    return "ONLY_TESTING selector %r is excluded by -skip-testing:%s on this subcommand (unit-only subcommands skip the IntentUITests bundle; use test-ios or test-without-building for it)." % (selector, skip)
'

# Resolves the ONLY_TESTING selectors against the enumerated test catalog.
# argv: <catalog json> then the -skip-testing: flags and selectors. Enabled
# and disabled identifiers are collected tolerantly from every
# enabledTests/disabledTests list in the document (xcodebuild -enumerate-tests
# -test-enumeration-style flat -format json writes
# values[].enabledTests[].identifier as Target/Suite/test()). Prints one
# "<count>\t<selector>" line per selector on stdout (the post-run summary
# shows it as "resolved"). Exit 0 when every selector resolves to at least one
# enabled test, 1 when any does not (each named on stderr, with up to five
# look-alike targets/suites), 2 when the catalog is unreadable or lists no
# tests at all.
ONLY_TESTING_RESOLVER_PY='
import difflib, json, os
catalog_path = sys.argv[1]
skips, selectors = split_skips(sys.argv[2:])
def unverified(reason):
    sys.stderr.write("error: could not verify the ONLY_TESTING selection: %s\n" % reason)
    sys.exit(2)
try:
    with open(catalog_path) as f:
        document = json.load(f)
except (OSError, ValueError) as e:
    unverified("the test enumeration output is unreadable (%s)" % e)
enabled, disabled = [], []
def identifiers(items):
    found = []
    for item in items if isinstance(items, list) else []:
        if isinstance(item, str):
            found.append(item)
        elif isinstance(item, dict) and isinstance(item.get("identifier"), str):
            found.append(item["identifier"])
    return found
def walk(node):
    if isinstance(node, dict):
        enabled.extend(identifiers(node.get("enabledTests")))
        disabled.extend(identifiers(node.get("disabledTests")))
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
walk(document)
if not enabled and not disabled:
    unverified("the test enumeration output lists no tests (expected values[].enabledTests[].identifier)")
known = enabled + disabled
candidates = sorted(set(i.split("/")[0] for i in known)) + sorted(set("/".join(i.split("/")[:2]) for i in known if "/" in i))
def suggest(selector):
    parts = selector.split("/")
    token = (parts[1] if len(parts) > 1 else parts[0]).lower()
    scored = []
    for candidate in candidates:
        name = candidate.split("/")[-1].lower()
        score = difflib.SequenceMatcher(None, selector.lower(), candidate.lower()).ratio()
        if token and (token in name or name in token):
            score += 1
        if score >= 0.6:
            scored.append((-score, candidate))
    return [candidate for _, candidate in sorted(scored)[:5]]
unmatched = 0
resolved_identities = {}
for selector in selectors:
    parts = selector.split("/")
    excluded = excluded_by(selector, skips)
    if excluded:
        unmatched += 1
        sys.stderr.write("error: %s\n" % excluded_message(selector, excluded[0]))
        continue
    hits = [i for i in enabled if matches(parts, i)]
    if hits:
        resolved_identities[selector] = hits
        sys.stderr.write("ONLY_TESTING: %s -> %d test(s)\n" % (selector, len(hits)))
        sys.stdout.write("%d\t%s\n" % (len(hits), selector))
        continue
    unmatched += 1
    off = [i for i in disabled if matches(parts, i)]
    if off:
        sys.stderr.write("error: ONLY_TESTING selector %r matched only disabled tests (%d, e.g. %s); nothing would run.\n" % (selector, len(off), off[0]))
        continue
    sys.stderr.write("error: ONLY_TESTING selector %r matched no test in the enumerated catalog.\n" % selector)
    for candidate in suggest(selector):
        sys.stderr.write("  did you mean: %s\n" % candidate)
if unmatched:
    sys.stderr.write("error: %d ONLY_TESTING selector(s) matched nothing; the test run was not started.\n" % unmatched)
    sys.stderr.write("A selector is Target/Suite or Target/Suite/test as enumerated by xcodebuild, not a file name (IntentTests/FooTests.swift never matches).\n")
    sys.exit(1)
evidence_path = os.environ.get("ONLY_TESTING_IDENTITIES_PATH")
if evidence_path:
    try:
        with open(evidence_path, "w") as evidence:
            json.dump({"version": 1, "selectors": resolved_identities}, evidence, indent=2)
            evidence.write("\n")
    except OSError as error:
        unverified("the requested resolved identity export could not be written (%s)" % error)
'

# Enumerates the tests of the built revision and resolves every ONLY_TESTING
# selector against them; a no-op when ONLY_TESTING is empty. Runs under the
# simulator lock (enumeration loads the test bundles on the device) with the
# same project/destination arguments as the real run plus the -skip-testing:
# flags of the subcommand ($@), but without the -only-testing: arguments so the
# whole catalog is available for suggestions. Exits EXIT_SELECTOR_UNMATCHED
# when any selector resolves to nothing and EXIT_SELECTION_UNVERIFIED when
# the enumeration fails or is unparsable; the real test run never starts then.
resolve_only_testing() {
  local udid=$1 dir catalog log status=0
  shift
  [ "${#ONLY_TESTING_IDS[@]}" -gt 0 ] || return 0
  command -v python3 >/dev/null 2>&1 \
    || die "python3 is required to resolve ONLY_TESTING selectors (on macOS it ships with Xcode's Command Line Tools)"
  dir=$(mktemp -d "${TMPDIR:-/tmp}/xcodebuild-enumerate.XXXXXX")
  catalog=$dir/tests.json
  log=$dir/enumerate.log
  echo "resolving ${#ONLY_TESTING_IDS[@]} ONLY_TESTING selector(s) against the enumerated test catalog" >&2
  run_xcodebuild_logged "$log" test-without-building "${PROJECT_ARGS[@]}" \
    -destination "platform=iOS Simulator,id=$udid" \
    -enumerate-tests -test-enumeration-style flat -test-enumeration-format json \
    -test-enumeration-output-path "$catalog" "$@" || status=$?
  echo done >&9
  if [ "$status" -ne 0 ]; then
    rm -rf -- "$dir"
    release_simulator_lock
    echo "error: could not verify the ONLY_TESTING selection: xcodebuild -enumerate-tests exited $status (see its output above).
Exiting $EXIT_SELECTION_UNVERIFIED (test selection unverified), not $status." >&2
    exit "$EXIT_SELECTION_UNVERIFIED"
  fi
  ONLY_TESTING_RESOLVED=$(python3 -c "$ONLY_TESTING_MATCH_PY$ONLY_TESTING_RESOLVER_PY" "$catalog" "$@" "${ONLY_TESTING_IDS[@]}" 9>&-) || status=$?
  rm -rf -- "$dir"
  case "$status" in
    0) ;;
    1)
      release_simulator_lock
      echo "Exiting $EXIT_SELECTOR_UNMATCHED (unmatched ONLY_TESTING selector)." >&2
      exit "$EXIT_SELECTOR_UNMATCHED" ;;
    *)
      release_simulator_lock
      echo "Exiting $EXIT_SELECTION_UNVERIFIED (test selection unverified)." >&2
      exit "$EXIT_SELECTION_UNVERIFIED" ;;
  esac
}

# Summarises a filtered run from its result bundle. argv: <xcresulttool tests
# json> <GITHUB_STEP_SUMMARY path or ""> <bundle path, for messages> then the
# -skip-testing: flags and selectors; ONLY_TESTING_RESOLVED in the environment
# carries the resolver's "<count>\t<selector>" lines, and
# ONLY_TESTING_RETRY_RESULTS, when set, the xcresulttool json of the crash
# re-run's bundle with ONLY_TESTING_RETRY_SELECTORS naming what it re-ran:
# the re-run's records stand in for every primary record matching a re-run
# selector (the re-run is the later, authoritative result; a crashed suite's
# results are never trusted), except that a primary Failed the re-run did not
# record is kept as an unrecovered failure. Each re-run selector is verified
# on its own against the re-run bundle — one that recorded nothing executed
# or skipped for it fails the run whatever the caller's broader selectors
# gathered from uninterrupted suites. Walks testNodes recursively (xcrun xcresulttool get test-results
# tests, Xcode 16+): a "Test Case" node is identified as <enclosing test
# bundle name>/<nodeIdentifier> and attributed to every selector it matches;
# executed = Passed + Failed + Expected Failure, Skipped is counted apart, and
# any other result string is "unknown" (the bundle cannot be trusted). Prints
# the table on stdout and appends it as Markdown to the step summary when
# given. Exit 0, or 1 when a selector has executed + skipped = 0 (named on
# stderr; an all-skipped selector is only a notice) or the re-run recorded
# nothing for one of its selectors or left a primary Failed unrecovered, or 2
# when the JSON is unreadable or not the expected shape or a selector has an
# unknown result (2 wins over 1).
ONLY_TESTING_SUMMARY_PY='
import json, os
results_path, summary_path, bundle = sys.argv[1], sys.argv[2], sys.argv[3]
skips, selectors = split_skips(sys.argv[4:])
retry_path = os.environ.get("ONLY_TESTING_RETRY_RESULTS", "")
resolved = {}
for line in os.environ.get("ONLY_TESTING_RESOLVED", "").splitlines():
    count, _, selector = line.partition("\t")
    if selector:
        resolved[selector] = count
def unverified(reason):
    sys.stderr.write("error: could not verify the ONLY_TESTING selection: %s\n" % reason)
    sys.exit(2)
def load(path, what):
    try:
        with open(path) as f:
            loaded = json.load(f)
    except (OSError, ValueError) as e:
        unverified("%s could not be read (%s)" % (what, e))
    if not isinstance(loaded, dict) or not isinstance(loaded.get("testNodes"), list):
        unverified("%s has no testNodes list (xcresulttool output shape changed?)" % what)
    return loaded
document = load(results_path, "the result bundle %s" % bundle)
cases = []
def walk(node, bundle_name):
    if isinstance(node, list):
        for value in node:
            walk(value, bundle_name)
        return
    if not isinstance(node, dict):
        return
    kind = str(node.get("nodeType", ""))
    if kind.lower().endswith("test bundle") and isinstance(node.get("name"), str):
        bundle_name = node["name"]
    if kind == "Test Case":
        ident = str(node.get("nodeIdentifier") or node.get("name") or "")
        if bundle_name and not ident.startswith(bundle_name + "/"):
            ident = bundle_name + "/" + ident
        cases.append((ident, str(node.get("result", ""))))
        return
    walk(node.get("children", []), bundle_name)
walk(document["testNodes"], "")
EXECUTED_RESULTS = ("Passed", "Failed", "Expected Failure")
rerun_empty, unrecovered = [], []
if retry_path:
    primary, cases = cases, []
    walk(load(retry_path, "the re-run result bundle")["testNodes"], "")
    rerun = os.environ.get("ONLY_TESTING_RETRY_SELECTORS", "").split()
    recorded = set(ident for ident, _ in cases)
    kept = []
    for ident, result in primary:
        if ident in recorded:
            continue
        if any(matches(selector.split("/"), ident) for selector in rerun):
            if result == "Failed":
                unrecovered.append(ident)
                kept.append((ident, result))
            continue
        kept.append((ident, result))
    for selector in rerun:
        parts = selector.split("/")
        if not any(matches(parts, ident) and (result in EXECUTED_RESULTS or result == "Skipped") for ident, result in cases):
            rerun_empty.append(selector)
    cases = kept + cases
    bundle += " merged with the re-run"
rows, failing, notices, unknowns = [], [], [], []
for selector in selectors:
    parts = selector.split("/")
    hits = [result for ident, result in cases if matches(parts, ident)]
    skipped = sum(1 for r in hits if r == "Skipped")
    failed = sum(1 for r in hits if r == "Failed")
    executed = sum(1 for r in hits if r in EXECUTED_RESULTS)
    unknown = sorted(set(r for r in hits if r != "Skipped" and r not in EXECUTED_RESULTS))
    unknown_count = len(hits) - executed - skipped
    rows.append((selector, resolved.get(selector, "?"), str(executed), str(skipped), str(failed), str(unknown_count)))
    if unknown_count:
        unknowns.append((selector, unknown_count, unknown))
    elif executed == 0 and skipped == 0:
        failing.append(selector)
    elif executed == 0:
        notices.append((selector, skipped))
header = ("requested", "resolved", "executed", "skipped", "failed", "unknown")
width = max(len(row[0]) for row in rows + [header])
fmt = "  %-" + str(width) + "s  %8s  %8s  %7s  %6s  %7s\n"
sys.stdout.write("ONLY_TESTING summary (%d test case(s) in %s):\n" % (len(cases), bundle))
for row in [header] + rows:
    sys.stdout.write(fmt % row)
sys.stdout.flush()
if summary_path:
    try:
        with open(summary_path, "a") as f:
            f.write("### ONLY_TESTING selectors\n\n| Requested | Resolved | Executed | Skipped | Failed | Unknown |\n|---|---:|---:|---:|---:|---:|\n")
            for row in rows:
                f.write("| `%s` | %s | %s | %s | %s | %s |\n" % row)
            for selector in failing:
                f.write("\n:x: `%s` executed nothing (exit 82).\n" % selector)
            for selector in rerun_empty:
                f.write("\n:x: the crash re-run of `%s` recorded nothing executed or skipped for it; the interrupted suite is not recovered (exit 82).\n" % selector)
            for ident in unrecovered:
                f.write("\n:x: `%s` failed in the crashed run and the re-run did not record it; no recovery evidence (exit 82).\n" % ident)
            for selector, count, unknown in unknowns:
                f.write("\n:warning: `%s`: %d test(s) with an unrecognised result (%s); selection unverified (exit 83).\n" % (selector, count, ", ".join(repr(u) for u in unknown)))
            for selector, skipped in notices:
                f.write("\n:information_source: `%s`: all %d tests skipped at runtime.\n" % (selector, skipped))
            f.write("\n")
    except OSError as e:
        sys.stderr.write("warning: could not append the ONLY_TESTING summary to GITHUB_STEP_SUMMARY (%s)\n" % e)
for selector, skipped in notices:
    sys.stderr.write("notice: ONLY_TESTING selector %r: all %d of its test(s) were skipped at runtime (XCTSkip / .disabled); the selection is valid but nothing executed.\n" % (selector, skipped))
for selector in failing:
    excluded = excluded_by(selector, skips)
    if excluded:
        sys.stderr.write("error: %s\n" % excluded_message(selector, excluded[0]))
    else:
        sys.stderr.write("error: ONLY_TESTING selector %r resolved to %s test(s) but the result bundle records none executed or skipped for it.\n" % (selector, resolved.get(selector, "?")))
for selector in rerun_empty:
    sys.stderr.write("error: the crash re-run of %r recorded no test executed or skipped for it; the interrupted suite is not recovered, whatever the other selectors gathered.\n" % selector)
for ident in unrecovered:
    sys.stderr.write("error: %s failed in the crashed run and the re-run did not record it; the crashed run is no evidence either way, so it counts as unrecovered.\n" % ident)
for selector, count, unknown in unknowns:
    sys.stderr.write("error: could not verify the ONLY_TESTING selection: %d test case(s) matching %r have a result the wrapper does not recognise (%s; expected Passed / Failed / Skipped / Expected Failure — xcresulttool output changed?).\n" % (count, selector, ", ".join(repr(u) for u in unknown)))
if unknowns:
    sys.exit(2)
if failing or rerun_empty or unrecovered:
    sys.exit(1)
'

# Reads the result bundle of a filtered run and prints the per-selector
# table; a no-op when ONLY_TESTING is empty. $1 = the status so far (after
# report_test_outcome and any crash re-run), $2 = the bundle path, the rest =
# the subcommand's -skip-testing: flags; RETRY_BUNDLE, when set, is read too
# and its records replace the primary ones for everything RETRY_SELECTORS
# re-ran, each re-run selector being verified against the re-run bundle on
# its own and a primary Failed the re-run did not record staying unrecovered.
# Returns the status to exit with: a nonzero $1 is kept (with a warning when
# a bundle disagrees or is unreadable); a 0 becomes EXIT_SELECTOR_UNMATCHED
# when a resolved selector executed and skipped nothing or the re-run left an
# interrupted suite or test unrecovered, or EXIT_SELECTION_UNVERIFIED when a
# bundle cannot be read or records a result the classifier does not recognise.
summarize_only_testing() {
  local status=$1 bundle=$2 results retry_results= outcome=0
  shift 2
  [ "${#ONLY_TESTING_IDS[@]}" -gt 0 ] || return "$status"
  results=$(mktemp "${TMPDIR:-/tmp}/xcodebuild-results.XXXXXX")
  if [ ! -e "$bundle" ]; then
    echo "error: could not verify the ONLY_TESTING selection: no result bundle was written at $bundle" >&2
    outcome=2
  elif ! xcrun xcresulttool get test-results tests --path "$bundle" > "$results"; then
    echo "error: could not verify the ONLY_TESTING selection: xcrun xcresulttool could not read $bundle" >&2
    outcome=2
  elif [ -n "$RETRY_BUNDLE" ] && [ ! -e "$RETRY_BUNDLE" ]; then
    echo "error: could not verify the ONLY_TESTING selection: no result bundle was written at $RETRY_BUNDLE (the re-run)" >&2
    outcome=2
  else
    if [ -n "$RETRY_BUNDLE" ]; then
      retry_results=$(mktemp "${TMPDIR:-/tmp}/xcodebuild-results.XXXXXX")
      if ! xcrun xcresulttool get test-results tests --path "$RETRY_BUNDLE" > "$retry_results"; then
        echo "error: could not verify the ONLY_TESTING selection: xcrun xcresulttool could not read $RETRY_BUNDLE (the re-run)" >&2
        outcome=2
      fi
    fi
    if [ "$outcome" -eq 0 ]; then
      ONLY_TESTING_RESOLVED="$ONLY_TESTING_RESOLVED" ONLY_TESTING_RETRY_RESULTS="$retry_results" \
        ONLY_TESTING_RETRY_SELECTORS="$RETRY_SELECTORS" \
        python3 -c "$ONLY_TESTING_MATCH_PY$ONLY_TESTING_SUMMARY_PY" \
        "$results" "${GITHUB_STEP_SUMMARY:-}" "$bundle" "$@" "${ONLY_TESTING_IDS[@]}" || outcome=$?
    fi
  fi
  rm -f -- "$results" ${retry_results:+"$retry_results"}
  case "$outcome" in
    0) return "$status" ;;
    1)
      if [ "$status" -ne 0 ]; then
        echo "warning: the ONLY_TESTING selector(s) above executed nothing; keeping exit $status from the test run." >&2
        return "$status"
      fi
      echo "Exiting $EXIT_SELECTOR_UNMATCHED (an ONLY_TESTING selector executed nothing although xcodebuild exited 0${RETRY_SELECTORS:+, or the crash re-run left an interrupted suite or test unrecovered})." >&2
      return "$EXIT_SELECTOR_UNMATCHED" ;;
    *)
      if [ "$status" -ne 0 ]; then
        echo "warning: the ONLY_TESTING selection could not be verified from the result bundle; keeping exit $status from the test run." >&2
        return "$status"
      fi
      echo "Exiting $EXIT_SELECTION_UNVERIFIED (a run that exited 0 could not be verified from its result bundle)." >&2
      return "$EXIT_SELECTION_UNVERIFIED" ;;
  esac
}

# xcodebuild refuses an existing result bundle path, so remove it first. A
# filtered run without RESULT_BUNDLE writes a temporary bundle (in a fresh
# directory, so the path is free) that the post-run summary reads; it is
# removed after a passing run and kept, and named, after a failing one.
# Positional arguments are test-selection flags supplied by the subcommand
# dispatch below (the two unit-only variants pass
# -skip-testing:IntentUITests); they are
# appended after the unconditional flags, as are the ONLY_TESTING arguments.
#
# The simulator lock is taken before the device is touched (boot, defaults,
# selector enumeration, tests) and released as soon as xcodebuild returns; the
# outcome is then classified from the captured log (see report_test_outcome),
# a test-process crash re-runs the interrupted suites once under the lock
# again (retry_crashed_suites), and, for a filtered run, the result bundle(s)
# are checked (summarize_only_testing).
cmd_test_without_building() {
  local udid extra=() log bundle= bundle_dir= status=0 outcome=0
  parse_only_testing
  udid=$(pick_simulator)
  acquire_simulator_lock "$udid"
  enable_simulator_accessibility "$udid"
  resolve_only_testing "$udid" "$@"
  if [ -n "${RESULT_BUNDLE:-}" ]; then
    rm -rf -- "${RESULT_BUNDLE:?}"
    bundle=$RESULT_BUNDLE
  elif [ "${#ONLY_TESTING_IDS[@]}" -gt 0 ]; then
    bundle_dir=$(mktemp -d "${TMPDIR:-/tmp}/xcodebuild-result.XXXXXX")
    bundle=$bundle_dir/Intent.xcresult
  fi
  [ -z "$bundle" ] || extra+=(-resultBundlePath "$bundle")
  log=$(mktemp "${TMPDIR:-/tmp}/xcodebuild-test.XXXXXX")
  run_xcodebuild_logged "$log" test-without-building "${PROJECT_ARGS[@]}" \
    -destination "platform=iOS Simulator,id=$udid" \
    -parallel-testing-enabled NO ${extra+"${extra[@]}"} \
    ${ONLY_TESTING_ARGS+"${ONLY_TESTING_ARGS[@]}"} "$@" || status=$?
  echo done >&9
  release_simulator_lock
  report_test_outcome "$status" "$log" || outcome=$?
  if [ "$outcome" -eq "$EXIT_TEST_PROCESS_CRASHED" ]; then
    outcome=0
    retry_crashed_suites "$udid" "$log" "$bundle" "$@" || outcome=$?
  fi
  summarize_only_testing "$outcome" "$bundle" "$@" || outcome=$?
  if [ -n "$bundle_dir" ]; then
    if [ "$outcome" -eq 0 ]; then
      rm -rf -- "$bundle_dir"
    else
      echo "Result bundle kept at: $bundle" >&2
      [ -z "$RETRY_BUNDLE" ] || echo "Re-run result bundle kept at: $RETRY_BUNDLE" >&2
    fi
  fi
  return "$outcome"
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

case "${BUILD_CONFIGURATION:-}" in
  ''|Debug|Release) ;;
  *) die "BUILD_CONFIGURATION must be Debug or Release (or unset to preserve scheme defaults)" ;;
esac

case "$subcommand" in
  resolve)               cmd_resolve ;;
  build-ios)             cmd_build_ios ;;
  archive-ios)           cmd_archive ios ;;
  archive-visionos)      cmd_archive visionos ;;
  export-ios|export-visionos) cmd_export ;;
  build-visionos)        cmd_build_visionos ;;
  build-for-testing)     cmd_build_for_testing ;;
  test-without-building) cmd_test_without_building ;;
  test-without-building-unit) cmd_test_without_building -skip-testing:IntentUITests ;;
  test-ios)              parse_only_testing && cmd_build_for_testing && cmd_test_without_building ;;
  test-ios-unit)         parse_only_testing && cmd_build_for_testing && cmd_test_without_building -skip-testing:IntentUITests ;;
  pick-simulator)        pick_simulator ;;
  *)                     usage ;;
esac
