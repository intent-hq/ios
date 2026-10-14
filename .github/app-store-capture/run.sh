#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${RUNNER_TEMP:?}" "${GITHUB_RUN_ID:?}"
export CAPTURE_ROOT="$RUNNER_TEMP/listing-capture-$GITHUB_RUN_ID"
mkdir -p "$CAPTURE_ROOT"
git rev-parse HEAD > "$CAPTURE_ROOT/harness-sha.txt"
git diff --exit-code 3f70e5e51f3e4b84157e571875661b9d171cf272 -- Intent/
printf '%s\n' 3f70e5e51f3e4b84157e571875661b9d171cf272 > "$CAPTURE_ROOT/candidate-sha.txt"
python3 .github/app-store-capture/prepare.py
udid=''
capture_pid=''
failed=0
cleanup() {
  if [ -n "$capture_pid" ]; then kill "$capture_pid" 2>/dev/null || true; fi
  if [ -n "$udid" ]; then
    xcrun simctl shutdown "$udid" || true
    xcrun simctl delete "$udid" || true
  fi
}
trap cleanup EXIT
for spec in \
 'APP_APPLE_VISION_PRO|visionos|com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro-4K' \
 'APP_IPHONE_67|ios|com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max' \
 'APP_IPHONE_65|ios|com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro-Max' \
 'APP_IPAD_PRO_3GEN_129|ios|com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB'; do
  IFS='|' read -r slot platform device_type <<< "$spec"
  output="$CAPTURE_ROOT/$slot"
  mkdir -p "$output"
  xcrun simctl list runtimes -j > "$output/runtimes.json"
  runtime=$(python3 - "$output/runtimes.json" "$device_type" <<'PY'
import json,sys
runtimes=json.load(open(sys.argv[1]))['runtimes']
compatible=[r for r in runtimes if r.get('isAvailable') and any(d['identifier']==sys.argv[2] for d in r.get('supportedDeviceTypes',[]))]
if not compatible: raise SystemExit('No installed runtime supports '+sys.argv[2])
print(max(compatible,key=lambda r:tuple(map(int,r['version'].split('.'))))['identifier'])
PY
)
  udid=$(xcrun simctl create "IntentCapture-$GITHUB_RUN_ID-$slot" "$device_type" "$runtime")
  printf '%s\n' "$udid" > "$output/simulator-udid.txt"
  if [ "$slot" = APP_IPAD_PRO_3GEN_129 ]; then
    plist="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Library/Preferences/com.apple.springboard.plist"
    mkdir -p "$(dirname "$plist")"
    /usr/libexec/PlistBuddy -c 'Add :SBMedusaMultitaskingEnabled bool false' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :SBChamoisWindowingEnabled bool false' "$plist"
  fi
  xcrun simctl boot "$udid"
  open -a "$DEVELOPER_DIR/Applications/Simulator.app" --args -CurrentDeviceUDID "$udid"
  xcrun simctl bootstatus "$udid" -b
  if [ "$platform" = ios ]; then
    xcrun simctl ui "$udid" appearance light
    xcrun simctl status_bar "$udid" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
  fi
  python3 .github/app-store-capture/capture_host.py "$output" "$udid" &
  capture_pid=$!
  export SIM_UDID="$udid" CAPTURE_PLATFORM="$platform" TEST_RUNNER_CAPTURE_OUTPUT="$output"
  export DERIVED_DATA_DIR="$CAPTURE_ROOT/derived-$platform" RESULT_BUNDLE="$output/capture.xcresult"
  if ! scripts/xcodebuild.sh capture-screenshots > "$output/build-test.log" 2>&1; then
    xcrun simctl io "$udid" screenshot "$output/failure.png" || true
    tail -80 "$output/build-test.log"
    failed=1
    cleanup
    udid=''
    capture_pid=''
    continue
  fi
  touch "$output/stop"
  wait "$capture_pid"
  capture_pid=''
  xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --format json > "$output/test-summary.json"
  sips -g pixelWidth -g pixelHeight "$output"/*.png > "$output/dimensions.txt"
  cleanup
  udid=''
done
git diff --exit-code 3f70e5e51f3e4b84157e571875661b9d171cf272 -- Intent/
[ "$failed" = 0 ] || exit 1
python3 .github/app-store-capture/verify.py "$CAPTURE_ROOT"
