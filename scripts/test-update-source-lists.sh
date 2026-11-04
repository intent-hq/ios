#!/usr/bin/env bash
# Self-test for scripts/update-source-lists.sh against a fixture git repo.
# Also proves the regenerated SwiftLint list satisfies
# scripts/check-swiftlint-inputs.sh; the test-source list format is pinned to
# the stale-list check in scripts/test-generate-test-inputs.sh.
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/intent-update-source-lists.XXXXXX")"
readonly FIXTURE="$TEMP_ROOT/repo"
readonly UPDATE="$FIXTURE/scripts/update-source-lists.sh"
readonly CHECK="$FIXTURE/scripts/check-swiftlint-inputs.sh"
readonly TEST_LIST="$FIXTURE/scripts/test-source-inputs.xcfilelist"
readonly SWIFTLINT_LIST="$FIXTURE/scripts/swiftlint-xcode-inputs.xcfilelist"
trap 'rm -rf -- "$TEMP_ROOT"' EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

assert_contains() {
  local text=$1 expected=$2
  grep -Fq -- "$expected" <<< "$text" || fail "expected output to contain: $expected"
}

assert_list() {
  local description=$1 list=$2
  shift 2
  printf '$(SRCROOT)/%s\n' "$@" > "$TEMP_ROOT/expected"
  diff -u "$TEMP_ROOT/expected" "$list" >&2 || fail "$description"
}

# Recomputes the test-source list exactly as test-generate-test-inputs.sh does.
assert_test_list_matches_generator_check() {
  find "$FIXTURE/Intent" "$FIXTURE/IntentTests" \
    \( -type d -o -type f -name '*.swift' \) -print | LC_ALL=C sort |
    while IFS= read -r path; do
      printf '$(SRCROOT)/%s\n' "${path#"$FIXTURE/"}"
    done > "$TEMP_ROOT/generator-expected"
  cmp -s "$TEMP_ROOT/generator-expected" "$TEST_LIST" ||
    fail "test-source list does not match the test-generate-test-inputs.sh check"
}

assert_check_passes() {
  output=$("$CHECK" 2>&1) || fail "$1: check-swiftlint-inputs.sh failed: $output"
}

run_update() {
  output=$("$UPDATE" 2>&1) || fail "update-source-lists.sh failed: $output"
}

git_fixture() {
  git -C "$FIXTURE" -c user.name=test -c user.email=test@example.com "$@"
}

mkdir -p "$FIXTURE/scripts" "$FIXTURE/Intent/Nested Dir" "$FIXTURE/Intent/Resources" \
  "$FIXTURE/Intent/Assets.xcassets" "$FIXTURE/Intent/Generated" "$FIXTURE/IntentTests/Fixtures" \
  "$FIXTURE/IntentUITests" "$FIXTURE/TailcatKit"
cp "$SCRIPT_DIR/update-source-lists.sh" "$UPDATE"
cp "$SCRIPT_DIR/check-swiftlint-inputs.sh" "$CHECK"
printf 'Intent/Generated/\n' > "$FIXTURE/.gitignore"
printf 'let app = 1\n' > "$FIXTURE/Intent/App.swift"
printf 'let nested = 2\n' > "$FIXTURE/Intent/Nested Dir/Nested.swift"
printf 'let tests = 3\n' > "$FIXTURE/IntentTests/AppTests.swift"
printf 'let ui = 4\n' > "$FIXTURE/IntentUITests/AppUITests.swift"
printf 'let resource = 5\n' > "$FIXTURE/Intent/Resources/Resource.swift"
printf 'let asset = 6\n' > "$FIXTURE/Intent/Assets.xcassets/Asset.swift"
printf 'let fixture = 7\n' > "$FIXTURE/IntentTests/Fixtures/Fixture.swift"
printf 'let generated = 8\n' > "$FIXTURE/Intent/Generated/Generated.swift"
printf 'let outside = 9\n' > "$FIXTURE/TailcatKit/Outside.swift"
printf 'not swift\n' > "$FIXTURE/Intent/Notes.md"
git_fixture init -q
git_fixture add -A
git_fixture commit -q -m 'fixture'

set +e
output=$("$UPDATE" --check 2>&1)
status=$?
set -e
[ "$status" -eq 1 ] || fail "argument rejection exited $status instead of 1"
assert_contains "$output" "takes no arguments"
if [ -e "$TEST_LIST" ] || [ -e "$SWIFTLINT_LIST" ]; then
  fail "rejected run wrote a list"
fi

run_update
assert_contains "$output" "updated scripts/test-source-inputs.xcfilelist"
assert_contains "$output" "updated scripts/swiftlint-xcode-inputs.xcfilelist"
# The test-source list keeps every directory (it declares sandbox reads) and
# every Swift file under Intent/ and IntentTests/, ignored or pruned or not.
assert_list "initial test-source list" "$TEST_LIST" \
  'Intent' \
  'Intent/App.swift' \
  'Intent/Assets.xcassets' \
  'Intent/Assets.xcassets/Asset.swift' \
  'Intent/Generated' \
  'Intent/Generated/Generated.swift' \
  'Intent/Nested Dir' \
  'Intent/Nested Dir/Nested.swift' \
  'Intent/Resources' \
  'Intent/Resources/Resource.swift' \
  'IntentTests' \
  'IntentTests/AppTests.swift' \
  'IntentTests/Fixtures' \
  'IntentTests/Fixtures/Fixture.swift'
assert_list "initial SwiftLint list" "$SWIFTLINT_LIST" \
  'Intent/App.swift' \
  'Intent/Nested Dir/Nested.swift' \
  'IntentTests/AppTests.swift' \
  'IntentUITests/AppUITests.swift'
assert_test_list_matches_generator_check
assert_check_passes "initial lists"

run_update
assert_contains "$output" "scripts/test-source-inputs.xcfilelist is up to date"
assert_contains "$output" "scripts/swiftlint-xcode-inputs.xcfilelist is up to date"

# A file split out of an existing source, not yet staged (the ios#939 case).
mkdir -p "$FIXTURE/Intent/Split"
printf 'let split = 10\n' > "$FIXTURE/Intent/Split/App+Split.swift"
printf 'let splitTests = 11\n' > "$FIXTURE/IntentTests/AppSplitTests.swift"
printf 'let splitUI = 12\n' > "$FIXTURE/IntentUITests/AppSplitUITests.swift"
set +e
"$CHECK" >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 1 ] || fail "check did not flag the unlisted split files"
run_update
assert_contains "$output" "updated scripts/test-source-inputs.xcfilelist"
assert_contains "$output" "updated scripts/swiftlint-xcode-inputs.xcfilelist"
assert_list "SwiftLint list after split" "$SWIFTLINT_LIST" \
  'Intent/App.swift' \
  'Intent/Nested Dir/Nested.swift' \
  'Intent/Split/App+Split.swift' \
  'IntentTests/AppSplitTests.swift' \
  'IntentTests/AppTests.swift' \
  'IntentUITests/AppSplitUITests.swift' \
  'IntentUITests/AppUITests.swift'
grep -Fqx '$(SRCROOT)/Intent/Split' "$TEST_LIST" || fail "new directory missing from test-source list"
grep -Fqx '$(SRCROOT)/Intent/Split/App+Split.swift' "$TEST_LIST" ||
  fail "new source missing from test-source list"
assert_test_list_matches_generator_check
assert_check_passes "unstaged split files"
git_fixture add -A
assert_check_passes "staged split files"

# Deleting a tracked file from disk drops it before `git rm`.
rm "$FIXTURE/IntentTests/AppSplitTests.swift"
run_update
if grep -Fq 'AppSplitTests.swift' "$TEST_LIST" "$SWIFTLINT_LIST"; then
  fail "deleted source is still listed"
fi
assert_test_list_matches_generator_check
assert_check_passes "deleted tracked source"

echo "update-source-lists.sh tests passed"
