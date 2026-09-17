#!/usr/bin/env bash
set -euo pipefail

readonly EXPECTED_SWIFTLINT_VERSION="0.65.1"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

die() {
  echo "error: $*" >&2
  exit 1
}

[ "$#" -eq 0 ] || die "scripts/swiftlint.sh takes no arguments"

if ! SWIFTLINT_PATH=$(command -v swiftlint); then
  die "SwiftLint $EXPECTED_SWIFTLINT_VERSION is required, but swiftlint was not found on PATH"
fi

if ! ACTUAL_SWIFTLINT_VERSION=$("$SWIFTLINT_PATH" version); then
  die "unable to run '$SWIFTLINT_PATH version'"
fi

if [ "$ACTUAL_SWIFTLINT_VERSION" != "$EXPECTED_SWIFTLINT_VERSION" ]; then
  die "SwiftLint $EXPECTED_SWIFTLINT_VERSION is required; found $ACTUAL_SWIFTLINT_VERSION at $SWIFTLINT_PATH"
fi

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
