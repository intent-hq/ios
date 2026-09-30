#!/usr/bin/env bash
# Offline post-clone contracts; no Apple tools, Go installation, or network.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/intent post-clone test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
export TEST_TRACE="$TEST_ROOT/trace"
TEST_REAL_TEE=$(command -v tee)
export TEST_REAL_TEE
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/package/go/bin" "$TEST_ROOT/tmp" \
  "$TEST_ROOT/repository/ci_scripts" "$TEST_ROOT/repository/TailcatKit"
cp "$SCRIPT_DIR/../ci_scripts/ci_post_clone.sh" "$TEST_ROOT/repository/ci_scripts/"
printf 'module test\ngo 1.27.0\n' > "$TEST_ROOT/repository/TailcatKit/go.mod"
POST_CLONE="$TEST_ROOT/repository/ci_scripts/ci_post_clone.sh"

cat > "$TEST_ROOT/package/go/bin/go" <<'EOF'
#!/bin/bash
set -eu
echo "go $*" >> "$TEST_TRACE"
[ "$GOTOOLCHAIN" = local ] && [ "$GOROOT/bin/go" = "$0" ] || exit 91
case "$*" in
  'env GOVERSION') echo "${TEST_GO_VERSION:-go1.27.1}" ;;
  version) echo 'go version go1.27.1 darwin/arm64' ;;
  *) exit 92 ;;
esac
EOF
chmod +x "$TEST_ROOT/package/go/bin/go"
export TEST_ARCHIVE="$TEST_ROOT/go.tar.gz"
tar -czf "$TEST_ARCHIVE" -C "$TEST_ROOT/package" go
TEST_FIXTURE_SHA=$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$TEST_ARCHIVE")
export TEST_FIXTURE_SHA

for tool in bash dirname mktemp rm cat grep chmod mkdir env cp sed tar gzip python3; do
  ln -s "$(command -v "$tool")" "$TEST_ROOT/bin/$tool"
done
cat > "$TEST_ROOT/bin/uname" <<'EOF'
#!/bin/bash
if [ "$1" = -m ]; then echo "${TEST_HOST_ARCH:-arm64}"; else echo "${TEST_HOST_OS:-Darwin}"; fi
EOF
cat > "$TEST_ROOT/bin/curl" <<'EOF'
#!/bin/bash
set -eu
echo "curl $*" >> "$TEST_TRACE"
args=" $* "
for contract in '--fail' '--location' '--proto =https' '--proto-redir =https' \
  '--retry 3' '--retry-all-errors' '--retry-max-time 300' '--connect-timeout 15' '--max-time 120'; do
  [[ "$args" == *" $contract "* ]] || { echo "Missing curl contract: $contract" >&2; exit 93; }
done
case "${TEST_HOST_ARCH:-arm64}" in
  arm64) arch=arm64 ;;
  x86_64) arch=amd64 ;;
  *) exit 94 ;;
esac
[[ "$args" == *" https://go.dev/dl/go1.27.1.darwin-$arch.tar.gz "* ]] || exit 95
while [ "$1" != -o ]; do shift; done
cp "$TEST_ARCHIVE" "$2"
if [ "${TEST_CORRUPT_ARCHIVE:-0}" = 1 ]; then echo corrupt >> "$2"; fi
if [ "${TEST_DOWNLOAD_STATUS:-0}" -ne 0 ]; then echo 'download exhausted retries' >&2; fi
exit "${TEST_DOWNLOAD_STATUS:-0}"
EOF
cat > "$TEST_ROOT/bin/shasum" <<'EOF'
#!/bin/bash
set -eu
echo checksum >> "$TEST_TRACE"
read -r checksum archive
case "${TEST_HOST_ARCH:-arm64}" in
  arm64) expected=ee215d57e0ec269c60cc9ceca68e6bda321ba9ee5afe24f4b0988703c2d87d12 ;;
  x86_64) expected=8f8f52c6649542cf027bbc9b9c68d1ec042f9f34808a40413f0b8b3f66f3caa4 ;;
esac
[ "$checksum" = "$expected" ] || exit 96
[ "$*" = '-a 256 -c -' ] || exit 96
# Translate the official pin to the local fixture, then verify real bytes.
python3 - "$TEST_FIXTURE_SHA" "$archive" <<'PY'
import hashlib
import sys

with open(sys.argv[2], "rb") as archive:
    actual = hashlib.sha256(archive.read()).hexdigest()
sys.exit(0 if actual == sys.argv[1] else 1)
PY
EOF
cat > "$TEST_ROOT/bin/tee" <<'EOF'
#!/bin/bash
"$TEST_REAL_TEE" "$@" || exit $?
exit "${TEST_TEE_STATUS:-0}"
EOF
cat > "$TEST_ROOT/bin/go" <<'EOF'
#!/bin/bash
echo 'Unexpected ambient Go invocation' >&2
exit 97
EOF
cp "$TEST_ROOT/bin/go" "$TEST_ROOT/bin/brew"
cat > "$TEST_ROOT/repository/TailcatKit/build_xcframework.sh" <<'EOF'
#!/bin/bash
set -eu
[ "$(go env GOVERSION)" = go1.27.1 ] || exit 98
count=$(grep -c '^build$' "$TEST_TRACE" || true)
echo build >> "$TEST_TRACE"
echo 'framework stdout'
echo 'framework stderr' >&2
mode=${TEST_BUILD_MODE:-success}
if [ "$mode" = crash-always ] || { [ "$count" = 0 ] && [[ "$mode" == crash-* ]]; }; then
  echo 'fatal error: sweep increased allocation count' >&2
  echo 'cmd/compile/internal/gc.Main' >&2
  exit 23
fi
case "$mode" in
  error|crash-then-error) echo 'ordinary build error' >&2; exit 37 ;;
  runtime-crash) echo 'fatal error: sweep increased allocation count' >&2; exit 23 ;;
  compiler-error) echo 'cmd/compile/internal/gc.Main: unrelated failure' >&2; exit 23 ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/"{uname,curl,shasum,tee,go,brew} \
  "$TEST_ROOT/repository/TailcatKit/build_xcframework.sh"
export PATH="$TEST_ROOT/bin"
export TMPDIR="$TEST_ROOT/tmp"
unset CI_PRODUCT_PLATFORM TEST_HOST_OS TEST_HOST_ARCH TEST_GO_VERSION TEST_BUILD_MODE \
  TEST_DOWNLOAD_STATUS TEST_CORRUPT_ARCHIVE TEST_TEE_STATUS
cd "$TEST_ROOT/repository/ci_scripts"

fail() { echo "FAIL: $*" >&2; echo "$output" >&2; exit 1; }
run_case() {
  local expected=$1 actual
  shift
  : > "$TEST_TRACE"
  rm -rf "$TEST_ROOT/repository/TailcatKit/build"
  if output=$("$@" 2>&1); then actual=0; else actual=$?; fi
  [ "$actual" -eq "$expected" ] || fail "expected exit $expected, got $actual"
  if compgen -G "$TMPDIR/intent-xcode-cloud-go.*" >/dev/null; then
    fail 'temporary Go installation was not removed'
  fi
}
expect_count() {
  local count
  count=$(grep -c "^$1" "$TEST_TRACE" || true)
  [ "$count" -eq "$2" ] || fail "expected $2 calls to $1, got $count"
}
expect_output() { grep -Fq "$1" <<< "$output" || fail "missing output: $1"; }
expect_logs() {
  local count=0 log
  for log in "$TEST_ROOT/repository/TailcatKit/build/"post-clone.*/attempt-*.log; do
    [ -f "$log" ] || continue
    count=$((count + 1))
    grep -Fq 'framework stdout' "$log" || fail 'lost build stdout'
    grep -Fq 'framework stderr' "$log" || fail 'lost build stderr'
  done
  [ "$count" -eq "$1" ] || fail "expected $1 build logs, got $count"
}

for platform in visionOS xrOS visionos xros; do
  run_case 0 env CI_PRODUCT_PLATFORM="$platform" TEST_HOST_OS=Linux "$POST_CLONE"
  expect_output 'Skipping Go/TailcatKit'
  [ ! -s "$TEST_TRACE" ] || fail 'visionOS invoked bootstrap tools'
  expect_logs 0
done
run_case 1 env CI_PRODUCT_PLATFORM=macOS "$POST_CLONE"
expect_output 'unsupported CI_PRODUCT_PLATFORM'
expect_count curl 0
run_case 1 env CI_PRODUCT_PLATFORM=iOS TEST_HOST_OS=Linux "$POST_CLONE"
expect_output 'requires macOS/Xcode'
expect_count curl 0
run_case 1 env TEST_HOST_ARCH=unsupported "$POST_CLONE"
expect_output 'unsupported Go host architecture'
expect_count curl 0

for arch in arm64 x86_64; do
  run_case 0 env CI_PRODUCT_PLATFORM=iOS TEST_HOST_ARCH="$arch" \
    GOTOOLCHAIN=auto GOROOT=/wrong-go "$POST_CLONE"
  expect_count curl 1
  expect_count checksum 1
  expect_count build 1
  expect_logs 1
done
run_case 0 "$POST_CLONE"
expect_count build 1

run_case 7 env TEST_DOWNLOAD_STATUS=7 "$POST_CLONE"
expect_output 'download exhausted retries'
expect_count checksum 0
expect_count go 0
expect_count build 0
run_case 1 env TEST_CORRUPT_ARCHIVE=1 "$POST_CLONE"
expect_output 'checksum mismatch'
expect_count go 0
expect_count build 0
run_case 1 env TEST_GO_VERSION=go1.28.0 "$POST_CLONE"
expect_output 'expected go1.27.1, found go1.28.0'
expect_count build 0

run_case 37 env TEST_BUILD_MODE=error "$POST_CLONE"
expect_count build 1
expect_output 'ordinary build error'
expect_logs 1
for mode in runtime-crash compiler-error; do
  run_case 23 env TEST_BUILD_MODE="$mode" "$POST_CLONE"
  expect_count build 1
  expect_logs 1
done
run_case 0 env TEST_BUILD_MODE=crash-once "$POST_CLONE"
expect_count build 2
expect_output 'Go compiler sweep crash; retrying once'
expect_logs 2
grep -Fq 'fatal error: sweep increased allocation count' \
  "$TEST_ROOT/repository/TailcatKit/build/"post-clone.*/attempt-1.log || fail 'lost crash diagnostics'
run_case 23 env TEST_BUILD_MODE=crash-always "$POST_CLONE"
expect_count build 2
expect_logs 2
run_case 37 env TEST_BUILD_MODE=crash-then-error "$POST_CLONE"
expect_count build 2
expect_logs 2
run_case 74 env TEST_TEE_STATUS=74 "$POST_CLONE"
expect_count build 1
expect_output 'could not preserve TailcatKit build diagnostics'

echo 'Xcode Cloud post-clone tests passed'
