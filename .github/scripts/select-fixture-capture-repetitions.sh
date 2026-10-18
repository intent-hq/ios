#!/usr/bin/env bash
set -euo pipefail

# Reduce only ordinary PRs whose complete changed-file response is trustworthy.
# Schedules, manual/full runs, merge queues, and uncertain inputs retain two runs.
repetitions=2
if [[ "${GITHUB_EVENT_NAME:-}" == pull_request ]]; then
  if [[ ! "${PR_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] ||
      [[ ! "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
      [[ -z "${GH_TOKEN:-}" ]]; then
    echo '::notice::Pull request inputs unavailable; keeping two screenshot contract repetitions'
  else
    response=$(mktemp)
    trap 'rm -f "$response"' EXIT
    if gh api --paginate --slurp \
        "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/files?per_page=100" \
        >"$response" 2>/dev/null; then
      if selected=$(jq -er '
          def valid_path:
            type == "string" and length > 0 and
            (test("^/|(^|/)\\.\\.?(/|$)|[[:cntrl:]]") | not);
          def relevant:
            . == ".github/workflows/ci.yml" or
            startswith(".github/actions/export-ui-evidence/") or
            . == ".github/scripts/select-fixture-capture-repetitions.sh" or
            test("^IntentUITests/FixtureCapture[^/]*\\.swift$") or
            test("^scripts/.*(fixture_capture|ui_attachment_lifecycle)") or
            . == "scripts/export_ui_evidence.py" or
            . == "scripts/test_export_ui_evidence.py";
          if type != "array" or length == 0 then
            error("missing pages")
          elif all(.[]; type == "array") then add
          else error("invalid pages") end
          # GitHub caps this endpoint at 3000 files; that limit can hide changes.
          | if length == 0 or length >= 3000 then error("incomplete file list") else . end
          | if all(.[];
              type == "object" and
              (.filename | valid_path) and
              (.status | IN("added", "removed", "modified", "renamed", "copied",
                            "changed", "unchanged")) and
              (if has("previous_filename") then (.previous_filename | valid_path)
               else .status != "renamed" end))
            then . else error("invalid file entry") end
          | if any(.[]; (.filename, (.previous_filename // empty)) | relevant)
            then 2 else 1 end
        ' "$response" 2>/dev/null) && [[ "$selected" =~ ^[12]$ ]]; then
        repetitions="$selected"
      else
        echo '::notice::Changed files could not be verified; keeping two screenshot contract repetitions'
      fi
    else
      echo '::notice::Changed files unavailable; keeping two screenshot contract repetitions'
    fi
  fi
fi

echo "repetitions=$repetitions" >> "$GITHUB_OUTPUT"
