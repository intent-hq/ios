#!/usr/bin/env bash
# Fails when scripts/swiftlint-xcode-inputs.xcfilelist drifts from the tracked
# Swift sources under Intent/, IntentTests/ and IntentUITests/. The Xcode lint
# phase (scripts/swiftlint-xcode.sh) only warns and skips diagnostics on
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

git -C "$repo_root" ls-files -z -- 'Intent/*.swift' 'IntentTests/*.swift' 'IntentUITests/*.swift' |
  LC_ALL=C sort -z |
  while IFS= read -r -d '' relative; do
    printf '$(SRCROOT)/%s\n' "$relative"
  done > "$expected"

[ -s "$expected" ] || fail "no tracked Swift sources found under $repo_root"

if ! drift="$(diff -u "$input_file_list" "$expected")"; then
  printf '%s\n' "$drift" >&2
  fail "scripts/swiftlint-xcode-inputs.xcfilelist is out of date (lines with + are missing, - are stale); list every tracked Swift source under Intent/, IntentTests/ and IntentUITests/ sorted with LC_ALL=C"
fi

echo "SwiftLint Xcode input list matches tracked Swift sources"
