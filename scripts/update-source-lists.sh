#!/usr/bin/env bash
# Regenerates both hand-maintained Xcode input lists from the Swift sources in
# the working tree. Run it after adding, removing, splitting or moving a Swift
# file under Intent/, IntentTests/ or IntentUITests/:
#
#   scripts/test-source-inputs.xcfilelist
#     Directories plus Swift files under Intent/ and IntentTests/; the
#     sandboxed Copy Test Source Inputs phase may only read paths it declares.
#     Checked by scripts/test-generate-test-inputs.sh.
#   scripts/swiftlint-xcode-inputs.xcfilelist
#     Swift files under Intent/, IntentTests/ and IntentUITests/, minus the
#     directories scripts/swiftlint-xcode.sh prunes. Checked by
#     scripts/check-swiftlint-inputs.sh.
#
# Both lists are sorted with LC_ALL=C. New files count before `git add`;
# git-ignored files and deleted-but-still-tracked files do not.
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

[ "$#" -eq 0 ] || fail "usage: $0 (takes no arguments)"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
test_list="$script_dir/test-source-inputs.xcfilelist"
swiftlint_list="$script_dir/swiftlint-xcode-inputs.xcfilelist"

for directory in Intent IntentTests IntentUITests; do
  [ -d "$repo_root/$directory" ] || fail "missing $directory/ under $repo_root"
done

test_tmp="$(mktemp "$script_dir/.test-source-inputs.XXXXXX")"
swiftlint_tmp="$(mktemp "$script_dir/.swiftlint-xcode-inputs.XXXXXX")"
trap 'rm -f -- "$test_tmp" "$swiftlint_tmp"' EXIT

# Mirrors the stale-list check in scripts/test-generate-test-inputs.sh.
(
  cd -- "$repo_root"
  find Intent IntentTests \( -type d -o -type f -name '*.swift' \) -print |
    LC_ALL=C sort |
    while IFS= read -r relative; do
      printf '$(SRCROOT)/%s\n' "$relative"
    done
) > "$test_tmp"

# Mirrors scripts/check-swiftlint-inputs.sh.
git -C "$repo_root" ls-files -z --cached --others --exclude-standard -- \
  'Intent/*.swift' 'IntentTests/*.swift' 'IntentUITests/*.swift' \
  ':(exclude)Intent/Resources' ':(exclude)Intent/Assets.xcassets' ':(exclude)IntentTests/Fixtures' |
  LC_ALL=C sort -zu |
  while IFS= read -r -d '' relative; do
    [ -f "$repo_root/$relative" ] || continue
    printf '$(SRCROOT)/%s\n' "$relative"
  done > "$swiftlint_tmp"

[ -s "$swiftlint_tmp" ] || fail "no Swift sources found under $repo_root"

publish() {
  local generated=$1 destination=$2 name=${2#"$repo_root/"}
  if [ -f "$destination" ] && cmp -s "$generated" "$destination"; then
    echo "$name is up to date"
    return
  fi
  chmod 644 "$generated"
  mv -- "$generated" "$destination"
  echo "updated $name"
}

publish "$test_tmp" "$test_list"
publish "$swiftlint_tmp" "$swiftlint_list"
