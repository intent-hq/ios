#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CHECK="$SCRIPT_DIR/check-swiftlint-inputs.sh"
readonly TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/intent-check-swiftlint-inputs.XXXXXX")"
readonly FIXTURE="$TEMP_ROOT/repo"
readonly FIXTURE_CHECK="$FIXTURE/scripts/check-swiftlint-inputs.sh"
readonly FIXTURE_LIST="$FIXTURE/scripts/swiftlint-xcode-inputs.xcfilelist"
trap 'rm -rf -- "$TEMP_ROOT"' EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

assert_contains() {
  local text=$1 expected=$2
  grep -Fq -- "$expected" <<< "$text" || fail "expected output to contain: $expected"
}

assert_check_fails() {
  local description=$1 expected=$2
  set +e
  output=$("$FIXTURE_CHECK" 2>&1)
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail "$description exited $status instead of 1"
  assert_contains "$output" "$expected"
  assert_contains "$output" "is out of date"
  assert_contains "$output" "run scripts/update-source-lists.sh"
}

assert_check_passes() {
  local description=$1
  output=$("$FIXTURE_CHECK" 2>&1) || fail "$description exited $? instead of 0: $output"
  assert_contains "$output" "matches the Swift sources"
}

write_list() {
  printf '$(SRCROOT)/%s\n' "$@" > "$FIXTURE_LIST"
}

git_fixture() {
  git -C "$FIXTURE" -c user.name=test -c user.email=test@example.com "$@"
}

mkdir -p "$FIXTURE/scripts" "$FIXTURE/Intent/Nested Dir" "$FIXTURE/Intent/Resources" \
  "$FIXTURE/Intent/Assets.xcassets" "$FIXTURE/IntentTests/Fixtures" "$FIXTURE/IntentUITests" \
  "$FIXTURE/TailcatKit"
cp "$CHECK" "$FIXTURE_CHECK"
printf 'let app = 1\n' > "$FIXTURE/Intent/App.swift"
printf 'let nested = 2\n' > "$FIXTURE/Intent/Nested Dir/Nested.swift"
printf 'let tests = 3\n' > "$FIXTURE/IntentTests/AppTests.swift"
printf 'let ui = 4\n' > "$FIXTURE/IntentUITests/AppUITests.swift"
printf 'let resource = 5\n' > "$FIXTURE/Intent/Resources/Ignored.swift"
printf 'let asset = 6\n' > "$FIXTURE/Intent/Assets.xcassets/Ignored.swift"
printf 'let fixture = 7\n' > "$FIXTURE/IntentTests/Fixtures/Ignored.swift"
printf 'let outside = 8\n' > "$FIXTURE/TailcatKit/Outside.swift"
printf 'not swift\n' > "$FIXTURE/Intent/Notes.md"
printf 'Intent/Generated/\n' > "$FIXTURE/.gitignore"
mkdir -p "$FIXTURE/Intent/Generated"
printf 'let ignored = 10\n' > "$FIXTURE/Intent/Generated/Ignored.swift"
write_list \
  'Intent/App.swift' \
  'Intent/Nested Dir/Nested.swift' \
  'IntentTests/AppTests.swift' \
  'IntentUITests/AppUITests.swift'
git_fixture init -q
git_fixture add -A
git_fixture commit -q -m 'fixture'

assert_check_passes "complete list"

set +e
output=$("$FIXTURE_CHECK" --fix 2>&1)
status=$?
set -e
[ "$status" -eq 1 ] || fail "argument rejection exited $status instead of 1"
assert_contains "$output" "takes no arguments"

assert_check_passes "git-ignored source is skipped"

printf 'let added = 9\n' > "$FIXTURE/IntentUITests/AddedUITests.swift"
assert_check_fails "missing untracked source" '+$(SRCROOT)/IntentUITests/AddedUITests.swift'
git_fixture add IntentUITests/AddedUITests.swift
assert_check_fails "missing tracked source" '+$(SRCROOT)/IntentUITests/AddedUITests.swift'
write_list \
  'Intent/App.swift' \
  'Intent/Nested Dir/Nested.swift' \
  'IntentTests/AppTests.swift' \
  'IntentUITests/AddedUITests.swift' \
  'IntentUITests/AppUITests.swift'
assert_check_passes "list updated for the tracked source"

mv "$FIXTURE/IntentUITests/AddedUITests.swift" "$TEMP_ROOT/AddedUITests.swift"
assert_check_fails "stale entry for a deleted tracked source" '-$(SRCROOT)/IntentUITests/AddedUITests.swift'
mv "$TEMP_ROOT/AddedUITests.swift" "$FIXTURE/IntentUITests/AddedUITests.swift"

write_list \
  'Intent/App.swift' \
  'IntentTests/AppTests.swift' \
  'Intent/Nested Dir/Nested.swift' \
  'IntentUITests/AddedUITests.swift' \
  'IntentUITests/AppUITests.swift'
assert_check_fails "unsorted list" "@@"

write_list \
  'Intent/App.swift' \
  'Intent/Nested Dir/Nested.swift' \
  'Intent/Resources/Ignored.swift' \
  'IntentTests/AppTests.swift' \
  'IntentUITests/AddedUITests.swift' \
  'IntentUITests/AppUITests.swift'
assert_check_fails "pruned directory entry" '-$(SRCROOT)/Intent/Resources/Ignored.swift'

: > "$FIXTURE_LIST"
assert_check_fails "empty list" '+$(SRCROOT)/Intent/App.swift'

rm "$FIXTURE_LIST"
set +e
output=$("$FIXTURE_CHECK" 2>&1)
status=$?
set -e
[ "$status" -eq 1 ] || fail "missing list exited $status instead of 1"
assert_contains "$output" "missing"

echo "SwiftLint input list check tests passed"
