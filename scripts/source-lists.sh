# shellcheck shell=bash
# Shared enumeration for the two committed Xcode input lists. Sourced by
# scripts/update-source-lists.sh (writes them), scripts/check-swiftlint-inputs.sh
# and the stale-list check in scripts/test-generate-test-inputs.sh (verify
# them), so the writer and the checks cannot disagree.
#
# Sources are the files git can see: tracked or untracked-but-not-ignored, and
# still present on disk. That is exactly what a fresh clone contains, so a
# local-only leftover (an empty directory, an ignored build product) never
# lands in a committed list. Callers must enable `set -o pipefail`.

# Prints NUL-separated repo-relative paths of git-visible files under the
# given pathspecs.
source_lists_git_files() {
  local repo_root=$1
  shift
  if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: $repo_root is not a git checkout; the Xcode input lists are built from the files git sees" >&2
    return 1
  fi
  git -C "$repo_root" ls-files -z --cached --others --exclude-standard -- "$@" |
    while IFS= read -r -d '' relative; do
      [ -f "$repo_root/$relative" ] || continue
      printf '%s\0' "$relative"
    done
}

# scripts/test-source-inputs.xcfilelist: every directory holding a file plus
# every Swift file under Intent/ and IntentTests/ (the sandboxed Copy Test
# Source Inputs phase may only read declared paths).
list_test_sources() {
  local repo_root=$1
  {
    printf '%s\0' Intent IntentTests
    source_lists_git_files "$repo_root" Intent IntentTests |
      while IFS= read -r -d '' relative; do
        local directory=$relative
        while [ "${directory%/*}" != "$directory" ]; do
          directory=${directory%/*}
          printf '%s\0' "$directory"
        done
        case "$relative" in
          *.swift) printf '%s\0' "$relative" ;;
        esac
      done
  } | LC_ALL=C sort -zu |
    while IFS= read -r -d '' relative; do
      printf '$(SRCROOT)/%s\n' "$relative"
    done
}

# scripts/swiftlint-xcode-inputs.xcfilelist: Swift files under Intent/,
# IntentTests/ and IntentUITests/ minus the directories
# scripts/swiftlint-xcode.sh prunes.
list_swiftlint_sources() {
  local repo_root=$1
  source_lists_git_files "$repo_root" \
    'Intent/*.swift' 'IntentTests/*.swift' 'IntentUITests/*.swift' \
    ':(exclude)Intent/Resources' ':(exclude)Intent/Assets.xcassets' ':(exclude)IntentTests/Fixtures' |
    LC_ALL=C sort -zu |
    while IFS= read -r -d '' relative; do
      printf '$(SRCROOT)/%s\n' "$relative"
    done
}

# On-disk counterparts the Xcode phases see (find, no .gitignore filtering).
# Only used to warn about local-only paths that the committed lists omit.
list_test_sources_on_disk() {
  local repo_root=$1
  (
    cd -- "$repo_root" &&
      find Intent IntentTests \( -type d -o -type f -name '*.swift' \) -print
  ) | LC_ALL=C sort |
    while IFS= read -r relative; do
      printf '$(SRCROOT)/%s\n' "$relative"
    done
}

list_swiftlint_sources_on_disk() {
  local repo_root=$1
  (
    cd -- "$repo_root" &&
      find Intent IntentTests IntentUITests \
        \( -path Intent/Resources -o -path Intent/Assets.xcassets -o -path IntentTests/Fixtures \) -prune -o \
        -type f -name '*.swift' -print
  ) | LC_ALL=C sort |
    while IFS= read -r relative; do
      printf '$(SRCROOT)/%s\n' "$relative"
    done
}
