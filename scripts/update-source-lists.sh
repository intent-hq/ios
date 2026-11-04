#!/usr/bin/env bash
# Regenerates both hand-maintained Xcode input lists. Run it after adding,
# removing, splitting or moving a Swift file under Intent/, IntentTests/ or
# IntentUITests/:
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
# Both lists hold the files git sees (tracked, or new and not ignored, and
# present on disk), sorted with LC_ALL=C; see scripts/source-lists.sh. Paths
# that exist only locally (empty or git-ignored directories, ignored Swift files)
# stay out and are reported as warnings, because the Xcode phases still see
# them on disk.
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
# shellcheck source=scripts/source-lists.sh
source "$script_dir/source-lists.sh"

for directory in Intent IntentTests IntentUITests; do
  [ -d "$repo_root/$directory" ] || fail "missing $directory/ under $repo_root"
done

test_tmp="$(mktemp "$script_dir/.test-source-inputs.XXXXXX")"
swiftlint_tmp="$(mktemp "$script_dir/.swiftlint-xcode-inputs.XXXXXX")"
trap 'rm -f -- "$test_tmp" "$swiftlint_tmp"' EXIT

list_test_sources "$repo_root" > "$test_tmp"
list_swiftlint_sources "$repo_root" > "$swiftlint_tmp"
[ -s "$swiftlint_tmp" ] || fail "no Swift sources found under $repo_root"

warn_local_only() {
  local generated=$1 on_disk=$2 consequence=$3 path
  LC_ALL=C comm -13 "$generated" <($on_disk "$repo_root") |
    while IFS= read -r path; do
      echo "warning: ${path#'$(SRCROOT)/'} exists only locally (empty or git-ignored); $consequence" >&2
    done
}

warn_local_only "$test_tmp" list_test_sources_on_disk \
  "left out of test-source-inputs.xcfilelist, so local test builds may hit a sandbox deny; delete it or add files git tracks"
warn_local_only "$swiftlint_tmp" list_swiftlint_sources_on_disk \
  "left out of swiftlint-xcode-inputs.xcfilelist, so the Xcode lint phase will skip diagnostics; delete it or stop ignoring it"

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
