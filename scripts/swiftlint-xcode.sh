#!/usr/bin/env bash
set -uo pipefail

readonly EXPECTED_SWIFTLINT_VERSION="0.65.1"

warning() {
  printf 'warning: %s\n' "$*" >&2
}

record_invalid_entry() {
  invalid_count=$((invalid_count + 1))
  if [ -z "$invalid_example" ]; then
    invalid_example="$1"
  fi
}

normalize_input_file_list() {
  local input_file_list="$1"
  local entry
  local relative_path
  local normalized
  local read_status

  normalized_sources=""
  normalized_count=0
  invalid_count=0
  invalid_example=""

  while IFS= read -r entry || [ -n "$entry" ]; do
    case "$entry" in
      '$(SRCROOT)/'*)
        relative_path="${entry#'$(SRCROOT)/'}"
        normalized="$repo_root/$relative_path"
        ;;
      /*)
        normalized="$entry"
        ;;
      *)
        record_invalid_entry "$entry"
        continue
        ;;
    esac

    case "$normalized" in
      *//*|*/./*|*/../*|*/.|*/..)
        record_invalid_entry "$entry"
        continue
        ;;
    esac

    case "$normalized" in
      "$repo_root"/Intent/*.swift|"$repo_root"/IntentTests/*.swift|"$repo_root"/IntentUITests/*.swift)
        ;;
      *)
        record_invalid_entry "$entry"
        continue
        ;;
    esac

    if [ -n "$normalized_sources" ]; then
      normalized_sources+=$'\n'
    fi
    normalized_sources+="$normalized"
    normalized_count=$((normalized_count + 1))
  done < "$input_file_list"
  read_status=$?

  if [ "$read_status" -ne 0 ]; then
    return "$read_status"
  fi

  return 0
}

line_count() {
  local lines="$1"

  if [ -z "$lines" ]; then
    printf '0\n'
  else
    printf '%s\n' "$lines" | awk 'END { print NR }'
  fi
}

first_line() {
  printf '%s\n' "$1" | sed -n '1p'
}

check_input_parity() {
  local input_file_list="$1"
  local actual_sources
  local listed_sources
  local duplicate_entries
  local duplicate_count
  local missing_sources
  local missing_count
  local stale_sources
  local stale_count
  local failed=0

  if ! actual_sources="$(find "$repo_root/Intent" "$repo_root/IntentTests" "$repo_root/IntentUITests" \
    \( -path "$repo_root/Intent/Resources" -o -path "$repo_root/Intent/Assets.xcassets" \
      -o -path "$repo_root/IntentTests/Fixtures" \) -prune -o \
    -type f -name '*.swift' -print | LC_ALL=C sort)"; then
    warning "SwiftLint diagnostics could not enumerate configured Swift sources; update the sandbox inputs"
    return 1
  fi

  if ! normalize_input_file_list "$input_file_list"; then
    warning "SwiftLint diagnostics could not read $input_file_list; update the sandbox inputs"
    return 1
  fi

  listed_sources="$(printf '%s\n' "$normalized_sources" | LC_ALL=C sort -u)"
  duplicate_entries="$(printf '%s\n' "$normalized_sources" | LC_ALL=C sort | uniq -d)"
  duplicate_count="$(line_count "$duplicate_entries")"
  missing_sources="$(comm -23 <(printf '%s\n' "$actual_sources") <(printf '%s\n' "$listed_sources"))"
  missing_count="$(line_count "$missing_sources")"
  stale_sources="$(comm -13 <(printf '%s\n' "$actual_sources") <(printf '%s\n' "$listed_sources"))"
  stale_count="$(line_count "$stale_sources")"

  if [ "$invalid_count" -ne 0 ]; then
    warning "SwiftLint input list has $invalid_count invalid or out-of-root path(s); example: $invalid_example"
    failed=1
  fi
  if [ "$duplicate_count" -ne 0 ]; then
    warning "SwiftLint input list has $duplicate_count duplicate normalized path(s); example: $(first_line "$duplicate_entries")"
    failed=1
  fi
  if [ "$missing_count" -ne 0 ]; then
    warning "SwiftLint input list is missing $missing_count source path(s); example: $(first_line "$missing_sources")"
    failed=1
  fi
  if [ "$stale_count" -ne 0 ]; then
    warning "SwiftLint input list has $stale_count stale source path(s); example: $(first_line "$stale_sources")"
    failed=1
  fi

  if [ "$failed" -ne 0 ]; then
    warning "Regenerate scripts/swiftlint-xcode-inputs.xcfilelist; build continues without incomplete lint diagnostics"
    return 1
  fi

  return 0
}

resolve_swiftlint() {
  local candidate

  if candidate="$(command -v swiftlint 2>/dev/null)" && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  for candidate in /opt/homebrew/bin/swiftlint /usr/local/bin/swiftlint; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

if [ "$#" -ne 0 ]; then
  warning "SwiftLint diagnostics runner takes no arguments; build continues without lint diagnostics"
  exit 0
fi

if ! script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; then
  warning "SwiftLint diagnostics could not locate the repository; build continues without lint diagnostics"
  exit 0
fi

if ! repo_root="$(cd -- "$script_dir/.." && pwd)"; then
  warning "SwiftLint diagnostics could not locate the repository; build continues without lint diagnostics"
  exit 0
fi

if [ "${SCRIPT_INPUT_FILE_LIST_COUNT:-0}" != "1" ] || [ -z "${SCRIPT_INPUT_FILE_LIST_0:-}" ]; then
  warning "SwiftLint diagnostics require one Xcode input file list; build continues without lint diagnostics"
  exit 0
fi

if ! check_input_parity "$SCRIPT_INPUT_FILE_LIST_0"; then
  exit 0
fi

if ! swiftlint_path="$(resolve_swiftlint)"; then
  warning "SwiftLint $EXPECTED_SWIFTLINT_VERSION was not found on PATH or in a common Homebrew location; build continues without lint diagnostics"
  exit 0
fi

if ! actual_version="$("$swiftlint_path" version)"; then
  warning "SwiftLint at $swiftlint_path could not report its version; build continues without lint diagnostics"
  exit 0
fi

if [ "$actual_version" != "$EXPECTED_SWIFTLINT_VERSION" ]; then
  warning "SwiftLint $EXPECTED_SWIFTLINT_VERSION is required, but found $actual_version at $swiftlint_path; build continues without lint diagnostics"
  exit 0
fi

if ! cd -- "$repo_root"; then
  warning "SwiftLint diagnostics could not enter $repo_root; build continues without lint diagnostics"
  exit 0
fi

lint_output_dir="${TARGET_TEMP_DIR:-${TMPDIR:-/tmp}}"
if ! lint_output="$(mktemp "$lint_output_dir/swiftlint-xcode.XXXXXX")"; then
  warning "SwiftLint diagnostics could not create a temporary output file; build continues without lint diagnostics"
  exit 0
fi
trap 'rm -f -- "$lint_output"' EXIT

"$swiftlint_path" lint \
  --config "$repo_root/.swiftlint.yml" \
  --lenient \
  --reporter xcode \
  --no-cache \
  --use-script-input-file-lists \
  >"$lint_output" 2>&1
lint_status=$?

if ! cat "$lint_output"; then
  warning "SwiftLint diagnostics output could not be replayed; build continues without complete lint diagnostics"
  exit 0
fi

unreadable_count="$(grep -c 'Could not read contents of' "$lint_output" || true)"
if [ "$unreadable_count" -ne 0 ]; then
  warning "SwiftLint could not read $unreadable_count sandboxed source file(s); update the Xcode input file list. Build continues without complete lint diagnostics"
  exit 0
fi

if [ "$lint_status" -ne 0 ]; then
  warning "SwiftLint diagnostics failed with exit status $lint_status; run scripts/swiftlint.sh for details. Build continues"
fi

exit 0