#!/usr/bin/env bash
set -euo pipefail

# GITHUB_TOKEN cannot read repository runner status. RUNNER_STATUS_TOKEN needs
# only Administration: read for this repository. When it is unavailable (for
# example on a fork PR), use a GitHub-hosted Mac.
hosted='"macos-26-xlarge"'
local_runner='["self-hosted","macOS","ARM64","intent-ios"]'
pool_label=${RUNNER_POOL_LABEL:-intent-ios}
preferred_runner=$(jq -cn --arg pool "$pool_label" '["self-hosted","macOS","ARM64",$pool]')
selected="$hosted"

if [ -z "${RUNNER_STATUS_TOKEN:-}" ]; then
  echo '::notice::RUNNER_STATUS_TOKEN is unavailable; using macos-26-xlarge'
else
  response=$(mktemp)
  trap 'rm -f "$response"' EXIT
  if curl -fsS --connect-timeout 10 --max-time 20 \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer $RUNNER_STATUS_TOKEN" \
      "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/runners?per_page=100" \
      -o "$response"; then
    if jq -e --argjson required "$preferred_runner" '
        any(.runners[];
          .status == "online" and .busy == false and
          (($required - [.labels[].name]) | length == 0))
      ' "$response" >/dev/null; then
      selected="$preferred_runner"
      echo "::notice::A matching Mac is online and idle; using the $pool_label runner pool"
    elif [ "$pool_label" != intent-ios ] && jq -e --argjson required "$local_runner" '
        any(.runners[];
          .status == "online" and .busy == false and
          (($required - [.labels[].name]) | length == 0))
      ' "$response" >/dev/null; then
      selected="$local_runner"
      echo '::notice::Build pool unavailable; using the intent-ios runner pool'
    else
      echo '::notice::No matching Mac is online and idle; using macos-26-xlarge'
    fi
  else
    echo '::warning::Could not check local Mac status; using macos-26-xlarge'
  fi
fi

echo "runs-on=$selected" >> "$GITHUB_OUTPUT"
