#!/usr/bin/env bash
set -euo pipefail

# Print the UDID of an iPhone 16 simulator on the newest installed iOS runtime
# with the same major version as the selected Xcode's iOS simulator SDK (Xcode
# 26.3 ships SDK 26.2 and pairs with the iOS 26.3.x runtime), creating one when
# none exists. Used only on the self-hosted Mac, which also has other runtimes
# installed (for example iOS 27 for the default Xcode). Unlike
# scripts/xcodebuild.sh pick-simulator, it pins the iPhone 16 model and creates
# an owned device. Hosted runners keep pick-simulator.
device_type='iPhone 16'
sdk_version=$(xcrun --sdk iphonesimulator --show-sdk-version)
sdk_major=${sdk_version%%.*}

runtime_json=$(xcrun simctl list runtimes -j | jq -c --arg major "$sdk_major" '
  [.runtimes[]
   | select(.platform == "iOS" and .isAvailable and (.version | split(".")[0]) == $major)]
  | sort_by(.version | split(".") | map(tonumber)) | last // empty')
if [ -z "$runtime_json" ]; then
  echo "::error::no iOS $sdk_major.x simulator runtime is installed for $DEVELOPER_DIR. Install it with: xcodebuild -downloadPlatform iOS" >&2
  exit 1
fi
runtime=$(jq -r .identifier <<< "$runtime_json")
runtime_version=$(jq -r .version <<< "$runtime_json")
name="CI $device_type (iOS $runtime_version)"

udid=$(xcrun simctl list devices available -j | jq -r --arg rt "$runtime" --arg name "$name" \
  '.devices[$rt] // [] | map(select(.name == $name)) | first | .udid // empty')
if [ -z "$udid" ]; then
  udid=$(xcrun simctl create "$name" "$device_type" "$runtime")
  echo "Created simulator: $name ($udid)" >&2
fi
echo "Selected simulator: $name ($udid)" >&2
echo "$udid"
