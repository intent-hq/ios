#!/usr/bin/env bash
# Fails when a built Intent.app binary loads /usr/lib/swift/libswiftWebKit.dylib.
#
# With the iOS 18.0 deployment target, WebKit's Swift-only APIs (async
# callAsyncJavaScript/evaluateJavaScript, pdf, find, ...) bind to that legacy
# overlay path instead of WebKit.framework. The iOS 18.4-18.5 simulator
# runtimes cannot load it, so the app aborts in dyld before main (ios#905,
# WebKit bug 293831). Call the Objective-C methods instead (see
# Intent/Utils/WKWebView+PageJavaScript.swift).
#
# Usage: scripts/check-webkit-overlay-linkage.sh <path/to/Intent.app>...
#        DERIVED_DATA_DIR=... scripts/check-webkit-overlay-linkage.sh
# With no arguments, checks every Intent.app under
# $DERIVED_DATA_DIR/Build/Products/*-iphonesimulator and *-iphoneos.
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
for app in "${apps[@]}"; do
  [ -d "$app" ] || fail "not an app bundle: $app"
  checked=0
  # Debug builds put the code in Intent.debug.dylib; Release links it into Intent.
  for binary in "$app/Intent" "$app/Intent.debug.dylib"; do
    [ -f "$binary" ] || continue
    checked=1
    if otool -L "$binary" | grep -qF "$overlay"; then
      echo "error: $binary loads $overlay; it cannot launch on iOS 18.4-18.5 simulators (ios#905)." >&2
      echo "Swift WebKit symbols bound from it:" >&2
      xcrun dyld_info -imports "$binary" | awk '/\(from libswiftWebKit\)/ { print "  " $2 }' | sort -u >&2 || true
      status=1
    else
      echo "ok: $binary does not load $overlay"
    fi
  done
  [ "$checked" -eq 1 ] || fail "no Intent binary in $app"
done
exit "$status"
