#!/usr/bin/env bash
# Xcode Cloud post-clone step (Xcode Cloud convention: executable
# scripts in ci_scripts/ at the repo root, run with this directory as
# the working directory).
#
# iOS needs the gitignored TailcatKit framework; visionOS does not link it.
# Keep the toolchain and checksums together when updating the Go pin.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

case "${CI_PRODUCT_PLATFORM:-}" in
  visionOS|visionos|xrOS|xros)
    echo "== Skipping Go/TailcatKit for ${CI_PRODUCT_PLATFORM}: linked on iOS only =="
    exit 0
    ;;
  iOS|"") ;;
  *)
    echo "error: unsupported CI_PRODUCT_PLATFORM: $CI_PRODUCT_PLATFORM" >&2
    exit 1
    ;;
esac

if [ "$(uname -s)" != Darwin ]; then
  echo "error: iOS TailcatKit setup requires macOS/Xcode" >&2
  exit 1
fi

GO_VERSION=1.27.1
# Official archive SHA256 values: https://go.dev/dl/?mode=json
case "$(uname -m)" in
  arm64)
    GO_ARCH=arm64
    GO_SHA256=ee215d57e0ec269c60cc9ceca68e6bda321ba9ee5afe24f4b0988703c2d87d12
    ;;
  x86_64)
    GO_ARCH=amd64
    GO_SHA256=8f8f52c6649542cf027bbc9b9c68d1ec042f9f34808a40413f0b8b3f66f3caa4
    ;;
  *)
    echo "error: unsupported Go host architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

GO_SETUP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/intent-xcode-cloud-go.XXXXXX")
trap 'rm -rf "$GO_SETUP_DIR"' EXIT
archive="$GO_SETUP_DIR/go.tar.gz"
echo "== Downloading Go $GO_VERSION for darwin/$GO_ARCH =="
curl --fail --location --silent --show-error \
  --proto '=https' --proto-redir '=https' \
  --retry 3 --retry-all-errors --retry-delay 2 --retry-max-time 300 \
  --connect-timeout 15 --max-time 120 \
  "https://go.dev/dl/go${GO_VERSION}.darwin-${GO_ARCH}.tar.gz" -o "$archive"
if ! printf '%s  %s\n' "$GO_SHA256" "$archive" | shasum -a 256 -c -; then
  echo "error: Go archive checksum mismatch; refusing to extract it" >&2
  exit 1
fi
tar -xzf "$archive" -C "$GO_SETUP_DIR"
export GOROOT="$GO_SETUP_DIR/go"
export PATH="$GOROOT/bin:$PATH"
export GOTOOLCHAIN=local
hash -r
actual_version=$(go env GOVERSION)
if [ "$actual_version" != "go$GO_VERSION" ]; then
  echo "error: expected go$GO_VERSION, found $actual_version" >&2
  exit 1
fi
required=$(sed -n 's/^go //p' "$REPO_ROOT/TailcatKit/go.mod")
echo "== Go toolchain: $(go version) (go.mod requires go $required) =="

mkdir -p "$REPO_ROOT/TailcatKit/build"
LOG_DIR=$(mktemp -d "$REPO_ROOT/TailcatKit/build/post-clone.XXXXXX")
echo "== TailcatKit build logs: $LOG_DIR =="
for attempt in 1 2; do
  log="$LOG_DIR/attempt-$attempt.log"
  echo "== Building TailcatKit.xcframework (attempt $attempt/2) =="
  if "$REPO_ROOT/TailcatKit/build_xcframework.sh" 2>&1 | tee "$log"; then
    exit 0
  else
    statuses=("${PIPESTATUS[@]}")
  fi
  if [ "${statuses[1]}" -ne 0 ]; then
    echo "error: could not preserve TailcatKit build diagnostics in $log" >&2
    exit "${statuses[1]}"
  fi
  status=${statuses[0]}
  # ios#616: retry only the observed compiler crash, keeping both full logs.
  if [ "$attempt" -eq 1 ] &&
    grep -Fxq 'fatal error: sweep increased allocation count' "$log" &&
    grep -Fq 'cmd/compile/internal/' "$log"; then
    echo "warning: Go compiler sweep crash; retrying once. Original log: $log" >&2
    continue
  fi
  echo "error: TailcatKit build failed (exit $status). Log: $log" >&2
  exit "$status"
done
