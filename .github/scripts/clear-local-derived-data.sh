#!/usr/bin/env bash
set -euo pipefail

# Remove the Xcode DerivedData folders that belong to this checkout's
# Intent.xcodeproj, so a self-hosted job builds from scratch as a hosted runner
# does. The runner's checkout path is fixed, so every branch otherwise shares
# one DerivedData folder, and a partial or other-branch build left there can
# crash the next job's tests (ios#592). Folders of other projects are matched
# by their info.plist WorkspacePath and left alone.
#
# Usage: clear-local-derived-data.sh [checkout-root] (default: current directory)
root=$(cd "${1:-.}" && pwd -P)
project="$root/Intent.xcodeproj"
derived_data=${DERIVED_DATA_ROOT:-"$HOME/Library/Developer/Xcode/DerivedData"}

removed=0
shopt -s nullglob
for dir in "$derived_data"/Intent-*; do
  plist="$dir/info.plist"
  [ -f "$plist" ] || continue
  workspace=$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$plist" 2>/dev/null || true)
  if [ "$workspace" = "$project" ]; then
    echo "Removing $dir ($(du -sh "$dir" | cut -f1))"
    rm -rf "$dir"
    removed=$((removed + 1))
  fi
done
echo "Removed $removed DerivedData folder(s) for $project"
