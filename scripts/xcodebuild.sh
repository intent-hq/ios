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
#   pick-simulator          Print the chosen iPhone simulator UDID on stdout
#
# Environment knobs (all optional; local runs need none):
#   SIM_UDID          Simulator UDID for test destinations; when unset the
#                     newest available iPhone simulator is picked automatically.
#   SPM_CLONE_DIR     Passed as -clonedSourcePackagesDirPath (CI caches it).
#   RESULT_BUNDLE     Passed as -resultBundlePath to test-without-building;
#                     an existing bundle at that path is removed first.
set -euo pipefail

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
  pick-simulator          Print the chosen iPhone simulator UDID on stdout

Optional env knobs: SIM_UDID, SPM_CLONE_DIR, RESULT_BUNDLE (see script header).
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

cmd_resolve() {
  run_xcodebuild -resolvePackageDependencies "${PROJECT_ARGS[@]}"
}

cmd_build_ios() {
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
enable_simulator_accessibility() {
  local udid=$1
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  xcrun simctl spawn "$udid" defaults write com.apple.Accessibility \
    ApplicationAccessibilityEnabled -bool true
  xcrun simctl spawn "$udid" defaults write com.apple.Accessibility \
    AccessibilityEnabled -bool true
}

# xcodebuild refuses an existing result bundle path, so remove it first.
cmd_test_without_building() {
  local udid extra=()
  udid=$(pick_simulator)
  enable_simulator_accessibility "$udid"
  if [ -n "${RESULT_BUNDLE:-}" ]; then
    rm -rf -- "${RESULT_BUNDLE:?}"
    extra+=(-resultBundlePath "$RESULT_BUNDLE")
  fi
  run_xcodebuild test-without-building "${PROJECT_ARGS[@]}" \
    -destination "platform=iOS Simulator,id=$udid" \
    -parallel-testing-enabled NO ${extra+"${extra[@]}"}
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
  test-ios)              cmd_build_for_testing && cmd_test_without_building ;;
  pick-simulator)        pick_simulator ;;
  *)                     usage ;;
esac
