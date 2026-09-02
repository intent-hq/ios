#!/usr/bin/env bash
# Xcode Cloud post-clone step (Xcode Cloud convention: executable
# scripts in ci_scripts/ at the repo root, run with this directory as
# the working directory).
#
# TailcatKit/build/TailcatKit.xcframework is a gitignored build
# artifact the Xcode project references; a fresh Xcode Cloud clone
# does not contain it, so archive/build actions fail without this
# step. GitHub CI builds it in .github/workflows/ci.yml (with a
# cache); here we install a Go toolchain and run the same pinned,
# reproducible build script (see TailcatKit/build_xcframework.sh —
# module versions come from go.mod/go.sum, gomobile/gobind are pinned
# by GOMOBILE_VERSION there).
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

# A go >= 1.21 auto-downloads the exact toolchain version go.mod
# requires, so any modern go works regardless of go.mod's (newer)
# requirement; older gos cannot and must be replaced.
go_is_usable() {
  command -v go >/dev/null || return 1
  v=$(go env GOVERSION 2>/dev/null) || return 1
  v=${v#go}
  major=${v%%.*}
  minor=${v#*.}
  minor=${minor%%[!0-9]*}
  [ "${major:-0}" -gt 1 ] 2>/dev/null ||
    { [ "${major:-0}" -eq 1 ] && [ "${minor:-0}" -ge 21 ]; } 2>/dev/null
}

if ! go_is_usable; then
  echo "== Installing Go via Homebrew =="
  if ! command -v brew >/dev/null; then
    echo "error: no usable go (>= 1.21) and no brew found in PATH" >&2
    exit 1
  fi
  HOMEBREW_NO_AUTO_UPDATE=1 brew install go
  hash -r
  if ! go_is_usable; then
    echo "error: still no usable go (>= 1.21) after brew install" >&2
    exit 1
  fi
fi

required=$(sed -n 's/^go //p' "$REPO_ROOT/TailcatKit/go.mod")
echo "== Go toolchain: $(go version) (go.mod requires go $required) =="

echo "== Building TailcatKit.xcframework =="
"$REPO_ROOT/TailcatKit/build_xcframework.sh"
