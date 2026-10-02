#!/usr/bin/env python3
"""Print TestFlight notes for BASE..HEAD in the current Git repository.

Usage: python3 scripts/release_notes.py BASE HEAD
       python3 scripts/release_notes.py --last-24-hours HEAD
Exit codes: 0 = notes, 3 = no commits, 1 = Git error, 2 = usage error.
First-parent history represents each merged PR once. Maintenance-only ranges
still produce notes; chore/ci/test commits are otherwise omitted. Truncation
keeps complete entries and counts omitted entries, not maintenance commits.
Without a release marker, --last-24-hours uses HEAD's committer time, not now.
"""

import argparse
import re
import subprocess
import sys


LIMIT = 4000
GROUPS = ("Features", "Fixes", "Performance", "Other")
TYPES = {"feat": "Features", "fix": "Fixes", "perf": "Performance"}
CONVENTIONAL = re.compile(r"^([a-z]+)(?:\([^)]*\))?!?:\s*(.+)$", re.IGNORECASE)
MERGE_PR = re.compile(r"^Merge pull request #(\d+)\b")


def git(*arguments):
    return subprocess.run(
        ["git", *arguments], check=True, capture_output=True,
        text=True, encoding="utf-8", errors="replace",
    ).stdout


def history(base, head):
    # Resolve refs separately so untrusted input cannot become git-log options
    # or introduce extra revisions/path filters into the requested range.
    head_sha = git("rev-parse", "--verify", "--end-of-options", head + "^{commit}").strip()
    if base is None:
        revision = head_sha
        end = int(git("show", "-s", "--format=%ct", head_sha, "--").strip())
    else:
        base_sha = git("rev-parse", "--verify", "--end-of-options", base + "^{commit}").strip()
        revision = f"{base_sha}..{head_sha}"
    output = git(
        "log", "--first-parent", "--reverse", "--topo-order", "--format=%ct%x00%s%x00%b", "-z",
        revision, "--",
    )
    fields = output.split("\0")
    commits = zip(fields[0:-1:3], fields[1:-1:3], fields[2:-1:3])
    # Filter every first-parent commit: timestamps can be out of order, so
    # stopping traversal at the first older commit would lose valid changes.
    return [(subject, body) for timestamp, subject, body in commits
            if base is not None or end - 86400 <= int(timestamp) <= end]


def entry(subject, body):
    merge = MERGE_PR.match(subject)
    if merge:
        # GitHub's merge message stores the PR title in its first body line.
        subject = body.strip().splitlines()[0] if body.strip() else subject
        reference = f"(#{merge[1]})"
        if reference not in subject:
            subject += " " + reference
    subject = " ".join(subject.split())
    conventional = CONVENTIONAL.match(subject)
    if not conventional:
        return "Other", subject
    kind, title = conventional.groups()
    if kind.lower() in {"chore", "ci", "test"}:
        return None
    return TYPES.get(kind.lower(), "Other"), title


def render(entries):
    output = ""
    previous = None
    for group, title in entries:
        if group != previous:
            output += ("\n" if output else "") + group + "\n"
        output += f"- {title}\n"
        previous = group
    return output


def notes(commits):
    grouped = {group: [] for group in GROUPS}
    for subject, body in commits:
        item = entry(subject, body)
        if item:
            grouped[item[0]].append(item)
    entries = [item for group in GROUPS for item in grouped[group]]
    if not entries:
        return f"Other\n- Internal maintenance updates ({len(commits)} commits).\n"
    full = render(entries)
    if len(full) <= LIMIT:
        return full

    # Reserve space for the exact omitted count, including the final newline.
    # An oversized entry is omitted whole, so PR numbers never get cut in half.
    output = f"…and {len(entries)} more\n"
    for count in range(1, len(entries)):
        candidate = render(entries[:count]) + f"\n…and {len(entries) - count} more\n"
        if len(candidate) > LIMIT:
            break
        output = candidate
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--last-24-hours", action="store_true", help="bootstrap from HEAD's last 24 hours")
    parser.add_argument("base", nargs="?", help="exclusive base commit or ref")
    parser.add_argument("head", help="inclusive head commit or ref")
    args = parser.parse_args()
    if args.last_24_hours != (args.base is None):
        parser.error("provide either BASE HEAD or --last-24-hours HEAD")
    try:
        commits = history(args.base, args.head)
    except (OSError, subprocess.CalledProcessError):
        print("Could not read Git history; check the repository and both commit refs.", file=sys.stderr)
        return 1
    if not commits:
        print("No changes.")
        return 3
    sys.stdout.write(notes(commits))
    return 0


if __name__ == "__main__":
    sys.exit(main())