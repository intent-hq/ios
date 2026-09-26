#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source-path=SCRIPTDIR
# shellcheck source=swiftlint-tools.sh
source "$SCRIPT_DIR/swiftlint-tools.sh"

die() {
  echo "error: $*" >&2
  exit 1
}

[ "$#" -eq 0 ] || die "scripts/swiftlint.sh takes no arguments"

swiftlint_find
swiftlint_version_check
swiftlint_linux_preflight

lint_args=(
  lint
  --config "$REPO_ROOT/.swiftlint.yml"
  --strict
  --no-cache
)
# SWIFTLINT_REPORTER overrides the config's reporter (CI sets
# github-actions-logging so violations render as PR annotations); unset or
# empty leaves the config's reporter in effect.
if [ -n "${SWIFTLINT_REPORTER:-}" ]; then
  lint_args+=(--reporter "$SWIFTLINT_REPORTER")
fi

cd "$REPO_ROOT"
exec "$SWIFTLINT_PATH" "${lint_args[@]}"
