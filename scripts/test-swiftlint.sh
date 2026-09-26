#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly WRAPPER="$SCRIPT_DIR/swiftlint.sh"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/intent-swiftlint-test.XXXXXX")"
readonly SCRIPT_DIR REPO_ROOT TEMP_ROOT
trap 'rm -rf -- "$TEMP_ROOT"' EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

assert_contains() {
  local text=$1 expected=$2
  grep -Fq -- "$expected" <<< "$text" || fail "expected output to contain: $expected"
}

mkdir -p "$TEMP_ROOT/bin" "$TEMP_ROOT/log" "$TEMP_ROOT/outside"
export INTENT_SWIFTLINT_HOME="$TEMP_ROOT/install"
cat > "$TEMP_ROOT/bin/uname" <<'EOF'
#!/bin/bash
echo "${FAKE_UNAME:?}"
EOF
cat > "$TEMP_ROOT/bin/swiftlint" <<'EOF'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  version)
    printf '%s\n' "${FAKE_SWIFTLINT_VERSION:-0.65.1}"
    exit "${FAKE_SWIFTLINT_VERSION_STATUS:-0}"
    ;;
  lint)
    if [[ " $* " == *" --use-stdin "* ]]; then
      cat >/dev/null
      exit 0
    fi
    printf '%s\n' "$PWD" > "${FAKE_SWIFTLINT_LOG:?}/cwd"
    printf '%s\n' "$@" > "${FAKE_SWIFTLINT_LOG:?}/args"
    exit "${FAKE_SWIFTLINT_LINT_STATUS:-0}"
    ;;
  *) exit 99 ;;
esac
EOF
chmod +x "$TEMP_ROOT/bin/swiftlint"
chmod +x "$TEMP_ROOT/bin/uname"

for FAKE_UNAME in Darwin Linux; do
export FAKE_UNAME
if [ "$FAKE_UNAME" = Darwin ]; then
  # Darwin must not inspect Linux runtime overrides or invoke the probe.
  export LINUX_SOURCEKIT_LIB_PATH="$TEMP_ROOT/absent"
else
  unset LINUX_SOURCEKIT_LIB_PATH
fi

(
  cd "$TEMP_ROOT/outside"
  PATH="$TEMP_ROOT/bin:$PATH" FAKE_SWIFTLINT_LOG="$TEMP_ROOT/log" "$WRAPPER"
)
[ "$(cat "$TEMP_ROOT/log/cwd")" = "$REPO_ROOT" ] || fail "wrapper did not lint from the repository root"
cat > "$TEMP_ROOT/expected-args" <<EOF
lint
--config
$REPO_ROOT/.swiftlint.yml
--strict
--no-cache
EOF
cmp -s "$TEMP_ROOT/expected-args" "$TEMP_ROOT/log/args" || fail "wrapper passed unexpected lint arguments"

(
  cd "$TEMP_ROOT/outside"
  PATH="$TEMP_ROOT/bin:$PATH" FAKE_SWIFTLINT_LOG="$TEMP_ROOT/log" SWIFTLINT_REPORTER='' "$WRAPPER"
)
cmp -s "$TEMP_ROOT/expected-args" "$TEMP_ROOT/log/args" || fail "empty SWIFTLINT_REPORTER changed the lint arguments"

(
  cd "$TEMP_ROOT/outside"
  PATH="$TEMP_ROOT/bin:$PATH" FAKE_SWIFTLINT_LOG="$TEMP_ROOT/log" \
    SWIFTLINT_REPORTER=github-actions-logging "$WRAPPER"
)
cat > "$TEMP_ROOT/expected-args-reporter" <<EOF
lint
--config
$REPO_ROOT/.swiftlint.yml
--strict
--no-cache
--reporter
github-actions-logging
EOF
cmp -s "$TEMP_ROOT/expected-args-reporter" "$TEMP_ROOT/log/args" || fail "SWIFTLINT_REPORTER did not append --reporter to the lint arguments"

set +e
output=$(PATH="$TEMP_ROOT/bin:$PATH" FAKE_SWIFTLINT_VERSION=0.65.0 \
  FAKE_SWIFTLINT_LOG="$TEMP_ROOT/log" "$WRAPPER" 2>&1)
status=$?
set -e
[ "$status" -eq 1 ] || fail "version mismatch exited $status instead of 1"
assert_contains "$output" "SwiftLint 0.65.1 is required; found 0.65.0"

set +e
output=$(PATH="$TEMP_ROOT/bin:$PATH" FAKE_SWIFTLINT_LOG="$TEMP_ROOT/log" \
  "$WRAPPER" --fix 2>&1)
status=$?
set -e
[ "$status" -eq 1 ] || fail "argument rejection exited $status instead of 1"
assert_contains "$output" "takes no arguments"

set +e
PATH="$TEMP_ROOT/bin:$PATH" FAKE_SWIFTLINT_LINT_STATUS=23 \
  FAKE_SWIFTLINT_LOG="$TEMP_ROOT/log" "$WRAPPER" >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 23 ] || fail "lint failure exited $status instead of 23"

mkdir -p "$TEMP_ROOT/missing-bin"
ln -sf /usr/bin/dirname "$TEMP_ROOT/missing-bin/dirname"
ln -sf "$TEMP_ROOT/bin/uname" "$TEMP_ROOT/missing-bin/uname"
set +e
output=$(PATH="$TEMP_ROOT/missing-bin" /bin/bash "$WRAPPER" 2>&1)
status=$?
set -e
[ "$status" -eq 1 ] || fail "missing SwiftLint exited $status instead of 1"
assert_contains "$output" "swiftlint was not found on PATH"

echo "SwiftLint wrapper smoke tests passed ($FAKE_UNAME)"
done
