#!/usr/bin/env bash
# Self-test for scripts/update-source-lists.sh against a fixture git repo.
# Also proves the regenerated lists satisfy scripts/check-swiftlint-inputs.sh
# and the shared enumeration the stale-list check in
# scripts/test-generate-test-inputs.sh uses (scripts/source-lists.sh).
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

# The stale-list check in test-generate-test-inputs.sh compares against this.
assert_test_list_matches_generator_check() {
  (
    set -euo pipefail
    # shellcheck source=scripts/source-lists.sh
    source "$FIXTURE/scripts/source-lists.sh"
    list_test_sources "$FIXTURE"
  ) > "$TEMP_ROOT/generator-expected"
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
cp "$SCRIPT_DIR/source-lists.sh" "$FIXTURE/scripts/source-lists.sh"
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

set +e
output=$("$UPDATE" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail "update outside a git checkout succeeded"
assert_contains "$output" "is not a git checkout"
if [ -e "$TEST_LIST" ] || [ -e "$SWIFTLINT_LIST" ]; then
  fail "update outside a git checkout wrote a list"
fi
if find "$FIXTURE/scripts" -name '.*.??????' -print | grep -q .; then
  fail "update outside a git checkout left temp files"
fi

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
# The test-source list declares sandbox reads: every directory holding a file
# git sees plus every such Swift file under Intent/ and IntentTests/, pruned
# by SwiftLint or not. The ignored Intent/Generated/ stays out (with a warning).
assert_contains "$output" "warning: Intent/Generated exists only locally"
assert_contains "$output" "warning: Intent/Generated/Generated.swift exists only locally"
assert_contains "$output" "Xcode lint phase will skip diagnostics"
assert_list "initial test-source list" "$TEST_LIST" \
  'Intent' \
  'Intent/App.swift' \
  'Intent/Assets.xcassets' \
  'Intent/Assets.xcassets/Asset.swift' \
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

# Local-only leftovers (an emptied directory, an ignored build directory) are
# what a fresh clone lacks, so they must never reach the committed lists.
cp "$TEST_LIST" "$TEMP_ROOT/test-list-before"
cp "$SWIFTLINT_LIST" "$TEMP_ROOT/swiftlint-list-before"
mkdir -p "$FIXTURE/Intent/Emptied" "$FIXTURE/IntentTests/build"
printf 'build/\n' >> "$FIXTURE/.gitignore"
git_fixture add .gitignore
printf 'let built = 13\n' > "$FIXTURE/IntentTests/build/Built.swift"
run_update
assert_contains "$output" "warning: Intent/Emptied exists only locally"
assert_contains "$output" "warning: IntentTests/build/Built.swift exists only locally"
assert_contains "$output" "local test builds may hit a sandbox deny"
cmp -s "$TEMP_ROOT/test-list-before" "$TEST_LIST" ||
  fail "local-only paths changed the test-source list"
cmp -s "$TEMP_ROOT/swiftlint-list-before" "$SWIFTLINT_LIST" ||
  fail "local-only paths changed the SwiftLint list"
assert_test_list_matches_generator_check
assert_check_passes "local-only leftovers"

# A fresh clone of the result passes both checks.
git_fixture add -A
git_fixture commit -q -m 'regenerated'
git clone -q "$FIXTURE" "$TEMP_ROOT/clone"
[ ! -e "$TEMP_ROOT/clone/Intent/Emptied" ] || fail "clone unexpectedly has the emptied directory"
(
  set -euo pipefail
  # shellcheck source=scripts/source-lists.sh
  source "$TEMP_ROOT/clone/scripts/source-lists.sh"
  list_test_sources "$TEMP_ROOT/clone"
) | cmp -s - "$TEMP_ROOT/clone/scripts/test-source-inputs.xcfilelist" ||
  fail "fresh clone fails the test-source stale check"
"$TEMP_ROOT/clone/scripts/check-swiftlint-inputs.sh" >/dev/null 2>&1 ||
  fail "fresh clone fails check-swiftlint-inputs.sh"

echo "update-source-lists.sh tests passed"
