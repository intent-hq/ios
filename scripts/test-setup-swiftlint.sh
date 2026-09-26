#!/usr/bin/env bash
# Setup boundaries: offline checks/reuse, unsupported hosts, verified downloads.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/intent-swiftlint-setup-test.XXXXXX")
trap 'rm -rf -- "$TEMP_ROOT"' EXIT
mkdir -p "$TEMP_ROOT/bin"
for tool in bash dirname python3 sha256sum gpg tar mktemp rm cat grep chmod mkdir env ln mv; do
  ln -s "$(command -v "$tool")" "$TEMP_ROOT/bin/$tool"
done
cat > "$TEMP_ROOT/bin/uname" <<'EOF'
#!/bin/bash
if [ "$1" = -m ]; then echo "${SETUP_TEST_ARCH:-x86_64}"; else echo "${SETUP_TEST_OS:-Linux}"; fi
EOF
cat > "$TEMP_ROOT/bin/swiftlint" <<'EOF'
#!/bin/bash
echo "$*" >> "$SETUP_TEST_INVOCATIONS"
if [ -n "${SETUP_TEST_MISSING_LIBRARY:-}" ] && [ "${SETUP_TEST_OS:-Linux}" = Linux ]; then
  echo "error while loading shared libraries: $SETUP_TEST_MISSING_LIBRARY" >&2
  exit 127
fi
if [ "$1" = version ]; then echo "${SETUP_TEST_VERSION:-0.65.1}"; else
  cat >/dev/null
  exit "${SETUP_TEST_PROBE_STATUS:-0}"
fi
EOF
cat > "$TEMP_ROOT/bin/ldd" <<'EOF'
#!/bin/bash
echo "$*" >> "$SETUP_TEST_LIBRARY_CHECKS"
if [ -n "${SETUP_TEST_MISSING_LIBRARY:-}" ]; then
  printf '\t%s => not found\n' "$SETUP_TEST_MISSING_LIBRARY"
fi
# glibc ldd can succeed even when a library is missing.
exit 0
EOF
cat > "$TEMP_ROOT/bin/curl" <<'EOF'
#!/bin/bash
echo "$*" >> "$SETUP_TEST_DOWNLOADS"
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then printf 'corrupt archive\n' > "$2"; exit 0; fi
  shift
done
exit 99
EOF
chmod +x "$TEMP_ROOT/bin/uname" "$TEMP_ROOT/bin/swiftlint" "$TEMP_ROOT/bin/curl" "$TEMP_ROOT/bin/ldd"
export PATH="$TEMP_ROOT/bin"
export INTENT_SWIFTLINT_HOME="$TEMP_ROOT/install"
export SETUP_TEST_DOWNLOADS="$TEMP_ROOT/downloads"
export SETUP_TEST_INVOCATIONS="$TEMP_ROOT/invocations"
export SETUP_TEST_LIBRARY_CHECKS="$TEMP_ROOT/library-checks"
unset LINUX_SOURCEKIT_LIB_PATH

expect_failure() {
  local expected=$1 output status
  shift
  set +e
  output=$("$@" 2>&1)
  status=$?
  set -e
  if [ "$status" -ne 1 ] || ! grep -Fq "$expected" <<< "$output"; then
    echo "FAIL: expected exit 1 containing '$expected', got $status: $output" >&2
    exit 1
  fi
}

"$SCRIPT_DIR/setup-swiftlint.sh" --check
"$SCRIPT_DIR/setup-swiftlint.sh"
[ ! -e "$INTENT_SWIFTLINT_HOME" ] && [ ! -e "$SETUP_TEST_DOWNLOADS" ]
expect_failure 'usage:' "$SCRIPT_DIR/setup-swiftlint.sh" --fix
expect_failure 'usage:' "$SCRIPT_DIR/setup-swiftlint.sh" ''
expect_failure 'usage:' "$SCRIPT_DIR/setup-swiftlint.sh" --check ''
expect_failure 'Ubuntu 24.04 x86_64 only' env SETUP_TEST_ARCH=aarch64 "$SCRIPT_DIR/setup-swiftlint.sh"
expect_failure 'LINUX_SOURCEKIT_LIB_PATH' env LINUX_SOURCEKIT_LIB_PATH="$TEMP_ROOT/absent" "$SCRIPT_DIR/setup-swiftlint.sh"
expect_failure 'found 0.65.0' env SETUP_TEST_VERSION=0.65.0 "$SCRIPT_DIR/setup-swiftlint.sh" --check
expect_failure 'found 0.65.0' env SETUP_TEST_VERSION=0.65.0 "$SCRIPT_DIR/setup-swiftlint.sh"
[ ! -e "$SETUP_TEST_DOWNLOADS" ]

# An absent Python prerequisite must be diagnosed without installing anything.
rm "$TEMP_ROOT/bin/python3"
expect_failure 'sudo apt-get install -y python3' "$SCRIPT_DIR/setup-swiftlint.sh" --check
[ ! -e "$SETUP_TEST_DOWNLOADS" ]
ln -s /usr/bin/python3 "$TEMP_ROOT/bin/python3"

# Diagnose binary libraries before version, probes, or runtime downloads. Check
# both PATH and managed binaries, and keep the documented apt command in sync.
expect_missing_library() {
  local output status apt_command
  rm -f "$SETUP_TEST_INVOCATIONS"
  set +e
  output=$(env SETUP_TEST_MISSING_LIBRARY=libxml2.so.2 "$@" 2>&1)
  status=$?
  set -e
  apt_command=$(grep '^sudo apt-get install -y ' "$SCRIPT_DIR/../README.md")
  if [ "$status" -ne 1 ] || ! grep -Fq 'libxml2.so.2' <<< "$output" ||
    [[ " $apt_command " != *' libxml2 '* ]] || ! grep -Fq "$apt_command" <<< "$output" ||
    [ -e "$SETUP_TEST_INVOCATIONS" ] || [ -e "$SETUP_TEST_DOWNLOADS" ]; then
    echo "FAIL: missing libxml2 must report the documented apt prerequisites before running SwiftLint or downloading a runtime; got $status: $output" >&2
    exit 1
  fi
}
for location in path managed; do
  if [ "$location" = managed ]; then
    mkdir -p "$INTENT_SWIFTLINT_HOME/bin"
    mv "$TEMP_ROOT/bin/swiftlint" "$INTENT_SWIFTLINT_HOME/bin/swiftlint"
  fi
  expect_missing_library "$SCRIPT_DIR/setup-swiftlint.sh"
  expect_missing_library "$SCRIPT_DIR/setup-swiftlint.sh" --check
  expect_missing_library "$SCRIPT_DIR/swiftlint.sh"
done
mv "$INTENT_SWIFTLINT_HOME/bin/swiftlint" "$TEMP_ROOT/bin/swiftlint"
rm -r "$INTENT_SWIFTLINT_HOME"

# Missing dependency-inspection tooling is actionable too.
mv "$TEMP_ROOT/bin/ldd" "$TEMP_ROOT/ldd"
expect_failure 'libc-bin' "$SCRIPT_DIR/setup-swiftlint.sh" --check
[ ! -e "$SETUP_TEST_INVOCATIONS" ] && [ ! -e "$SETUP_TEST_DOWNLOADS" ]
mv "$TEMP_ROOT/ldd" "$TEMP_ROOT/bin/ldd"

# Darwin must never inspect Linux shared libraries.
rm -f "$SETUP_TEST_LIBRARY_CHECKS"
env SETUP_TEST_OS=Darwin SETUP_TEST_MISSING_LIBRARY=libxml2.so.2 "$SCRIPT_DIR/setup-swiftlint.sh"
[ ! -e "$SETUP_TEST_LIBRARY_CHECKS" ] && [ ! -e "$SETUP_TEST_DOWNLOADS" ]

# Reject a corrupt Swiftly bootstrap before extracting or executing it.
expect_failure 'Checksum mismatch' env SETUP_TEST_PROBE_STATUS=132 "$SCRIPT_DIR/setup-swiftlint.sh"
grep -Fq 'swiftly-1.1.2-x86_64.tar.gz' "$SETUP_TEST_DOWNLOADS"
[ ! -e "$INTENT_SWIFTLINT_HOME" ]
rm "$SETUP_TEST_DOWNLOADS" "$TEMP_ROOT/bin/swiftlint"

# A read-only check with neither PATH nor managed binary cannot download tools.
expect_failure 'swiftlint was not found on PATH' "$SCRIPT_DIR/setup-swiftlint.sh" --check
[ ! -e "$SETUP_TEST_DOWNLOADS" ]
expect_failure 'Checksum mismatch' "$SCRIPT_DIR/setup-swiftlint.sh"
grep -Fq '0.65.1/swiftlint_linux_amd64.zip' "$SETUP_TEST_DOWNLOADS"
[ ! -e "$INTENT_SWIFTLINT_HOME" ]
echo 'SwiftLint setup tests passed'
