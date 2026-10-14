#!/usr/bin/env bash
set -euo pipefail

# All simulator and build jobs use ephemeral Depot Apple Silicon runners.
# No local-fleet probe or GitHub runner-inventory token is needed.
echo 'runs-on="depot-macos-15"' >> "$GITHUB_OUTPUT"
