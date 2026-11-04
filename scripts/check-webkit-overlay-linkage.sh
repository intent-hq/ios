#!/usr/bin/env bash
# Fails when a built Intent.app binary, or a test bundle built next to it,
# loads /usr/lib/swift/libswiftWebKit.dylib.
#
# With the iOS 18.0 deployment target, WebKit's Swift-only APIs (async
# callAsyncJavaScript/evaluateJavaScript, pdf, find, ...) bind to that legacy
# overlay path instead of WebKit.framework. The iOS 18.4-18.5 simulator
# runtimes cannot load it, so the app aborts in dyld before main (ios#905,
# WebKit bug 293831), and a test bundle that links it cannot be injected.
# Call the Objective-C methods instead (see
# Intent/Utils/WKWebView+PageJavaScript.swift).
#
# Usage: scripts/check-webkit-overlay-linkage.sh <path/to/Intent.app>...
#        DERIVED_DATA_DIR=... scripts/check-webkit-overlay-linkage.sh
# With no arguments, checks every Intent.app under
# $DERIVED_DATA_DIR/Build/Products/*-iphonesimulator and *-iphoneos.
# For each app it also checks Intent.app/PlugIns/*.xctest and, when present,
# the sibling *-Runner.app and its PlugIns/*.xctest (build-for-testing only).
set -euo pipefail

overlay=/usr/lib/swift/libswiftWebKit.dylib

fail() {
  echo "error: $*" >&2
  exit 1
}

apps=("$@")
if [ "${#apps[@]}" -eq 0 ]; then
  [ -n "${DERIVED_DATA_DIR:-}" ] || fail "pass Intent.app paths or set DERIVED_DATA_DIR"
  shopt -s nullglob
  apps=("$DERIVED_DATA_DIR"/Build/Products/*-iphonesimulator/Intent.app "$DERIVED_DATA_DIR"/Build/Products/*-iphoneos/Intent.app)
  shopt -u nullglob
  [ "${#apps[@]}" -gt 0 ] || fail "no Intent.app under $DERIVED_DATA_DIR/Build/Products"
fi

status=0

check_binary() {
  local binary=$1 links
  # Capture first: piping into grep -q could mask an otool failure (or its
  # SIGPIPE) as "not linked". otool exits 0 on a non-Mach-O file, so also
  # require at least one tab-indented load-command line.
  links=$(otool -L "$binary" 2>&1) || fail "otool -L failed on $binary: $links"
  grep -q $'^\t' <<< "$links" || fail "otool -L listed no libraries for $binary: $links"
  if grep -qF "$overlay" <<< "$links"; then
    echo "error: $binary loads $overlay; it cannot load on iOS 18.4-18.5 simulators (ios#905)." >&2
    echo "Swift WebKit symbols bound from it:" >&2
    xcrun dyld_info -imports "$binary" | awk '/\(from libswiftWebKit\)/ { print "  " $2 }' | sort -u >&2 || true
    status=1
  else
    echo "ok: $binary does not load $overlay"
  fi
}

# Checks the main executable of each bundle (named after the bundle).
check_bundles() {
  local bundle binary
  for bundle in "$@"; do
    binary="$bundle/$(basename "${bundle%.*}")"
    [ -f "$binary" ] || fail "no executable in $bundle"
    check_binary "$binary"
  done
}

for app in "${apps[@]}"; do
  [ -d "$app" ] || fail "not an app bundle: $app"
  checked=0
  # Debug builds put the code in Intent.debug.dylib; Release links it into Intent.
  for binary in "$app/Intent" "$app/Intent.debug.dylib"; do
    [ -f "$binary" ] || continue
    checked=1
    check_binary "$binary"
  done
  [ "$checked" -eq 1 ] || fail "no Intent binary in $app"

  shopt -s nullglob
  test_bundles=("$app"/PlugIns/*.xctest)
  runners=("$(dirname "$app")"/*-Runner.app)
  # ${a[@]+...} keeps empty arrays safe under set -u in macOS's bash 3.2.
  for runner in ${runners[@]+"${runners[@]}"}; do
    test_bundles+=("$runner" "$runner"/PlugIns/*.xctest)
  done
  shopt -u nullglob
  if [ "${#test_bundles[@]}" -eq 0 ]; then
    echo "note: no test bundles next to $app"
  else
    check_bundles "${test_bundles[@]}"
  fi
done
exit "$status"
