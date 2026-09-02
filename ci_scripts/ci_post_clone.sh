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

if ! command -v go >/dev/null; then
  echo "== Installing Go via Homebrew =="
  if ! command -v brew >/dev/null; then
    echo "error: neither go nor brew found in PATH" >&2
    exit 1
  fi
  brew install go
fi

# The go command auto-downloads the toolchain version go.mod requires
# (any go >= 1.21 supports this), so a brew go older than go.mod's
# requirement still works; just surface both versions for the log.
required=$(sed -n 's/^go //p' "$REPO_ROOT/TailcatKit/go.mod")
echo "== Go toolchain: $(go version) (go.mod requires go $required) =="

echo "== Building TailcatKit.xcframework =="
"$REPO_ROOT/TailcatKit/build_xcframework.sh"
