#!/usr/bin/env bash
# Builds tiny Mach-O fixtures that do and do not link the legacy Swift WebKit
# overlay install name and checks scripts/check-webkit-overlay-linkage.sh
# accepts and rejects them. macOS only (needs clang, otool and dyld_info).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CHECK="$SCRIPT_DIR/check-webkit-overlay-linkage.sh"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/intent-check-webkit-overlay.XXXXXX")"
readonly TEMP_ROOT
trap 'rm -rf -- "$TEMP_ROOT"' EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

assert_contains() {
  local text=$1 expected=$2
  grep -Fq -- "$expected" <<< "$text" || fail "expected output to contain: $expected"
}

run_check() {
  set +e
  output=$("$@" 2>&1)
  status=$?
  set -e
}

# A stand-in for the overlay with its real install name and one exported symbol.
echo 'void overlay_symbol(void) {}' > "$TEMP_ROOT/overlay.c"
clang -dynamiclib -o "$TEMP_ROOT/libswiftWebKit.dylib" \
  -install_name /usr/lib/swift/libswiftWebKit.dylib "$TEMP_ROOT/overlay.c"
echo 'void overlay_symbol(void); int main(void) { overlay_symbol(); return 0; }' > "$TEMP_ROOT/uses.c"
echo 'int main(void) { return 0; }' > "$TEMP_ROOT/clean.c"

make_app() {
  local app=$1 source=$2 binary=$3
  shift 3
  mkdir -p "$app"
  clang -o "$app/$binary" "$TEMP_ROOT/$source" "$@"
}

make_app "$TEMP_ROOT/Clean/Intent.app" clean.c Intent
make_app "$TEMP_ROOT/Clean/Intent.app" clean.c Intent.debug.dylib -dynamiclib
make_app "$TEMP_ROOT/Release/Intent.app" uses.c Intent "$TEMP_ROOT/libswiftWebKit.dylib"
make_app "$TEMP_ROOT/Debug/Intent.app" clean.c Intent
make_app "$TEMP_ROOT/Debug/Intent.app" uses.c Intent.debug.dylib -dynamiclib "$TEMP_ROOT/libswiftWebKit.dylib"

run_check "$CHECK" "$TEMP_ROOT/Clean/Intent.app"
[ "$status" -eq 0 ] || fail "clean app exited $status: $output"
assert_contains "$output" "ok: $TEMP_ROOT/Clean/Intent.app/Intent.debug.dylib does not load"

run_check "$CHECK" "$TEMP_ROOT/Release/Intent.app"
[ "$status" -eq 1 ] || fail "Release app linking the overlay exited $status"
assert_contains "$output" "error: $TEMP_ROOT/Release/Intent.app/Intent loads /usr/lib/swift/libswiftWebKit.dylib"
assert_contains "$output" "_overlay_symbol"

run_check "$CHECK" "$TEMP_ROOT/Clean/Intent.app" "$TEMP_ROOT/Debug/Intent.app"
[ "$status" -eq 1 ] || fail "Debug dylib linking the overlay exited $status"
assert_contains "$output" "error: $TEMP_ROOT/Debug/Intent.app/Intent.debug.dylib loads"
assert_contains "$output" "ok: $TEMP_ROOT/Debug/Intent.app/Intent does not load"

# Weak linking still records the overlay path, so it is rejected too.
make_app "$TEMP_ROOT/Weak/Intent.app" uses.c Intent -Wl,-weak_library,"$TEMP_ROOT/libswiftWebKit.dylib"
run_check "$CHECK" "$TEMP_ROOT/Weak/Intent.app"
[ "$status" -eq 1 ] || fail "weakly linked app exited $status"

mkdir -p "$TEMP_ROOT/DD/Build/Products/Debug-iphonesimulator"
cp -R "$TEMP_ROOT/Debug/Intent.app" "$TEMP_ROOT/DD/Build/Products/Debug-iphonesimulator/"
run_check env DERIVED_DATA_DIR="$TEMP_ROOT/DD" "$CHECK"
[ "$status" -eq 1 ] || fail "DERIVED_DATA_DIR discovery exited $status"
assert_contains "$output" "Debug-iphonesimulator/Intent.app/Intent.debug.dylib loads"

run_check env -u DERIVED_DATA_DIR "$CHECK"
[ "$status" -eq 1 ] || fail "missing arguments exited $status"
assert_contains "$output" "pass Intent.app paths or set DERIVED_DATA_DIR"

mkdir -p "$TEMP_ROOT/Empty/Intent.app"
run_check "$CHECK" "$TEMP_ROOT/Empty/Intent.app"
[ "$status" -eq 1 ] || fail "app without a binary exited $status"
assert_contains "$output" "no Intent binary in"

echo "check-webkit-overlay-linkage tests passed"
