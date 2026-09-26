#!/usr/bin/env bash
# Setup boundaries: offline checks/reuse, unsupported hosts, verified downloads.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/intent-swiftlint-setup-test.XXXXXX")
trap 'rm -rf -- "$TEMP_ROOT"' EXIT
mkdir -p "$TEMP_ROOT/bin"
for tool in bash dirname python3 sha256sum gpg tar mktemp rm cat grep chmod mkdir env ln; do
  ln -s "$(command -v "$tool")" "$TEMP_ROOT/bin/$tool"
done
cat > "$TEMP_ROOT/bin/uname" <<'EOF'
#!/bin/bash
if [ "$1" = -m ]; then echo "${SETUP_TEST_ARCH:-x86_64}"; else echo Linux; fi
EOF
cat > "$TEMP_ROOT/bin/swiftlint" <<'EOF'
#!/bin/bash
if [ "$1" = version ]; then echo "${SETUP_TEST_VERSION:-0.65.1}"; else
  cat >/dev/null
  exit "${SETUP_TEST_PROBE_STATUS:-0}"
fi
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
chmod +x "$TEMP_ROOT/bin/uname" "$TEMP_ROOT/bin/swiftlint" "$TEMP_ROOT/bin/curl"
export PATH="$TEMP_ROOT/bin"
export INTENT_SWIFTLINT_HOME="$TEMP_ROOT/install"
export SETUP_TEST_DOWNLOADS="$TEMP_ROOT/downloads"
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
