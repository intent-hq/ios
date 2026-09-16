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
#                         (falling back to /tmp).
#
# Simulator lock: test-without-building (and so test-ios / test-ios-unit) holds
# an exclusive lock on the chosen simulator for the duration of the xcodebuild
# test run. Two runs driving one device concurrently (two agents in one
# checkout, or two checkouts picking the same device) kill each other's test
# processes and produce disjoint, false "Failing tests" lists
# (intent-hq/intent#4563). The lock is a symlink
# <SIM_LOCK_DIR>/xcodebuild-sim-<UDID>.lock -> <holder PID>, created atomically
# with ln -s (stock macOS Bash 3.2 has no flock). A waiter prints who holds the
# lock and polls once a second; a lock whose holder PID no longer exists is
# stale and reclaimed. CI runs one job per VM, so the lock is never contended
# there.
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
# pipefail makes the pipeline report xcodebuild's own status.
run_xcodebuild_logged() {
  local log=$1 extra=()
  shift
  while IFS= read -r arg; do extra+=("$arg"); done < <(common_args)
  (
    set -x
    xcodebuild "$@" ${extra+"${extra[@]}"}
  ) 2>&1 | tee "$log"
}

# Simulator lock (see the header). The symlink target is the holder's PID, so
# ln -s both takes the lock and records the owner in one atomic step; readlink
# reads it back. Held by this shell, not a subshell, so $$ is the owner.
SIM_LOCK_PATH=
acquire_simulator_lock() {
  local udid=$1 dir timeout holder err waited=0 announced=0 misses=0
  dir=${SIM_LOCK_DIR:-${TMPDIR:-/tmp}}
  timeout=${SIM_LOCK_TIMEOUT:-1800}
  case "$timeout" in
    ''|*[!0-9]*) die "SIM_LOCK_TIMEOUT must be a non-negative integer number of seconds (got '$timeout')" ;;
  esac
  mkdir -p -- "$dir"
  SIM_LOCK_PATH="${dir%/}/xcodebuild-sim-$udid.lock"
  while ! err=$(ln -s "$$" "$SIM_LOCK_PATH" 2>&1); do
    if [ -e "$SIM_LOCK_PATH" ] && [ ! -L "$SIM_LOCK_PATH" ]; then
      die "$SIM_LOCK_PATH exists but is not a lock symlink; remove it to continue"
    fi
    holder=$(readlink "$SIM_LOCK_PATH" 2>/dev/null || true)
    if [ -z "$holder" ]; then
      # Either released between the failed ln and readlink (retry at once)
      # or ln keeps failing for another reason (surface it, don't spin).
      misses=$((misses + 1))
      if [ "$misses" -ge 3 ]; then
        SIM_LOCK_PATH=
        die "cannot create simulator lock: $err"
      fi
      continue
    fi
    misses=0
    if ! kill -0 "$holder" 2>/dev/null; then
      echo "notice: reclaiming stale simulator lock $SIM_LOCK_PATH (holder PID $holder is gone)" >&2
      rm -f -- "$SIM_LOCK_PATH"
      continue
    fi
    if [ "$waited" -ge "$timeout" ]; then
      echo "error: timed out after ${timeout}s waiting for simulator $udid: lock $SIM_LOCK_PATH is held by PID $holder.
Wait for that run to finish (or raise SIM_LOCK_TIMEOUT), or pick another device with SIM_UDID." >&2
      SIM_LOCK_PATH=
      exit "$EXIT_SIM_LOCK_TIMEOUT"
    fi
    if [ "$announced" -eq 0 ]; then
      echo "waiting for simulator $udid: lock $SIM_LOCK_PATH is held by PID $holder (another xcodebuild.sh test run); giving up after ${timeout}s" >&2
      announced=1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$announced" -eq 1 ]; then
    echo "acquired simulator lock after ${waited}s" >&2
  fi
}

release_simulator_lock() {
  if [ -n "$SIM_LOCK_PATH" ] && [ "$(readlink "$SIM_LOCK_PATH" 2>/dev/null || true)" = "$$" ]; then
    rm -f -- "$SIM_LOCK_PATH"
  fi
  SIM_LOCK_PATH=
}

# The EXIT trap releases the lock on any exit path; the signal traps turn an
# interrupt into a normal exit so that the EXIT trap runs.
trap release_simulator_lock EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Lines xcodebuild prints when the test process itself died or the connection
# to it was lost, as opposed to a test assertion failing. In both cases
# xcodebuild exits 65 and lists whatever tests were in flight under "Failing
# tests", which is what makes a crash look like a test failure (ios#238) and
# a concurrent-run corruption look like flaky tests (intent#4563).
TEST_CRASH_PATTERN='Restarting after unexpected exit, crash, or test timeout|Test crashed with signal|Early unexpected exit, operation never finished bootstrapping|Lost connection to the test manager service|Test runner (exited|never began executing|crashed)|The test runner exited with code'

# $1 = xcodebuild status, $2 = log path. Returns the status to exit with:
# EXIT_TEST_PROCESS_CRASHED when the log shows a test-process crash or
# termination (the log is kept and named), else xcodebuild's status unchanged.
report_test_outcome() {
  local status=$1 log=$2 crashes
  crashes=$(grep -E "$TEST_CRASH_PATTERN" "$log" | awk '!seen[$0]++' | head -n 40 || true)
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
enable_simulator_accessibility() {
  local udid=$1
  xcrun simctl boot "$udid" 2>&1 | grep -v 'current state: Booted' || true
  xcrun simctl bootstatus "$udid" -b || true
  xcrun simctl spawn "$udid" defaults write com.apple.Accessibility \
    ApplicationAccessibilityEnabled -bool true
  xcrun simctl spawn "$udid" defaults write com.apple.Accessibility \
    AccessibilityEnabled -bool true
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
