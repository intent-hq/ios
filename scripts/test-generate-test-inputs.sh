#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly GENERATOR="$SCRIPT_DIR/generate-test-inputs.sh"
readonly INPUT_FILE_LIST="$SCRIPT_DIR/test-source-inputs.xcfilelist"
readonly FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/intent-test-inputs.XXXXXX")"
readonly SOURCE="$FIXTURE_ROOT/source"
readonly DESTINATION="$FIXTURE_ROOT/output/SourceInputs"
readonly SCRATCH="$FIXTURE_ROOT/scratch/TestSourceInputsScratch"
trap 'rm -rf -- "$FIXTURE_ROOT"' EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    fail "command unexpectedly succeeded: $*"
  fi
}

write_sandbox_profile() {
  local profile=$1
  shift
  {
    cat <<EOF
(version 1)
(allow default)
(deny file-read-data (subpath "$sandbox_source"))
(deny file-read-data (subpath "$sandbox_destination"))
(deny file-write*)
(allow file-write*
  (literal "$sandbox_destination")
  (subpath "$sandbox_destination")
  (literal "$sandbox_scratch")
  (subpath "$sandbox_scratch"))
(allow file-read-data
EOF
    while [ "$#" -gt 0 ]; do
      printf '  (literal "%s")\n' "$1"
      shift
    done
    printf ')\n'
  } > "$profile"
}

mkdir -p "$SOURCE/Intent/Nested" "$SOURCE/IntentTests" \
  "$FIXTURE_ROOT/output" "$FIXTURE_ROOT/scratch"
printf 'ios-plist\n' > "$SOURCE/Intent/Info.plist"
printf 'vision-plist\n' > "$SOURCE/Info-visionOS.plist"
printf 'let first = 1\n' > "$SOURCE/Intent/First.swift"
printf 'let nested = 2\n' > "$SOURCE/Intent/Nested/Second.swift"
printf 'let tests = 3\n' > "$SOURCE/IntentTests/FirstTests.swift"
printf 'must-not-copy\n' > "$SOURCE/Intent/credentials.txt"

[ -f "$INPUT_FILE_LIST" ] || fail "missing test source input file list"
expected_input_file_list="$FIXTURE_ROOT/expected-input-file-list"
# shellcheck source=scripts/source-lists.sh
source "$SCRIPT_DIR/source-lists.sh"
list_test_sources "$REPO_ROOT" > "$expected_input_file_list"
cmp -s "$expected_input_file_list" "$INPUT_FILE_LIST" ||
  fail "scripts/test-source-inputs.xcfilelist is stale; run scripts/update-source-lists.sh to regenerate it"

"$GENERATOR" "$SOURCE" "$DESTINATION" "$SCRATCH"
cat > "$FIXTURE_ROOT/expected-manifest" <<'EOF'
Info-visionOS.plist
Intent/First.swift
Intent/Info.plist
Intent/Nested/Second.swift
IntentTests/FirstTests.swift
EOF
cmp -s "$FIXTURE_ROOT/expected-manifest" "$DESTINATION/manifest.txt" ||
  fail "fresh manifest is not complete and sorted"
while IFS= read -r relative; do
  cmp -s "$SOURCE/$relative" "$DESTINATION/$relative" ||
    fail "path or bytes were not preserved for $relative"
done < "$FIXTURE_ROOT/expected-manifest"
[ ! -e "$DESTINATION/Intent/credentials.txt" ] || fail "non-allowlisted file was copied"
[ -d "$SCRATCH" ] || fail "declared scratch output was not preserved"
[ -z "$(find "$SCRATCH" -mindepth 1 -print -quit)" ] ||
  fail "successful generation left scratch contents"

if [ -x /usr/bin/sandbox-exec ]; then
  sandbox_root="$FIXTURE_ROOT/sandbox-boundary"
  mkdir -p "$sandbox_root/output" "$sandbox_root/scratch"
  sandbox_root=$(cd -- "$sandbox_root" && pwd -P)
  sandbox_source=$(cd -- "$SOURCE" && pwd -P)
  sandbox_destination="$sandbox_root/output/SourceInputs"
  sandbox_scratch="$sandbox_root/scratch/TestSourceInputsScratch"
  root_only_profile="$sandbox_root/root-only-profile.sb"
  sandbox_profile="$sandbox_root/profile.sb"
  declared_root_inputs=(
    "$sandbox_source"
    "$sandbox_source/Intent"
    "$sandbox_source/IntentTests"
    "$sandbox_source/Intent/Info.plist"
    "$sandbox_source/Info-visionOS.plist"
    "$sandbox_source/Intent/First.swift"
    "$sandbox_source/IntentTests/FirstTests.swift"
  )
  write_sandbox_profile "$root_only_profile" "${declared_root_inputs[@]}"
  assert_fails /usr/bin/sandbox-exec -f "$root_only_profile" \
    /bin/cat "$sandbox_source/Intent/Nested/Second.swift"
  assert_fails /usr/bin/sandbox-exec -f "$root_only_profile" \
    "$GENERATOR" "$SOURCE" "$sandbox_destination" "$sandbox_scratch"
  [ ! -e "$sandbox_destination" ] ||
    fail "root-only read contract unexpectedly published source inputs"

  declared_inputs=(
    "${declared_root_inputs[@]}"
    "$sandbox_source/Intent/Nested"
    "$sandbox_source/Intent/Nested/Second.swift"
  )
  write_sandbox_profile "$sandbox_profile" "${declared_inputs[@]}"
  assert_fails /usr/bin/sandbox-exec -f "$sandbox_profile" \
    /bin/mkdir "$sandbox_root/output/UndeclaredSibling"
  /usr/bin/sandbox-exec -f "$sandbox_profile" \
    "$GENERATOR" "$SOURCE" "$sandbox_destination" "$sandbox_scratch"
  cmp -s "$FIXTURE_ROOT/expected-manifest" "$sandbox_destination/manifest.txt" ||
    fail "sandbox-boundary generation did not publish the expected manifest"
  [ -d "$sandbox_scratch" ] || fail "sandbox-boundary scratch output is missing"
  [ -z "$(find "$sandbox_scratch" -mindepth 1 -print -quit)" ] ||
    fail "sandbox-boundary generation left scratch contents"

  cp -R "$sandbox_destination" "$sandbox_root/published-before-stale-input"
  printf 'let unlisted = 5\n' > "$SOURCE/IntentTests/UnlistedTests.swift"
  assert_fails /usr/bin/sandbox-exec -f "$sandbox_profile" \
    "$GENERATOR" "$SOURCE" "$sandbox_destination" "$sandbox_scratch"
  diff -r "$sandbox_root/published-before-stale-input" "$sandbox_destination" >/dev/null ||
    fail "stale read contract changed the previously published destination"
  declared_inputs+=("$sandbox_source/IntentTests/UnlistedTests.swift")
  write_sandbox_profile "$sandbox_profile" "${declared_inputs[@]}"
  /usr/bin/sandbox-exec -f "$sandbox_profile" \
    "$GENERATOR" "$SOURCE" "$sandbox_destination" "$sandbox_scratch"
  cmp -s "$SOURCE/IntentTests/UnlistedTests.swift" \
    "$sandbox_destination/IntentTests/UnlistedTests.swift" ||
    fail "refreshed read contract did not publish the newly declared source"
fi

printf 'let first = 10\n' > "$SOURCE/Intent/First.swift"
rm "$SOURCE/Intent/Nested/Second.swift"
printf 'let added = 4\n' > "$SOURCE/IntentTests/AddedTests.swift"
"$GENERATOR" "$SOURCE" "$DESTINATION" "$SCRATCH"
cmp -s "$SOURCE/Intent/First.swift" "$DESTINATION/Intent/First.swift" ||
  fail "changed source was not refreshed"
[ ! -e "$DESTINATION/Intent/Nested/Second.swift" ] || fail "removed source remains bundled"
cmp -s "$SOURCE/IntentTests/AddedTests.swift" "$DESTINATION/IntentTests/AddedTests.swift" ||
  fail "added source was not bundled"
cp -R "$DESTINATION" "$FIXTURE_ROOT/published-before-invalid"

mkdir -p "$SOURCE/SourceInputs"
printf 'preserve-me\n' > "$SOURCE/SourceInputs/sentinel"

destination_ancestor="$FIXTURE_ROOT/destination-ancestor/SourceInputs"
destination_ancestor_source="$destination_ancestor/source"
destination_ancestor_scratch="$FIXTURE_ROOT/destination-ancestor-scratch/TestSourceInputsScratch"
mkdir -p "$destination_ancestor_source/Intent" "$destination_ancestor_source/IntentTests" \
  "$FIXTURE_ROOT/destination-ancestor-scratch"
printf 'ios\n' > "$destination_ancestor_source/Intent/Info.plist"
printf 'vision\n' > "$destination_ancestor_source/Info-visionOS.plist"
printf 'let app = 1\n' > "$destination_ancestor_source/Intent/App.swift"
printf 'let test = 1\n' > "$destination_ancestor_source/IntentTests/AppTests.swift"
printf 'preserve-me\n' > "$destination_ancestor_source/sentinel"
assert_fails "$GENERATOR" "$destination_ancestor_source" \
  "$destination_ancestor" "$destination_ancestor_scratch"
[ -f "$destination_ancestor_source/sentinel" ] ||
  fail "destination ancestor removed source sentinel"

scratch_ancestor="$FIXTURE_ROOT/scratch-ancestor/TestSourceInputsScratch"
scratch_ancestor_source="$scratch_ancestor/source"
scratch_ancestor_destination="$FIXTURE_ROOT/scratch-ancestor-output/SourceInputs"
mkdir -p "$scratch_ancestor_source/Intent" "$scratch_ancestor_source/IntentTests" \
  "$FIXTURE_ROOT/scratch-ancestor-output"
printf 'ios\n' > "$scratch_ancestor_source/Intent/Info.plist"
printf 'vision\n' > "$scratch_ancestor_source/Info-visionOS.plist"
printf 'let app = 1\n' > "$scratch_ancestor_source/Intent/App.swift"
printf 'let test = 1\n' > "$scratch_ancestor_source/IntentTests/AppTests.swift"
printf 'preserve-me\n' > "$scratch_ancestor_source/sentinel"
assert_fails "$GENERATOR" "$scratch_ancestor_source" \
  "$scratch_ancestor_destination" "$scratch_ancestor"
[ -f "$scratch_ancestor_source/sentinel" ] ||
  fail "scratch ancestor removed source sentinel"

ln -s "$SOURCE" "$FIXTURE_ROOT/source-root-link"
assert_fails "$GENERATOR" "$FIXTURE_ROOT/source-root-link" "$DESTINATION" "$SCRATCH"
[ -f "$SOURCE/SourceInputs/sentinel" ] || fail "symlink source root removed source sentinel"
unlink "$FIXTURE_ROOT/source-root-link"
ln -s "$SOURCE" "$FIXTURE_ROOT/destination-parent-link"
assert_fails "$GENERATOR" "$SOURCE" \
  "$FIXTURE_ROOT/destination-parent-link/SourceInputs" "$SCRATCH"
[ -f "$SOURCE/SourceInputs/sentinel" ] || fail "symlink destination parent removed source sentinel"
unlink "$FIXTURE_ROOT/destination-parent-link"

assert_fails "$GENERATOR" "$SOURCE" "$DESTINATION" \
  "$SOURCE/SourceInputs/TestSourceInputsScratch"
[ -f "$SOURCE/SourceInputs/sentinel" ] || fail "contained scratch root removed source sentinel"
ln -s "$SOURCE" "$FIXTURE_ROOT/scratch-parent-link"
assert_fails "$GENERATOR" "$SOURCE" "$DESTINATION" \
  "$FIXTURE_ROOT/scratch-parent-link/TestSourceInputsScratch"
[ -f "$SOURCE/SourceInputs/sentinel" ] || fail "symlink scratch parent removed source sentinel"
unlink "$FIXTURE_ROOT/scratch-parent-link"
rm -rf -- "$SCRATCH"
ln -s "$SOURCE/SourceInputs" "$SCRATCH"
assert_fails "$GENERATOR" "$SOURCE" "$DESTINATION" "$SCRATCH"
[ -f "$SOURCE/SourceInputs/sentinel" ] || fail "symlink scratch root removed source sentinel"
unlink "$SCRATCH"

assert_fails "$GENERATOR" "$FIXTURE_ROOT/missing" "$DESTINATION" "$SCRATCH"
assert_fails "$GENERATOR" "$SOURCE" "$FIXTURE_ROOT/output/WrongName" "$SCRATCH"
assert_fails "$GENERATOR" "$SOURCE" "$FIXTURE_ROOT/missing-parent/SourceInputs" "$SCRATCH"
assert_fails "$GENERATOR" "$SOURCE" "$DESTINATION" \
  "$FIXTURE_ROOT/missing-scratch-parent/TestSourceInputsScratch"
assert_fails "$GENERATOR" "$SOURCE" "$DESTINATION" "$FIXTURE_ROOT/scratch/WrongName"
assert_fails "$GENERATOR" "$SOURCE" "$SOURCE/SourceInputs" "$SCRATCH"
assert_fails "$GENERATOR" "$SOURCE" "$FIXTURE_ROOT/output/./SourceInputs" "$SCRATCH"
assert_fails "$GENERATOR" "$SOURCE" "$DESTINATION" \
  "$FIXTURE_ROOT/scratch/./TestSourceInputsScratch"
[ -f "$SOURCE/SourceInputs/sentinel" ] || fail "contained destination removed source sentinel"
ln -s "$SOURCE/Intent" "$SOURCE/IntentTests/LinkedSources"
assert_fails "$GENERATOR" "$SOURCE" "$DESTINATION" "$SCRATCH"
unlink "$SOURCE/IntentTests/LinkedSources"
mv "$DESTINATION" "$FIXTURE_ROOT/real-destination"
ln -s "$FIXTURE_ROOT/real-destination" "$DESTINATION"
assert_fails "$GENERATOR" "$SOURCE" "$DESTINATION" "$SCRATCH"
unlink "$DESTINATION"
mv "$FIXTURE_ROOT/real-destination" "$DESTINATION"
mv "$SOURCE/Info-visionOS.plist" "$FIXTURE_ROOT/real-plist"
ln -s "$FIXTURE_ROOT/real-plist" "$SOURCE/Info-visionOS.plist"
assert_fails "$GENERATOR" "$SOURCE" "$DESTINATION" "$SCRATCH"
diff -r "$FIXTURE_ROOT/published-before-invalid" "$DESTINATION" >/dev/null ||
  fail "failed generation changed the previously published destination"

echo "Test input generator checks passed"