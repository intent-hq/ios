#!/usr/bin/env bash
set -euo pipefail

# Reduce only ordinary PRs containing exclusively unrelated modified files.
# Unknown paths, uncertain pagination, and every other event retain both themes.
appearances=both
if [[ "${GITHUB_EVENT_NAME:-}" == pull_request ]]; then
  if [[ ! "${PR_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] ||
      [[ ! "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+$ ]] ||
      [[ "${GITHUB_REPOSITORY##*/}" == . || "${GITHUB_REPOSITORY##*/}" == .. ]] ||
      [[ -z "${GH_TOKEN:-}" || "${GH_TOKEN:-}" =~ [[:space:][:cntrl:]] ]]; then
    echo '::notice::Pull request inputs unavailable; keeping both workspace entry appearances'
  else
    response=$(mktemp)
    trap 'rm -f "$response"' EXIT
    if gh api --paginate --slurp \
        "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/files?per_page=100" \
        >"$response" 2>/dev/null; then
      if selected=$(jq -ers '
          def valid_path:
            type == "string" and length > 0 and
            (test("^/|//|/$|\\\\|(^|/)\\.\\.?(/|$)|[[:cntrl:]]") | not);
          def unrelated:
            . == "README.md" or . == "AGENTS.md" or . == "LICENSE" or
            test("^IntentTests/[^/]+\\.swift$") or
            . == "Intent/Views/Conversation/Content/PDFLightboxView.swift" or
            . == "Intent/Views/Conversation/Content/PDFLinkPreviewView.swift" or
            . == "Intent/Views/Conversation/Content/IntentFilePDFAttachment.swift" or
            . == "Intent/Views/Conversation/Notices/WatcherMessageBodyView.swift" or
            . == "Intent/Presentation/WatcherMessagePresentation.swift" or
            . == "Intent/Services/MobileTerminalStore.swift" or
            . == "Intent/Services/MobileTerminalConnection.swift";
          # --slurp from gh must produce exactly one JSON document of pages.
          if length != 1 then error("invalid response count") else .[0] end
          | if type != "array" or length == 0 or length > 30 then
              error("missing or excessive pages")
            elif all(.[]; type == "array" and length > 0 and length <= 100) then .
            else error("invalid pages") end
          # Require full intermediate pages and an unambiguous short final page.
          # A full final page may be a truncated response, so keep both themes
          # even for legitimate PRs whose file count is a multiple of 100.
          | if all(.[0:-1][]; length == 100) and (.[-1] | length < 100) then add
            else error("incomplete pagination") end
          # GitHub caps this endpoint at 3000 files; that limit can hide changes.
          | if length == 0 or length >= 3000 then error("incomplete file list") else . end
          | if all(.[];
              type == "object" and
              (.filename | valid_path) and
              .status == "modified" and
              (has("previous_filename") | not))
            then . else error("not exclusively modified files") end
          | if (map(.filename) | unique | length) == length then .
            else error("duplicate files") end
          | if all(.[]; .filename | unrelated) then "light" else "both" end
        ' "$response" 2>/dev/null) && [[ "$selected" == light || "$selected" == both ]]; then
        appearances="$selected"
      else
        echo '::notice::Changed files could not be verified; keeping both workspace entry appearances'
      fi
    else
      echo '::notice::Changed files unavailable; keeping both workspace entry appearances'
    fi
  fi
fi

echo "appearances=$appearances" >> "$GITHUB_OUTPUT"
