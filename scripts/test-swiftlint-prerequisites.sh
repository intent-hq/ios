#!/usr/bin/env bash
# Isolated prerequisite regressions: no installed Swift or network required.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/intent-swiftlint-prerequisites.XXXXXX")"
trap 'rm -rf -- "$TEMP_ROOT"' EXIT
mkdir -p "$TEMP_ROOT/bin" "$TEMP_ROOT/runtime"
printf 'not a shared library\n' > "$TEMP_ROOT/runtime/libsourcekitdInProc.so"
cat > "$TEMP_ROOT/bin/uname" <<'EOF'
#!/bin/bash
echo Linux
EOF
cat > "$TEMP_ROOT/bin/swiftlint" <<'EOF'
#!/bin/bash
case "$1" in
  version) echo 0.65.1 ;;
  lint)
    if [[ " $* " == *" --use-stdin "* ]]; then
      cat >/dev/null
      echo 'Loading libsourcekitdInProc.so failed' >&2
      kill -ILL $$
    fi
    echo 'repository lint started' >> "$LINT_TEST_LOG"
    ;;
esac
EOF
chmod +x "$TEMP_ROOT/bin/"*
export PATH="$TEMP_ROOT/bin:$PATH"
export INTENT_SWIFTLINT_HOME="$TEMP_ROOT/install"
export LINT_TEST_LOG="$TEMP_ROOT/lint.log"
unset LINUX_SOURCEKIT_LIB_PATH
ulimit -c 0

check_failure() {
  local name=$1 expected=$2 output status
  set +e
  output=$("$SCRIPT_DIR/swiftlint.sh" 2>&1)
  status=$?
  set -e
  if [ "$status" -ne 1 ] || ! grep -Fq "$expected" <<< "$output" ||
    ! grep -Fq 'scripts/setup-swiftlint.sh' <<< "$output" || [ -f "$LINT_TEST_LOG" ]; then
    echo "FAIL: $name: expected actionable exit 1 before repository lint; got $status" >&2
    echo "$output" >&2
    return 1
  fi
  echo "PASS: $name"
}

failures=0
check_failure 'missing SourceKit' 'SourceKit' || failures=$((failures + 1))
rm -f "$LINT_TEST_LOG"
export LINUX_SOURCEKIT_LIB_PATH="$TEMP_ROOT/absent"
check_failure 'invalid explicit runtime path' 'LINUX_SOURCEKIT_LIB_PATH' || failures=$((failures + 1))
rm -f "$LINT_TEST_LOG"
export LINUX_SOURCEKIT_LIB_PATH="$TEMP_ROOT/runtime"
check_failure 'unloadable SourceKit' 'SourceKit' || failures=$((failures + 1))
[ "$failures" -eq 0 ]
