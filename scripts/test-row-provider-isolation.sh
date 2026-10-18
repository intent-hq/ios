#!/usr/bin/env bash
# Compile the production boundary with positive and negative SwiftUI fixtures.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/intent-row-provider.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
boundary="$repo_root/Intent/Views/Components/ForEach+Snapshots.swift"
fixtures="$script_dir/fixtures/row-provider"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
compiler=(xcrun --sdk iphonesimulator swiftc -typecheck -swift-version 6
  -default-isolation MainActor -strict-concurrency=complete
  -sdk "$sdk" -target "$(uname -m)-apple-ios18.0-simulator")

"${compiler[@]}" "$boundary" "$fixtures/Safe.swift"
echo 'PASS: prepared values and main-actor actions compile'

reject() {
  local fixture=$1 diagnostic=$2
  if "${compiler[@]}" "$boundary" "$fixtures/$fixture.swift" > "$scratch/$fixture.log" 2>&1; then
    echo "error: $fixture unexpectedly compiled; deferred row isolation is not enforced" >&2
    exit 1
  fi
  if ! grep -Eq "$diagnostic" "$scratch/$fixture.log"; then
    cat "$scratch/$fixture.log" >&2
    echo "error: $fixture failed for an unexpected reason" >&2
    exit 1
  fi
  cat "$scratch/$fixture.log"
  echo "PASS: $fixture rejected for actor isolation"
}

reject MainActorRead "main actor-isolated property 'title'.*Sendable closure"
reject IsolatedBuilder "loses global actor 'MainActor'"
