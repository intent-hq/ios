#!/usr/bin/env bash
set -euo pipefail

# GITHUB_TOKEN cannot read repository runner status. RUNNER_STATUS_TOKEN needs
# only Administration: read for this repository. When it is unavailable (for
# example on a fork PR), use a GitHub-hosted Mac.
hosted='"macos-15"'
local_runner='["self-hosted","macOS","ARM64","intent-ios"]'
selected="$hosted"

if [ -z "${RUNNER_STATUS_TOKEN:-}" ]; then
  echo '::notice::RUNNER_STATUS_TOKEN is unavailable; using macos-15'
else
  response=$(mktemp)
  trap 'rm -f "$response"' EXIT
  if curl -fsS --connect-timeout 10 --max-time 20 \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer $RUNNER_STATUS_TOKEN" \
      "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/runners?per_page=100" \
      -o "$response"; then
    if jq -e --arg name 'Sams-MacBook-Pro-2-intent-ios' '
        .runners[]
        | select(.name == $name and .status == "online")
        | select([.labels[].name] | index("intent-ios"))
      ' "$response" >/dev/null; then
      selected="$local_runner"
      echo '::notice::Local Mac is online; using intent-ios runner'
    else
      echo '::notice::Local Mac is offline; using macos-15'
    fi
  else
    echo '::warning::Could not check local Mac status; using macos-15'
  fi
fi

echo "runs-on=$selected" >> "$GITHUB_OUTPUT"
