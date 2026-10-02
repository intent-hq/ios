#!/usr/bin/env bash
# Called only after both platforms have processed and reached the internal group.
set -euo pipefail

if [[ ! "${TESTFLIGHT_TAG:-}" =~ ^testflight/(alpha|beta)/[0-9]+$ ]] ||
   [[ ! "${TESTFLIGHT_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Invalid TestFlight tag or commit." >&2
  exit 1
fi
git cat-file -e "${TESTFLIGHT_COMMIT}^{commit}"
existing=$(git ls-remote --refs origin "refs/tags/$TESTFLIGHT_TAG")
if [ -n "$existing" ]; then
  if [ "${existing%%[[:space:]]*}" != "$TESTFLIGHT_COMMIT" ]; then
    echo "Refusing to replace existing $TESTFLIGHT_TAG on another commit." >&2
    exit 1
  fi
  echo "$TESTFLIGHT_TAG already points to the built commit."
else
  # Push the captured commit, never whichever branch tip exists after archiving.
  git push origin "$TESTFLIGHT_COMMIT:refs/tags/$TESTFLIGHT_TAG"
fi