#!/usr/bin/env bash
# Explicit, user-owned Linux setup. The lint gate never installs anything.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=swiftlint-tools.sh
source "$SCRIPT_DIR/swiftlint-tools.sh"

case "$#:${1:-}" in
  0:) mode=install ;;
  1:--check) mode=check ;;
  *) swiftlint_error 'usage: scripts/setup-swiftlint.sh [--check]'; exit 1 ;;
esac
sourcekit_override=${LINUX_SOURCEKIT_LIB_PATH+x}

if [ "$mode" = check ] || [ "$(uname -s)" = Darwin ]; then
  swiftlint_find
  swiftlint_version_check
  swiftlint_linux_preflight
  echo "SwiftLint $EXPECTED_SWIFTLINT_VERSION is ready: $SWIFTLINT_PATH"
  exit 0
fi

if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
  swiftlint_error 'Native setup supports Ubuntu 24.04 x86_64 only; use that host, or use the existing macOS SwiftLint 0.65.1 + Xcode setup.'
  exit 1
fi
# shellcheck source=/dev/null
source /etc/os-release
if [ "$ID" != ubuntu ] || [ "$VERSION_ID" != 24.04 ]; then
  swiftlint_error "Native setup supports Ubuntu 24.04 x86_64 only (found $ID $VERSION_ID); use a supported host."
  exit 1
fi
case "$SWIFTLINT_INSTALL_DIR" in
  /*) ;;
  *) swiftlint_error 'INTENT_SWIFTLINT_HOME must be an absolute path'; exit 1 ;;
esac

if (swiftlint_find && swiftlint_version_check && swiftlint_linux_preflight) 2>/dev/null; then
  exec "$SCRIPT_DIR/setup-swiftlint.sh" --check
fi
for tool in curl sha256sum tar python3 gpg; do
  if ! command -v "$tool" >/dev/null; then
    swiftlint_error "Missing $tool. Run: sudo apt-get update && sudo apt-get install -y ca-certificates coreutils curl gnupg tar python3"
    exit 1
  fi
done

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/intent-swiftlint-setup.XXXXXX")
trap 'rm -rf -- "$TEMP_ROOT"' EXIT
download() {
  curl --fail --location --silent --show-error --compressed --retry 3 --proto '=https' "$1" -o "$2"
  printf '%s  %s\n' "$3" "$2" | sha256sum --check --status || {
    swiftlint_error "Checksum mismatch for $1; download was not installed. Re-run scripts/setup-swiftlint.sh."
    return 1
  }
}

if ! swiftlint_find 2>/dev/null; then
  # Same official release and checksum previously pinned in ci.yml.
  download "https://github.com/realm/SwiftLint/releases/download/$EXPECTED_SWIFTLINT_VERSION/swiftlint_linux_amd64.zip" \
    "$TEMP_ROOT/swiftlint.zip" caeed6f4a679c35539ffaf124f6c4ab4a8416917f7d8796279dc52b74026059d
  mkdir -p "$SWIFTLINT_INSTALL_DIR/bin"
  python3 - "$TEMP_ROOT/swiftlint.zip" "$SWIFTLINT_INSTALL_DIR/bin/swiftlint" <<'PY'
from pathlib import Path
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    target = Path(sys.argv[2])
    target.write_bytes(archive.read("swiftlint"))
    target.chmod(0o755)
PY
  swiftlint_find
fi
swiftlint_version_check

if ! swiftlint_linux_preflight; then
  # An explicit override is a user choice, never silently replaced by setup.
  if [ "$sourcekit_override" = x ]; then
    swiftlint_error 'The explicit LINUX_SOURCEKIT_LIB_PATH is unusable; correct it or run: unset LINUX_SOURCEKIT_LIB_PATH; scripts/setup-swiftlint.sh'
    exit 1
  fi
  # Official Swiftly 1.1.2 archive, verified against Swift.org's detached
  # signature before recording this SHA256. Swiftly verifies Swift's signature.
  download https://download.swift.org/swiftly/linux/swiftly-1.1.2-x86_64.tar.gz \
    "$TEMP_ROOT/swiftly.tar.gz" 21ad3d6376af0b423435f1f7295364add66c7173ea342654f4ae536c20ae88ba
  tar -xzf "$TEMP_ROOT/swiftly.tar.gz" -C "$TEMP_ROOT" swiftly
  export SWIFTLY_HOME_DIR="$SWIFTLINT_INSTALL_DIR/swiftly"
  export SWIFTLY_BIN_DIR="$SWIFTLINT_INSTALL_DIR/swiftly-bin"
  export SWIFTLY_TOOLCHAINS_DIR="$SWIFTLY_HOME_DIR/toolchains"
  export GNUPGHOME="$SWIFTLINT_INSTALL_DIR/gnupg"
  mkdir -p "$GNUPGHOME"
  chmod 700 "$GNUPGHOME"
  "$TEMP_ROOT/swiftly" init --no-modify-profile --skip-install --quiet-shell-followup \
    --assume-yes --platform ubuntu24.04
  "$SWIFTLY_BIN_DIR/swiftly" install "$SWIFTLINT_SWIFT_VERSION" --verify --assume-yes \
    --post-install-file "$TEMP_ROOT/system-dependencies.sh"
fi
if ! swiftlint_linux_preflight; then
  if [ -s "$TEMP_ROOT/system-dependencies.sh" ]; then
    echo 'Install Swift system dependencies with sudo, then re-run scripts/setup-swiftlint.sh:' >&2
    cat "$TEMP_ROOT/system-dependencies.sh" >&2
    echo >&2
  fi
  exit 1
fi
echo "SwiftLint $EXPECTED_SWIFTLINT_VERSION is ready: $SWIFTLINT_PATH"
echo "SourceKit: ${LINUX_SOURCEKIT_LIB_PATH:-SwiftLint default search paths}"
echo 'Run scripts/swiftlint.sh (no PATH or shell-profile changes needed).'
