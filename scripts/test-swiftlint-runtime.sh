#!/usr/bin/env bash
# Real pinned binary + SourceKit + unchanged repository rules; never stubs.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=swiftlint-tools.sh
source "$SCRIPT_DIR/swiftlint-tools.sh"
swiftlint_find
swiftlint_version_check
swiftlint_linux_preflight
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/intent-swiftlint-runtime.XXXXXX")
trap 'rm -rf -- "$TEMP_ROOT"' EXIT
cat > "$TEMP_ROOT/clean.swift" <<'EOF'
_ = [
    "one",
    "two"
]
EOF
cat > "$TEMP_ROOT/violation.swift" <<'EOF'
_ = ["one",
     "two"]
EOF

# stdin avoids the config's included source directories. No tracked inputs or
# rules change, and --strict still determines each process's real exit status.
"$SWIFTLINT_PATH" lint --config "$REPO_ROOT/.swiftlint.yml" --strict --no-cache \
  --use-stdin --reporter json < "$TEMP_ROOT/clean.swift" > "$TEMP_ROOT/clean.json"
set +e
"$SWIFTLINT_PATH" lint --config "$REPO_ROOT/.swiftlint.yml" --strict --no-cache \
  --use-stdin --reporter json < "$TEMP_ROOT/violation.swift" > "$TEMP_ROOT/violation.json"
status=$?
set -e
[ "$status" -eq 2 ] || { echo "expected violation exit 2, got $status" >&2; exit 1; }
python3 - "$TEMP_ROOT/clean.json" "$TEMP_ROOT/violation.json" <<'PY'
import json
from pathlib import Path
import sys

assert json.loads(Path(sys.argv[1]).read_text()) == [], "clean fixture has violations"
violations = json.loads(Path(sys.argv[2]).read_text())
assert any(item["rule_id"] == "multiline_literal_brackets" for item in violations), violations
print("Real SwiftLint 0.65.1: clean multiline literal passed; multiline_literal_brackets failed (exit 2)")
PY
