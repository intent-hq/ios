#!/usr/bin/env bash
set -euo pipefail

# Reduce only ordinary PRs whose complete changed-file response is trustworthy.
# Schedules, manual/full runs, merge queues, and uncertain inputs retain two runs.
repetitions=2
verified_file_count() {
  local metadata
  metadata=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER" 2>/dev/null) || return 1
  jq -ers --arg head "$PR_HEAD_SHA" --arg base "$PR_BASE_SHA" '
    if length == 1 then .[0] else error("invalid metadata response") end
    | select(type == "object" and .head.sha == $head and .base.sha == $base)
    | .changed_files
    | select(type == "number" and . == floor and . > 0 and . < 3000)
  ' <<< "$metadata" 2>/dev/null
}

if [[ "${GITHUB_EVENT_NAME:-}" == pull_request ]]; then
  if [[ ! "${PR_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] ||
      [[ ! "${PR_HEAD_SHA:-}" =~ ^[0-9a-f]{40}$ || ! "${PR_BASE_SHA:-}" =~ ^[0-9a-f]{40}$ ]] ||
      [[ ! "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+$ ]] ||
      [[ "${GITHUB_REPOSITORY##*/}" == . || "${GITHUB_REPOSITORY##*/}" == .. ]] ||
      [[ -z "${GH_TOKEN:-}" || "${GH_TOKEN:-}" =~ [[:space:][:cntrl:]] ]]; then
    echo '::notice::Pull request inputs unavailable; keeping two screenshot contract repetitions'
  else
    response=$(mktemp)
    trap 'rm -f "$response"' EXIT
    if expected_count=$(verified_file_count) && gh api --paginate --slurp \
        "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/files?per_page=100" \
        >"$response" 2>/dev/null && final_count=$(verified_file_count) &&
        [[ "$expected_count" == "$final_count" ]]; then
      if selected=$(jq -ers --argjson expected_count "$expected_count" '
          def valid_path:
            type == "string" and length > 0 and
            (test("^/|//|/$|\\\\|(^|/)\\.\\.?(/|$)|[[:cntrl:]]") | not);
          def relevant:
            . == ".github/workflows/ci.yml" or
            startswith(".github/actions/export-ui-evidence/") or
            . == ".github/scripts/select-fixture-capture-repetitions.sh" or
            test("^IntentUITests/FixtureCapture[^/]*\\.swift$") or
            test("^scripts/.*(fixture_capture|ui_attachment_lifecycle)") or
            . == "scripts/export_ui_evidence.py" or
            . == "scripts/test_export_ui_evidence.py";
          # --slurp from gh must produce exactly one JSON document of pages.
          if length != 1 then error("invalid response count") else .[0] end
          | if type != "array" or length == 0 or length > 30 then
              error("missing or excessive pages")
            elif all(.[]; type == "array" and length > 0 and length <= 100) then .
            else error("invalid pages") end
          # Intermediate pages must be full. A full final page is safe only
          # because unchanged revision metadata independently proves the count.
          | if all(.[0:-1][]; length == 100) then add
            else error("incomplete pagination") end
          # GitHub caps this endpoint at 3000 files; that limit can hide changes.
          | if length != $expected_count or length >= 3000 then error("incomplete file list") else . end
          | if all(.[];
              type == "object" and
              (.filename | valid_path) and
              (.status | IN("added", "removed", "modified", "renamed", "copied",
                            "changed", "unchanged")) and
              (if has("previous_filename") then (.previous_filename | valid_path)
               else .status != "renamed" end))
            then . else error("invalid file entry") end
          | if (map(.filename) | unique | length) == length then .
            else error("duplicate files") end
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
