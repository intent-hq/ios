#!/usr/bin/env bash
# Reports stored properties that are assigned but never read (Periphery's
# assign-only hint), the trace of a write-only state flag. Existing findings
# live in scripts/periphery-baseline.json, so only new ones are reported.
#
# Usage (macOS, with `brew install periphery`):
#   DERIVED_DATA_DIR=<dir> scripts/periphery-assign-only.sh [--write-baseline]
#
# It scans the index store of a wrapper build in DERIVED_DATA_DIR and runs
# `scripts/xcodebuild.sh build-for-testing` first when that store is missing.
# Exit status: 0 when nothing new is found, 1 when new assign-only properties
# are listed, 2 for bad usage or a missing tool. --write-baseline replaces the
# baseline with the current findings (review the diff before committing).
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 2
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
baseline="$script_dir/periphery-baseline.json"

write_baseline=0
case "${1:-}" in
  "") ;;
  --write-baseline) write_baseline=1 ;;
  *) fail "usage: DERIVED_DATA_DIR=<dir> $0 [--write-baseline]" ;;
esac
[ -n "${DERIVED_DATA_DIR:-}" ] || fail "set DERIVED_DATA_DIR to a wrapper build's derived data directory"
command -v periphery >/dev/null || fail "periphery is not on PATH; install it with: brew install periphery"

index_store="$DERIVED_DATA_DIR/Index.noindex/DataStore"
cd "$repo_root"
if [ ! -d "$index_store" ]; then
  echo "notice: no index store in $DERIVED_DATA_DIR; building with scripts/xcodebuild.sh build-for-testing" >&2
  scripts/xcodebuild.sh build-for-testing
fi

scan=(periphery scan --project Intent.xcodeproj --schemes Intent --index-store-path "$index_store"
  --relative-results --quiet --disable-update-check)
if [ "$write_baseline" -eq 1 ]; then
  "${scan[@]}" --format json --write-baseline "$baseline" > /dev/null
  echo "wrote $baseline"
  exit 0
fi

results=$(mktemp "${TMPDIR:-/tmp}/periphery-results.XXXXXX")
trap 'rm -f -- "$results"' EXIT
baseline_args=()
[ -f "$baseline" ] && baseline_args=(--baseline "$baseline")
"${scan[@]}" ${baseline_args[@]+"${baseline_args[@]}"} --format json > "$results"

python3 - "$results" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    findings = [item for item in json.load(handle) if "assignOnlyProperty" in item.get("hints", [])]
for item in sorted(findings, key=lambda entry: entry["location"]):
    print(f"{item['location']}: warning: '{item['name']}' is assigned but never read")
if findings:
    print(f"{len(findings)} new assign-only propert{'y' if len(findings) == 1 else 'ies'}: "
          "read the value, delete it, or fold it into the state it shadows", file=sys.stderr)
    sys.exit(1)
print("no new assign-only properties")
PY
