#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

[ "$#" -eq 3 ] ||
  fail "usage: $0 SOURCE_ROOT DESTINATION/SourceInputs SCRATCH_ROOT/TestSourceInputsScratch"

source_root=${1%/}
destination=${2%/}
scratch_root=${3%/}
case "$source_root:$destination:$scratch_root" in
  /*:/*:/*) ;;
  *) fail "source root, destination, and scratch root must be absolute paths" ;;
esac
for candidate in "$source_root" "$destination" "$scratch_root"; do
  case "$candidate/" in
    */../*|*/./*) fail "source root, destination, and scratch root must not contain path traversal" ;;
  esac
done
[ -d "$source_root" ] && [ ! -L "$source_root" ] ||
  fail "source root must be a real, non-symlink directory"
canonical_source_root=$(cd -- "$source_root" && pwd -P) ||
  fail "cannot resolve physical source root"
source_root=$canonical_source_root
[ "${destination##*/}" = "SourceInputs" ] || fail "destination must be named SourceInputs"

destination_parent=${destination%/*}
[ -n "$destination_parent" ] && [ "$destination_parent" != "/" ] ||
  fail "destination parent must not be the filesystem root"
[ -d "$destination_parent" ] && [ ! -L "$destination_parent" ] ||
  fail "destination parent must be a real, non-symlink directory"
canonical_destination_parent=$(cd -- "$destination_parent" && pwd -P) ||
  fail "cannot resolve physical destination parent"
destination="$canonical_destination_parent/${destination##*/}"
case "$destination" in
  "$source_root"|"$source_root"/*) fail "destination must be outside source root" ;;
esac
case "$source_root" in
  "$destination"/*) fail "destination must not contain source root" ;;
esac
[ ! -L "$destination" ] || fail "existing destination must not be a symlink"

[ "${scratch_root##*/}" = "TestSourceInputsScratch" ] ||
  fail "scratch root must be named TestSourceInputsScratch"
scratch_parent=${scratch_root%/*}
[ -n "$scratch_parent" ] && [ "$scratch_parent" != "/" ] ||
  fail "scratch parent must not be the filesystem root"
[ -d "$scratch_parent" ] && [ ! -L "$scratch_parent" ] ||
  fail "scratch parent must be a real, non-symlink directory"
canonical_scratch_parent=$(cd -- "$scratch_parent" && pwd -P) ||
  fail "cannot resolve physical scratch parent"
scratch_root="$canonical_scratch_parent/${scratch_root##*/}"
case "$scratch_root" in
  "$source_root"|"$source_root"/*) fail "scratch root must be outside source root" ;;
  "$destination"|"$destination"/*) fail "scratch root must be separate from destination" ;;
esac
case "$source_root" in
  "$scratch_root"/*) fail "scratch root must not contain source root" ;;
esac
case "$destination" in
  "$scratch_root"/*) fail "destination must be separate from scratch root" ;;
esac
if [ -e "$scratch_root" ] || [ -L "$scratch_root" ]; then
  [ -d "$scratch_root" ] && [ ! -L "$scratch_root" ] ||
    fail "existing scratch root must be a real directory"
fi

for directory in Intent IntentTests; do
  [ -d "$source_root/$directory" ] && [ ! -L "$source_root/$directory" ] ||
    fail "$directory must be a real directory under source root"
done
for plist in Intent/Info.plist Info-visionOS.plist; do
  [ -f "$source_root/$plist" ] && [ ! -L "$source_root/$plist" ] ||
    fail "$plist must be a regular, non-symlink file"
done

if [ -e "$scratch_root" ]; then
  rm -rf -- "$scratch_root"
fi
mkdir "$scratch_root"
staging="$scratch_root/SourceInputs"
mkdir "$staging"
path_list="$staging/.paths"
source_list="$staging/.sources"
symlink_list="$staging/.symlinks"
cleanup() { rm -rf -- "$scratch_root"; }
trap cleanup EXIT

find "$source_root/Intent" "$source_root/IntentTests" -type l -print0 > "$symlink_list"
while IFS= read -r -d '' link; do
  case "$link" in
    *.swift) fail "Swift source must not be a symlink: $link" ;;
  esac
  [ ! -d "$link" ] || fail "source directory must not be a symlink: $link"
done < "$symlink_list"
rm "$symlink_list"

printf '%s\n' Intent/Info.plist Info-visionOS.plist > "$path_list"
find "$source_root/Intent" "$source_root/IntentTests" \
  -type f -name '*.swift' -print0 > "$source_list"
while IFS= read -r -d '' source; do
  relative=${source#"$source_root/"}
  [ "$relative" != "$source" ] || fail "source escaped source root: $source"
  case "$relative" in
    *$'\n'*) fail "source path contains a newline" ;;
  esac
  printf '%s\n' "$relative" >> "$path_list"
done < "$source_list"
rm "$source_list"

LC_ALL=C sort -u "$path_list" -o "$path_list"
while IFS= read -r relative; do
  target="$staging/$relative"
  mkdir -p "${target%/*}"
  cp -p "$source_root/$relative" "$target"
done < "$path_list"
mv "$path_list" "$staging/manifest.txt"

previous="$scratch_root/PreviousSourceInputs"
if [ -e "$destination" ] || [ -L "$destination" ]; then
  [ -d "$destination" ] && [ ! -L "$destination" ] ||
    fail "existing destination must be a real directory"
  mv "$destination" "$previous"
fi
if ! mv "$staging" "$destination"; then
  if [ -e "$previous" ]; then
    mv "$previous" "$destination" ||
      fail "cannot publish source inputs or restore previous destination"
  fi
  fail "cannot publish source inputs"
fi
if [ -e "$previous" ]; then
  rm -rf -- "$previous"
fi
trap - EXIT