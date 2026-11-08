#!/usr/bin/env bash
# Runs chosen iOS test suites for one commit in a clean temporary checkout and
# writes a short pass/fail summary to a fixed file.
#
# Linux agents cannot compile Swift, so a helper agent on a Mac builds and
# tests iOS changes. This script is that agent's single command, and the
# summary file records everything needed to repeat the run, so an agent that
# lost its conversation can carry on from the file alone (intent-hq/ios#944).
#
# Usage:
#   scripts/run_commit_tests.sh [--repo <ios clone>] <commit> <selector>...
#
#   <commit>    A full commit SHA (preferred) or a branch or tag on origin.
#               It is fetched from origin when the clone does not have it.
#   <selector>  Target[/Suite[/test]] test identifiers, as for ONLY_TESTING in
#               scripts/xcodebuild.sh, e.g. 'IntentTests/AgentListPagingTests'.
#               'IntentTests' alone runs the whole unit suite. Single-quote
#               each one: zsh treats the '()' in a test name as a glob.
#               Any IntentUITests selector runs `test-ios`, otherwise
#               `test-ios-unit`.
#   --repo      The iOS clone to fetch into and clone from. Default: the clone
#               that holds this script. Its working tree is never modified.
#
# Steps:
#   1. Resolve <commit>, fetching it from origin when needed.
#   2. Clone it (git clone --shared, no network) into a new temporary
#      directory, so uncommitted files and old build products cannot leak in.
#   3. Run that commit's scripts/xcodebuild.sh in the foreground with
#      ONLY_TESTING, a private DERIVED_DATA_DIR and a RESULT_BUNDLE.
#   4. Read the result bundle (merging the wrapper's crash re-run bundle, if
#      any) and write the summary: verdict, exit code, per-suite counts,
#      failing tests with their first failure message, and a rerun command.
#   5. Delete the temporary checkout (KEEP_CHECKOUT=1 keeps it).
#
# Files, under INTENT_IOS_TEST_RUN_DIR (default
# ~/Library/Caches/intent-ios-test-run):
#   summary.md           The latest run. It says RUNNING (with this script's
#                        PID) while the run is in progress, then PASSED,
#                        FAILED, INTERRUPTED or ERROR. RUNNING with a PID that
#                        no longer exists means the run was killed: rerun it.
#   runs/<stamp>-<sha>.*/ Each run's xcodebuild.log and summary.md, plus the
#                        result bundle of a failed run. The newest 10 are kept.
#   tailcatkit/<tree>/   TailcatKit.xcframework builds keyed by the git tree
#                        of TailcatKit/, so a new checkout skips the slow Go
#                        build. Only complete builds the wrapper made in a
#                        clean checkout are cached. The newest 3 are kept.
#   stale-checkouts      Temporary checkouts a run could not delete; the next
#                        run deletes them.
#
# Xcode: an unset DEVELOPER_DIR is set to the Xcode the commit's CI selects
# (the newest non-beta /Applications match of its "Select Xcode" find
# pattern; XCODE_APPS_DIR replaces /Applications), because the Mac's default
# Xcode can differ and lack components the build needs. A DEVELOPER_DIR from
# the environment is used as given. The summary says which applied.
#
# These environment variables are passed to the wrapper and recorded in the
# rerun command: DEVELOPER_DIR (when the caller sets it), BUILD_CONFIGURATION,
# SIM_UDID, SPM_CLONE_DIR,
# TEST_CRASH_RETRY, SIM_LOCK_TIMEOUT, SIM_LOCK_DIR, TAILCATKIT_AUTOBUILD,
# KEEP_CHECKOUT, RUN_KILL_GRACE, INTENT_IOS_TEST_RUN_DIR and every TEST_RUNNER_*
# variable.
#
# Interrupts: a TERM, INT or HUP stops the whole test run (xcodebuild
# included) with TERM; a second signal, or RUN_KILL_GRACE seconds (default
# 60) without exiting, escalates to KILL. Before the checkout is deleted (on
# every exit), processes still naming it on their command line are stopped
# too: Xcode starts its compilers outside the wrapper's process group. A
# cleanup problem is noted in the summary and never changes the exit status.
#
# Exit status: the wrapper's (0 passed, 65 build or test failure, 80-84 see
# scripts/xcodebuild.sh), 2 for bad arguments, 1 when the commit cannot be
# resolved or checked out, 130 or 143 when interrupted.
#
# Run it in the foreground, never with `&` or nohup, and give the command a
# timeout long enough for a build plus the tests.
set -euo pipefail

RECORDED_ENV="DEVELOPER_DIR BUILD_CONFIGURATION SIM_UDID SPM_CLONE_DIR TEST_CRASH_RETRY SIM_LOCK_TIMEOUT SIM_LOCK_DIR TAILCATKIT_AUTOBUILD KEEP_CHECKOUT RUN_KILL_GRACE INTENT_IOS_TEST_RUN_DIR"
KEEP_RUNS=10
KEEP_TAILCATKIT=3

script_path=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
repo=$(cd "$(dirname "$0")/.." && pwd)

usage() {
  cat >&2 <<'EOF'
Usage: scripts/run_commit_tests.sh [--repo <ios clone>] <commit> <selector>...

Runs the selected tests of <commit> in a clean temporary checkout through
scripts/xcodebuild.sh and writes the result to
~/Library/Caches/intent-ios-test-run/summary.md (INTENT_IOS_TEST_RUN_DIR).

  <commit>    full SHA (preferred), or a branch or tag on origin
  <selector>  Target[/Suite[/test]], e.g. 'IntentTests/AgentListPagingTests';
              'IntentTests' runs the whole unit suite. Single-quote each one.

Example:
  scripts/run_commit_tests.sh 0123abcd... 'IntentTests/AgentListPagingTests'

Run it in the foreground. See the script header for details.
EOF
}

bad_usage() {
  echo "error: $*" >&2
  usage
  exit 2
}

# shell_quote <word>: the word in single quotes, safe to paste into bash or zsh.
shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo)
      [ $# -ge 2 ] || bad_usage "--repo needs a path"
      repo=$2
      shift 2 ;;
    --repo=*) repo=${1#--repo=}; shift ;;
    --) shift; break ;;
    -*) bad_usage "unknown option: $1" ;;
    *) break ;;
  esac
done
[ $# -ge 2 ] || bad_usage "give a commit and at least one test selector"
rev=$1
shift

subcommand=test-ios-unit
selectors=()
set -f
for arg in "$@"; do
  for selector in $arg; do
    case "$selector" in
      IntentTests|IntentTests/?*) ;;
      IntentUITests|IntentUITests/?*) subcommand=test-ios ;;
      *) set +f; bad_usage "selector '$selector' is not IntentTests[/Suite[/test]] or IntentUITests[/Suite[/test]] (selectors are test identifiers, not file names)" ;;
    esac
    selectors+=("$selector")
  done
done
set +f
[ ${#selectors[@]} -gt 0 ] || bad_usage "give at least one test selector"

[ -d "$repo" ] || bad_usage "--repo $repo is not a directory"
repo=$(cd "$repo" && pwd)
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || bad_usage "$repo is not a git clone"

root=${INTENT_IOS_TEST_RUN_DIR:-$HOME/Library/Caches/intent-ios-test-run}
mkdir -p "$root/runs" "$root/tailcatkit"
root=$(cd "$root" && pwd)
summary=$root/summary.md

# set_rerun <commit>: the rerun commands - recorded environment, then this
# script with --repo (rerun) or the relative path for any iOS clone
# (rerun_anywhere), the commit and every selector, each single-quoted. It is
# set again with the resolved SHA, so replaying never follows a moved branch.
set_rerun() {
  local name value selector args env_prefix=''
  for name in $RECORDED_ENV $(env | sed -n 's/^\(TEST_RUNNER_[A-Za-z0-9_]*\)=.*/\1/p' | sort -u); do
    if value=$(printenv "$name"); then
      env_prefix="$env_prefix$name=$(shell_quote "$value") "
    fi
  done
  args=$(shell_quote "$1")
  for selector in "${selectors[@]}"; do
    args="$args $(shell_quote "$selector")"
  done
  rerun="$env_prefix$(shell_quote "$script_path") --repo $(shell_quote "$repo") $args"
  rerun_anywhere="${env_prefix}scripts/run_commit_tests.sh $args"
}
set_rerun "$rev"

state=RUNNING
status=
sha=
subject=
run_dir=
log=
bundle=
work=
child=
interrupted=
error_message=
tailcat_note="not checked yet"
report=
cleanup_note=
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
started_epoch=$(date +%s)
finished_at=
duration=
xcode_note="DEVELOPER_DIR from the environment"
[ -n "${DEVELOPER_DIR:-}" ] || xcode_note="the default Xcode"
# The chosen Xcode applies to the wrapper only: on macOS /usr/bin/git is an
# Xcode shim that also follows DEVELOPER_DIR.
selected_developer_dir=${DEVELOPER_DIR:-}
read_xcode_version() {
  xcode_version=$( {
    if [ -n "$selected_developer_dir" ]; then
      DEVELOPER_DIR=$selected_developer_dir xcodebuild -version 2>/dev/null
    else
      xcodebuild -version 2>/dev/null
    fi || true
  } | sed -n 1p)
  [ -n "$xcode_version" ] || xcode_version="unknown (xcodebuild -version failed)"
}
read_xcode_version
host=$(hostname 2>/dev/null || echo unknown)

exit_meaning() {
  case "$1" in
    0) echo "passed" ;;
    65) echo "build or test failure" ;;
    80) echo "test process crashed and the re-run did not recover" ;;
    81) echo "timed out waiting for the simulator lock" ;;
    82) echo "a selector matched or ran no test" ;;
    83) echo "the test selection could not be verified" ;;
    84) echo "the app could not launch on the simulator" ;;
    130|143) echo "interrupted" ;;
    *) echo "see scripts/xcodebuild.sh" ;;
  esac
}

# write_summary: writes $summary (atomically) and a copy in the run directory.
# $report, when present, holds the per-suite table and failure lists.
write_summary() {
  local tmp heading
  tmp=$(mktemp "$root/.summary.XXXXXX")
  case "$state" in
    RUNNING) heading="RUNNING" ;;
    PASSED) heading="PASSED" ;;
    FAILED) heading="FAILED (exit $status: $(exit_meaning "$status"))" ;;
    INTERRUPTED) heading="INTERRUPTED (exit $status)" ;;
    *) heading="ERROR (exit $status)" ;;
  esac
  {
    echo "# iOS test run: $heading"
    echo
    if [ -n "$sha" ]; then
      echo "- Commit: $sha ($subject)"
    else
      echo "- Commit: $rev (not resolved)"
    fi
    echo "- Tests: scripts/xcodebuild.sh $subcommand with ONLY_TESTING='${selectors[*]}'"
    if [ -n "$finished_at" ]; then
      echo "- Time: $started_at to $finished_at ($duration)"
    else
      echo "- Started: $started_at"
    fi
    echo "- Host: $host, $xcode_version (selected by $xcode_note)"
    echo "- TailcatKit: $tailcat_note"
    [ -z "$log" ] || echo "- Log: $log"
    if [ -n "$bundle" ] && [ -e "$bundle" ]; then
      echo "- Result bundle: $bundle"
    fi
    echo "- Rerun: $rerun"
    echo "- Rerun from any iOS clone: $rerun_anywhere"
    if [ "$state" = RUNNING ]; then
      echo "- PID: $$ (if this process no longer exists, the run was killed; rerun it)"
    fi
    if [ -n "$error_message" ]; then
      echo
      echo "Error: $error_message"
    fi
    if [ -n "$cleanup_note" ]; then
      echo
      echo "Note: $cleanup_note"
    fi
    if [ -n "$report" ] && [ -s "$report" ]; then
      echo
      cat "$report"
    fi
  } > "$tmp"
  mv -f "$tmp" "$summary"
  [ -z "$run_dir" ] || [ ! -d "$run_dir" ] || cp "$summary" "$run_dir/summary.md"
}

finish_time() {
  local elapsed
  finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  elapsed=$(( $(date +%s) - started_epoch ))
  duration="$((elapsed / 60))m $((elapsed % 60))s"
}

# stop_strays: stops processes whose command line names this run's private
# directory. Xcode's build service starts swift-frontend outside the wrapper's
# process group, so after an interrupt compilers can keep writing into the
# checkout (seen on Xcode 27.2). Nothing else uses this directory. It matches
# the directory's unique name, not its full path: compilers print a normalized
# path (one slash, /var not /private/var). TERM first, KILL after about 5s.
stop_strays() {
  local pattern pids tries=0
  pattern="intent-ios-run\\.$(printf '%s' "${work##*/intent-ios-run.}" | sed 's/[][\.*^$+?(){}|]/\\&/g')/"
  while pids=$(pgrep -f -- "$pattern" 2>/dev/null | grep -vx "$$" || true); [ -n "$pids" ]; do
    if [ "$tries" -ge 20 ]; then
      echo "warning: processes still using $work after KILL: $(echo $pids)" >&2
      return 0
    elif [ "$tries" -ge 10 ]; then
      # shellcheck disable=SC2086
      kill -KILL $pids 2>/dev/null || true
    else
      # shellcheck disable=SC2086
      kill -TERM $pids 2>/dev/null || true
    fi
    sleep 0.5
    tries=$((tries + 1))
  done
}

# remove_work: deletes this run's checkout and derived data after stopping
# stray processes. If it still cannot be deleted, its path is listed in
# $root/stale-checkouts for the next run to delete, and $cleanup_note says so.
remove_work() {
  local tries=0
  [ -n "$work" ] && [ -d "$work" ] || return 0
  stop_strays
  if [ "${KEEP_CHECKOUT:-0}" = 1 ]; then
    echo "notice: KEEP_CHECKOUT=1 keeps the checkout at $work/ios" >&2
    work=
    return 0
  fi
  # A compiler that starts during the delete can recreate folders afterwards,
  # so the delete only counts once a final sweep leaves nothing behind.
  until rm -rf -- "$work" 2>/dev/null && stop_strays && [ ! -e "$work" ]; do
    tries=$((tries + 1))
    if [ "$tries" -ge 3 ]; then
      echo "$work" >> "$root/stale-checkouts"
      cleanup_note="the temporary checkout $work could not be deleted (a process was still using it); the next run deletes it"
      echo "warning: $cleanup_note" >&2
      break
    fi
    sleep 1
    stop_strays
  done
  work=
}

# purge_stale_checkouts: deletes checkouts earlier runs could not delete.
purge_stale_checkouts() {
  local list=$root/stale-checkouts old
  [ -f "$list" ] || return 0
  mv -f "$list" "$list.$$"
  while IFS= read -r old; do
    case "$old" in
      */intent-ios-run.*) rm -rf -- "$old" 2>/dev/null || echo "$old" >> "$list" ;;
    esac
  done < "$list.$$"
  rm -f "$list.$$"
}

on_exit() {
  local code=$?
  set +e
  if [ "$state" = RUNNING ]; then
    # An unexpected failure (set -e) after the RUNNING summary was written.
    state=ERROR
    status=$code
    [ "$status" -ne 0 ] || status=1
    [ -n "$error_message" ] || error_message="run_commit_tests.sh stopped unexpectedly (exit $code); see the messages above"
    remove_work
    finish_time
    write_summary
  fi
  # Cleanup problems are reported in the summary; they never change the
  # exit status.
  remove_work
  exit "$code"
}
trap on_exit EXIT

# cache_tailcatkit: keeps a TailcatKit build the wrapper made for later
# checkouts, also in an interrupted run. build_xcframework.sh copies
# LICENSE.tailcat in last, so a build without it is incomplete and not kept.
cache_tailcatkit() {
  local staging
  if [ -n "${tailcat_cache:-}" ] && [ -f "$tailcat_dest/LICENSE.tailcat" ] && [ ! -d "$tailcat_cache" ]; then
    staging=$(mktemp -d "$root/tailcatkit/.staging.XXXXXX")
    if cp -R "$tailcat_dest" "$staging/TailcatKit.xcframework" \
        && mv "$staging" "$root/tailcatkit/$tailcat_tree" 2>/dev/null; then
      tailcat_note="$tailcat_note; cached for later runs"
    else
      rm -rf -- "$staging"
    fi
  fi
}

finish_interrupted() {
  cache_tailcatkit
  remove_work
  state=INTERRUPTED
  status=$1
  error_message="the run was stopped by a signal before it finished; rerun it"
  finish_time
  write_summary
  echo "Interrupted. Summary: $summary" >&2
  exit "$status"
}

# on_signal: the first signal sends TERM to the wrapper's whole process group
# (the wrapper waits on a foreground xcodebuild pipeline, so signalling only
# the wrapper would not stop the run); a repeated signal sends KILL.
on_signal() {
  if [ -z "$child" ]; then
    interrupted=$1
    finish_interrupted "$1"
  elif [ -z "$interrupted" ]; then
    interrupted=$1
    kill -TERM -- "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null || true
  else
    kill -KILL -- "-$child" 2>/dev/null || kill -KILL "$child" 2>/dev/null || true
  fi
}

# wait_for_child_exit: after an interrupt, waits until the wrapper's process
# group is gone (KILL after RUN_KILL_GRACE seconds, default 60), so the
# checkout is never deleted under a running xcodebuild.
wait_for_child_exit() {
  local waited=0
  while kill -0 -- "-$child" 2>/dev/null || kill -0 "$child" 2>/dev/null; do
    if [ "$waited" -ge "${RUN_KILL_GRACE:-60}" ]; then
      kill -KILL -- "-$child" 2>/dev/null || kill -KILL "$child" 2>/dev/null || true
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$child" 2>/dev/null || true
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

fail_early() {
  remove_work
  state=ERROR
  status=$1
  error_message=$2
  finish_time
  write_summary
  echo "error: $2" >&2
  echo "Summary: $summary" >&2
  exit "$status"
}

purge_stale_checkouts
write_summary

# 1. Resolve the commit.
fetch_err=$(mktemp "${TMPDIR:-/tmp}/run-commit-tests-fetch.XXXXXX")
fetch_ref=refs/run-commit-tests/$$
if printf '%s' "$rev" | grep -Eq '^[0-9a-f]{40}$' && git -C "$repo" cat-file -e "$rev^{commit}" 2>/dev/null; then
  sha=$rev
elif git -C "$repo" fetch --quiet --no-tags origin "+$rev:$fetch_ref" 2>"$fetch_err"; then
  # A private ref, not FETCH_HEAD, so concurrent runs cannot swap commits.
  sha=$(git -C "$repo" rev-parse --verify --quiet "$fetch_ref^{commit}")
  git -C "$repo" update-ref -d "$fetch_ref"
elif sha=$(git -C "$repo" rev-parse --verify --quiet "$rev^{commit}"); then
  echo "warning: could not fetch $rev from origin; using the local $rev" >&2
else
  message="could not resolve $rev in $repo or fetch it from origin: $(tr '\n' ' ' < "$fetch_err")"
  rm -f "$fetch_err"
  fail_early 1 "$message"
fi
rm -f "$fetch_err"
set_rerun "$sha"
subject=$(git -C "$repo" log -1 --format=%s "$sha")
git -C "$repo" cat-file -e "$sha:scripts/xcodebuild.sh" 2>/dev/null \
  || fail_early 1 "commit $sha has no scripts/xcodebuild.sh"

# Use the Xcode this commit's CI selects unless the caller chose one.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  xcode_pattern=$( { git -C "$repo" show "$sha:.github/workflows/ci.yml" 2>/dev/null || true; } |
    sed -n "s/.*find \/Applications .*-name '\(Xcode[^']*\.app\)'.*/\1/p" | sed -n 1p)
  if [ -z "$xcode_pattern" ]; then
    xcode_note="the default Xcode (this commit's CI has no Select Xcode pattern)"
  else
    ci_xcode=$(find "${XCODE_APPS_DIR:-/Applications}" -maxdepth 1 -type d -name "$xcode_pattern" \
      ! -iname '*beta*' ! -iname '*candidate*' 2>/dev/null | sort -V | tail -n 1)
    if [ -n "$ci_xcode" ]; then
      selected_developer_dir=$ci_xcode/Contents/Developer
      xcode_note="CI's Select Xcode pattern $xcode_pattern"
    else
      xcode_note="the default Xcode (nothing matches CI's $xcode_pattern)"
    fi
  fi
  read_xcode_version
fi

run_dir=$(mktemp -d "$root/runs/$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%s' "$sha" | cut -c1-12).XXXXXX")
log=$run_dir/xcodebuild.log
bundle=$run_dir/Results.xcresult
retry_bundle=$run_dir/Results-retry.xcresult

# 2. Check out a clean copy.
# No double slash when TMPDIR ends in "/" (it does on macOS).
tmp_base=${TMPDIR:-/tmp}
work=$(mktemp -d "${tmp_base%/}/intent-ios-run.XXXXXX")
checkout=$work/ios
git clone --quiet --shared --no-checkout "$repo" "$checkout" \
  || fail_early 1 "could not clone $repo into $checkout"
git -C "$checkout" -c advice.detachedHead=false checkout --quiet --detach "$sha" \
  || fail_early 1 "could not check out $sha in $checkout"

# Reuse a TailcatKit.xcframework built from the same TailcatKit/ sources.
tailcat_tree=$(git -C "$repo" rev-parse --verify --quiet "$sha:TailcatKit" || true)
tailcat_dest=$checkout/TailcatKit/build/TailcatKit.xcframework
tailcat_cache=
if [ -z "$tailcat_tree" ]; then
  tailcat_note="this commit has no TailcatKit/ directory"
else
  tailcat_cache=$root/tailcatkit/$tailcat_tree/TailcatKit.xcframework
  if [ -d "$tailcat_cache" ]; then
    mkdir -p "$(dirname "$tailcat_dest")"
    cp -R "$tailcat_cache" "$tailcat_dest"
    touch "$root/tailcatkit/$tailcat_tree"
    tailcat_note="reused the cached build for TailcatKit tree $(printf '%s' "$tailcat_tree" | cut -c1-12)"
    tailcat_cache=
  else
    tailcat_note="no matching build cached; the wrapper builds it (needs Go)"
  fi
fi

# 3. Run the commit's wrapper, in its own process group (set -m) so an
# interrupt can reach xcodebuild itself.
echo "Running scripts/xcodebuild.sh $subcommand for $sha ($subject)"
echo "  ONLY_TESTING='${selectors[*]}'"
echo "  log: $log"
echo "  summary: $summary"
write_summary
set -m
(
  cd "$checkout"
  unset RESULT_BUNDLE ONLY_TESTING DERIVED_DATA_DIR UI_TEST_SHARD UI_TEST_SHARD_PLAN_PATH ONLY_TESTING_IDENTITIES_PATH
  export ONLY_TESTING="${selectors[*]}"
  export RESULT_BUNDLE="$bundle"
  export DERIVED_DATA_DIR="$work/DerivedData"
  [ -z "$selected_developer_dir" ] || export DEVELOPER_DIR="$selected_developer_dir"
  exec scripts/xcodebuild.sh "$subcommand"
) > "$log" 2>&1 < /dev/null &
child=$!
set +m
status=0
wait "$child" || status=$?
if [ -n "$interrupted" ]; then
  # Let the wrapper stop xcodebuild and release the simulator first.
  wait_for_child_exit
  child=
  finish_interrupted "$interrupted"
fi
child=

cache_tailcatkit

# 4. Summarize the results.
results=
retry_results=
if [ -d "$bundle" ]; then
  results=$work/results.json
  xcrun xcresulttool get test-results tests --path "$bundle" > "$results" 2>>"$log" || results=
fi
if [ -d "$retry_bundle" ]; then
  retry_results=$work/retry-results.json
  xcrun xcresulttool get test-results tests --path "$retry_bundle" > "$retry_results" 2>>"$log" || retry_results=
fi
report=$run_dir/report.md
python3 - "$status" "$log" "$report" "$results" "$retry_results" <<'PY' || echo "warning: could not summarize the results; read the log" >&2
import json
import sys

status, log_path, out_path, results_path, retry_path = sys.argv[1:6]
status = int(status)
lines = []


def load(path):
    if not path:
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def first_failure(node):
    # Parameterized Swift Testing cases keep the message under an argument node.
    for child in node.get("children") or []:
        if not isinstance(child, dict):
            continue
        if child.get("nodeType") == "Failure Message":
            return child.get("name", "")
        found = first_failure(child)
        if found:
            return found
    return ""


def walk(node, target, suites, out):
    if not isinstance(node, dict):
        return
    kind = node.get("nodeType", "")
    name = node.get("name", "")
    if kind in ("Unit test bundle", "UI test bundle"):
        target = name
    if kind == "Test Case":
        ident = node.get("nodeIdentifier") or name
        if "/" in ident:
            suite, test = ident.rsplit("/", 1)
        else:
            suite, test = "/".join(suites) or "?", ident
        out[(target or "?", suite, test)] = (node.get("result", ""), first_failure(node))
        return
    if kind == "Test Suite":
        suites = suites + [name]
    for child in node.get("children") or []:
        walk(child, target, suites, out)


def cases(doc):
    out = {}
    for node in (doc or {}).get("testNodes") or []:
        walk(node, None, [], out)
    return out


primary = load(results_path)
retry = load(retry_path)
tests = cases(primary)
retried = cases(retry)
tests.update(retried)

if tests:
    suites = {}
    failing = []
    for (target, suite, test), (result, message) in tests.items():
        row = suites.setdefault(target + "/" + suite, [0, 0, 0, 0])
        if result == "Skipped":
            row[3] += 1
            continue
        row[0] += 1
        if result in ("Passed", "Expected Failure"):
            row[1] += 1
        else:
            row[2] += 1
            label = "" if result == "Failed" else " [result: %s]" % (result or "missing")
            failing.append((target + "/" + suite + "/" + test, label, message))
    lines.append("| Suite | Executed | Passed | Failed | Skipped |")
    lines.append("| --- | ---: | ---: | ---: | ---: |")
    total = [0, 0, 0, 0]
    for name, row in suites.items():
        lines.append("| %s | %d | %d | %d | %d |" % ((name,) + tuple(row)))
        total = [a + b for a, b in zip(total, row)]
    lines.append("| **Total** | %d | %d | %d | %d |" % tuple(total))
    if retried:
        lines.append("")
        lines.append("A test process crashed; the wrapper re-ran the interrupted suites and these counts use the re-run's results for them.")
    if failing:
        lines.append("")
        lines.append("## Failing tests")
        lines.append("")
        for ident, label, message in failing[:50]:
            message = " ".join(message.split())
            if len(message) > 300:
                message = message[:297] + "..."
            lines.append("- `%s`%s%s" % (ident, label, (": " + message) if message else ""))
        if len(failing) > 50:
            lines.append("- ... and %d more (see the log)" % (len(failing) - 50))
elif status != 0:
    lines.append("No test results: the build or the test setup failed before any test ran.")
else:
    lines.append("No test results could be read from the result bundle.")

if status != 0:
    errors = []
    try:
        with open(log_path, errors="replace") as f:
            for line in f:
                line = line.rstrip("\n")
                if ("error:" in line or "** BUILD FAILED **" in line) and line not in errors:
                    errors.append(line)
    except OSError:
        pass
    if errors:
        lines.append("")
        lines.append("## Errors from the log")
        lines.append("")
        lines.append("```text")
        for line in errors[:20]:
            lines.append(line[:400])
        if len(errors) > 20:
            lines.append("... %d more error lines in the log" % (len(errors) - 20))
        lines.append("```")

with open(out_path, "w") as f:
    f.write("\n".join(lines) + "\n")
PY

if [ "$status" -eq 0 ]; then
  state=PASSED
  rm -rf -- "$bundle" "$retry_bundle"
else
  state=FAILED
fi
remove_work
finish_time
write_summary

# Keep the newest runs and TailcatKit builds.
ls -1 "$root/runs" | sort -r | sed "1,${KEEP_RUNS}d" | while IFS= read -r old; do
  rm -rf -- "${root:?}/runs/$old"
done
ls -1t "$root/tailcatkit" | sed "1,${KEEP_TAILCATKIT}d" | while IFS= read -r old; do
  rm -rf -- "${root:?}/tailcatkit/$old"
done

echo
cat "$summary"
exit "$status"
