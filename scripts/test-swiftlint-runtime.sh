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

# Exercise policy rules through the real binary and production configuration.
# Compare exact rule/line pairs so unrelated formatter failures cannot satisfy
# rejection assertions, and allowed strings/comments cannot add false positives.
python3 - "$SWIFTLINT_PATH" "$REPO_ROOT/.swiftlint.yml" "$TEMP_ROOT" <<'PY'
from collections import Counter
import json
from pathlib import Path
import subprocess
import sys

binary, config, temp = sys.argv[1:]
button_rule = "generic_button_style"
icon_rule = "intent_system_icon"
sources = {"forbidden": [], "allowed": []}
expected = Counter()
case_names = {}


def fixture(name, source, rule=None, line=1):
    kind = "forbidden" if rule else "allowed"
    lines = sources[kind]
    lines.append(f"// Fixture: {name}")
    if rule:
        location = (rule, len(lines) + line)
        expected[location] += 1
        case_names[location] = name
    lines.extend(source.splitlines())
    lines.append("")


styles = {
    "plain": "PlainButtonStyle",
    "bordered": "BorderedButtonStyle",
    "borderedProminent": "BorderedProminentButtonStyle",
    "borderless": "BorderlessButtonStyle",
    "automatic": "DefaultButtonStyle",
    "glass": "GlassButtonStyle",
    "glassProminent": "GlassProminentButtonStyle",
    "link": "LinkButtonStyle",
}
for member, constructor in styles.items():
    fixture(member, f"_ = button.buttonStyle(.{member})", button_rule)
    fixture(f"multiline {member}",
            f"_ = button\n    .buttonStyle(\n        .{member}\n    )", button_rule, line=2)
    fixture(constructor, f"_ = button.buttonStyle({constructor}())", button_rule)
    fixture(f"qualified {constructor}",
            f"_ = button.buttonStyle(SwiftUI.{constructor}())", button_rule)
    fixture(f"explicit init {constructor}",
            f"_ = button.buttonStyle({constructor}.init())", button_rule)
    fixture(f"multiline {constructor}",
            f"_ = button.buttonStyle(\n    SwiftUI.{constructor}\n        .init()\n)",
            button_rule, line=2)
    fixture(f"stored {constructor}", f"let style = {constructor}()", button_rule)
    fixture(f"{member} in a string", f'_ = "button.buttonStyle(.{member})"')
    fixture(f"{constructor} in a string", f'_ = "{constructor}()"')
    fixture(f"{member} in a comment", f"// button.buttonStyle(.{member})")
    fixture(f"{constructor} in a comment", f"// {constructor}()")

fixture("content style", "_ = button.buttonStyle(IntentContentButtonStyle())")
fixture("filled style", "_ = button.buttonStyle(IntentButtonStyle())")
fixture("multiline content style", "_ = button.buttonStyle(\n    IntentContentButtonStyle()\n)")
fixture("other custom style", "_ = button.buttonStyle(CustomButtonStyle())")
fixture("similarly named custom style", "_ = button.buttonStyle(CustomPlainButtonStyle())")
fixture("custom static member", "_ = button.buttonStyle(.plainCustom)")
fixture("unrelated plain member", "_ = text.listStyle(.plain)")
fixture("block comment", "/*\nbutton.buttonStyle(\n    .plain\n)\nPlainButtonStyle()\n*/")
fixture("doc comment", "/// button.buttonStyle(.borderedProminent); DefaultButtonStyle()")
fixture("multiline string", '_ = """\nbutton.buttonStyle(\n    .plain\n)\nPlainButtonStyle()\n"""')
fixture("raw string", '_ = #"button.buttonStyle(.plain); PlainButtonStyle()"#')
# Implicit styles, aliases and native menu actions need a screen audit; this
# syntax rule does not infer SwiftUI types or the surrounding view hierarchy.
fixture("native menu action", 'Button("Delete", systemImage: "trash", role: .destructive) {}')
fixture("implicit button", 'Button("Continue") {}')

icons = {
    "plus": "addIcon", "xmark": "close", "magnifyingglass": "search",
    "ellipsis": "more", "eye": "eye", "eye.slash": "eyeClosed",
}
for symbol, asset in icons.items():
    fixture(symbol, f'_ = Image(systemName: "{symbol}")', icon_rule)
    fixture(f"qualified {symbol}", f'_ = SwiftUI.Image(systemName: "{symbol}")', icon_rule)
    fixture(f"explicit init {symbol}", f'_ = Image.init(systemName: "{symbol}")', icon_rule)
    fixture(f"multiline {symbol}", f'_ = Image(\n    systemName:\n        "{symbol}"\n)', icon_rule)
    fixture(asset, f"_ = Image(.{asset})")
    fixture(f"{symbol} in a comment", f'// Image(systemName: "{symbol}")')
    fixture(f"{symbol} in a string", f'_ = #"Image(systemName: "{symbol}")"#')
    fixture(f"native label {symbol}", f'_ = Label("Action", systemImage: "{symbol}")')
fixture("other system symbol", '_ = Image(systemName: "exclamationmark.triangle")')
fixture("similar system symbol", '_ = Image(systemName: "plus.circle")')
fixture("computed system symbol", "_ = Image(systemName: symbolName)")
fixture("asset string", '_ = Image("plus")')
fixture("custom image initializer", '_ = CustomImage(systemName: "plus")')
fixture("icon block comment", '/*\nImage(\n    systemName: "plus"\n)\n*/')
fixture("icon multiline string", '_ = """\nImage(\n    systemName: "plus"\n)\n"""')

for kind, lines in sources.items():
    source = "\n".join(lines)
    Path(temp, f"{kind}-styles.swift").write_text(source)
    result = subprocess.run(
        [binary, "lint", "--config", config, "--strict", "--no-cache", "--use-stdin", "--reporter", "json"],
        input=source, text=True, capture_output=True, check=False,
    )
    Path(temp, f"{kind}-styles.json").write_text(result.stdout)
    assert result.returncode in (0, 2), (kind, result.returncode, result.stderr)
    violations = json.loads(result.stdout)
    policy = [item for item in violations if item["rule_id"] in (button_rule, icon_rule)]
    actual = Counter((item["rule_id"], item["line"]) for item in policy)
    wanted = expected if kind == "forbidden" else Counter()
    missing = {case_names[key]: count for key, count in (wanted - actual).items()}
    assert actual == wanted, (kind, "missing", missing, "unexpected", actual - wanted, result.stderr)
    for item in policy:
        assert item["severity"] == "Error", item
        replacements = ("IntentContentButtonStyle", "IntentButtonStyle") if item["rule_id"] == button_rule else icons.values()
        assert all(name in item["reason"] for name in replacements), item
    if kind == "forbidden":
        assert result.returncode == 2, (kind, result.returncode)
    # Allowed fixtures may have unrelated formatting/accessibility findings;
    # they must never trigger either policy rule. No production rule is disabled.

print(f"Real SwiftLint 0.65.1: {sum(expected.values())} button/icon policy errors verified; allowed fixtures produced no policy errors")
PY
