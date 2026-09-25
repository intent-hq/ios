#!/usr/bin/env python3
"""Fail closed unless both expected UI jobs and their matrix succeeded."""

import json
import sys


def main():
    if len(sys.argv) != 3 or sys.argv[1] != "success":
        raise ValueError("UI shard matrix did not succeed")
    attempt = int(sys.argv[2])
    if attempt < 1:
        raise ValueError("Invalid workflow attempt")
    pages = json.load(sys.stdin)
    if not isinstance(pages, list) or not pages:
        raise ValueError("Missing job pages")
    jobs = []
    for page in pages:
        if not isinstance(page, dict) or not isinstance(page.get("jobs"), list):
            raise ValueError("Invalid job page")
        if any(not isinstance(job, dict) for job in page["jobs"]):
            raise ValueError("Invalid job record")
        jobs.extend(page["jobs"])
    for shard in (1, 2):
        name = f"iOS UI Tests (shard {shard}/2)"
        matches = [job for job in jobs if job.get("name") == name]
        if not matches:
            raise ValueError(f"Missing {name}")
        if any(type(job.get("run_attempt")) is not int
               or not 1 <= job["run_attempt"] <= attempt for job in matches):
            raise ValueError(f"Invalid attempt for {name}")
        latest_attempt = max(job["run_attempt"] for job in matches)
        latest = [job for job in matches if job["run_attempt"] == latest_attempt]
        if len(latest) != 1:
            raise ValueError(f"Ambiguous records for {name}")
        if latest[0].get("status") != "completed" or latest[0].get("conclusion") != "success":
            raise ValueError(f"{name} did not complete successfully")
    print("Both UI shards completed successfully")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        print(f"UI test gate failed: {error}", file=sys.stderr)
        sys.exit(1)