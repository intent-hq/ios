#!/usr/bin/env bash
# Builds TailcatKit.xcframework from the Go wrapper in this directory
# with gomobile bind, for iOS devices, simulators, and Mac Catalyst.
#
# Requires: macOS with Xcode command line tools and a Go toolchain
# (>= the version in go.mod). The build is reproducible: tailcat and
# golang.org/x/mobile are pinned by go.mod/go.sum, and the gomobile/
# gobind tools by GOMOBILE_VERSION below (kept equal to the x/mobile
# version in go.mod).
#
# Output: TailcatKit/build/TailcatKit.xcframework (gitignored; the
# Xcode project references it at that path).
#
# There is no xros/xrsimulator (visionOS) slice: gomobile bind has no
# visionOS target, so the Xcode project links TailcatKit for iOS only
# (platformFilters on the framework build files) and the app degrades
# the tunnel feature on visionOS (UnavailableTunnelDialer). Building the
# Go archive directly with `go build -buildmode=c-archive` against the
# xros SDK is the likely route to add a slice later.
set -euo pipefail

cd "$(dirname "$0")"

GOMOBILE_VERSION=v0.0.0-20260821190718-4776eadac327

if ! command -v go >/dev/null; then
  echo "error: Go toolchain not found in PATH" >&2
  exit 1
fi
if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: gomobile bind for iOS requires macOS/Xcode" >&2
  exit 1
fi

BIN_DIR=$(mktemp -d)
trap 'rm -rf "$BIN_DIR"' EXIT
export PATH="$BIN_DIR:$PATH"

echo "== Installing pinned gomobile/gobind =="
GOBIN="$BIN_DIR" go install \
  "golang.org/x/mobile/cmd/gomobile@$GOMOBILE_VERSION" \
  "golang.org/x/mobile/cmd/gobind@$GOMOBILE_VERSION"
gomobile init

mkdir -p build
rm -rf build/TailcatKit.xcframework

echo "== gomobile bind =="
gomobile bind \
  -target ios,iossimulator,maccatalyst \
  -iosversion 16.0 \
  -trimpath \
  -ldflags "-s -w" \
  -o build/TailcatKit.xcframework \
  .

cp LICENSE.tailcat build/TailcatKit.xcframework/

echo "== Done =="
du -sh build/TailcatKit.xcframework
