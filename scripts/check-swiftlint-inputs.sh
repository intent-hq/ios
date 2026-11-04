#!/usr/bin/env bash
# Fails when scripts/swiftlint-xcode-inputs.xcfilelist drifts from the Swift
# sources under Intent/, IntentTests/ and IntentUITests/ (excluding the same
# directories scripts/swiftlint-xcode.sh prunes). Sources are the working-tree
# files git tracks or would track (new files count before `git add`; ignored
# and deleted files do not), matching scripts/update-source-lists.sh, which
# fixes any drift. The Xcode lint phase only warns and skips diagnostics on
# drift, so this strict check runs in CI to keep the list complete.
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

[ "$#" -eq 0 ] || fail "usage: $0 (takes no arguments)"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
input_file_list="$script_dir/swiftlint-xcode-inputs.xcfilelist"

[ -f "$input_file_list" ] || fail "missing $input_file_list"

expected="$(mktemp "${TMPDIR:-/tmp}/swiftlint-inputs-expected.XXXXXX")"
trap 'rm -f -- "$expected"' EXIT

git -C "$repo_root" ls-files -z --cached --others --exclude-standard -- 'Intent/*.swift' 'IntentTests/*.swift' 'IntentUITests/*.swift' \
  ':(exclude)Intent/Resources' ':(exclude)Intent/Assets.xcassets' ':(exclude)IntentTests/Fixtures' |
  LC_ALL=C sort -zu |
  while IFS= read -r -d '' relative; do
    [ -f "$repo_root/$relative" ] || continue
    printf '$(SRCROOT)/%s\n' "$relative"
  done > "$expected"

[ -s "$expected" ] || fail "no Swift sources found under $repo_root"

if ! drift="$(diff -u "$input_file_list" "$expected")"; then
  printf '%s\n' "$drift" >&2
  fail "scripts/swiftlint-xcode-inputs.xcfilelist is out of date (lines with + are missing, - are stale); run scripts/update-source-lists.sh to regenerate it"
fi

echo "SwiftLint Xcode input list matches the Swift sources"
