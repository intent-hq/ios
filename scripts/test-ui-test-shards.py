#!/usr/bin/env python3
"""Exercise the production aggregate CLI with GitHub jobs API responses."""

import json
from pathlib import Path
import subprocess
import sys
import unittest


CHECK = Path(__file__).with_name("check-ui-test-shards.py")


def job(shard, conclusion="success", status="completed", attempt=1):
    return {"name": f"iOS UI Tests (shard {shard}/2)", "status": status,
            "conclusion": conclusion, "run_attempt": attempt}


class UIShardGateTests(unittest.TestCase):
    def check(self, pages, expected, result="success", attempt="1"):
        completed = subprocess.run(
            [sys.executable, str(CHECK), result, attempt],
            input=json.dumps(pages), capture_output=True, text=True, check=False)
        self.assertEqual(completed.returncode, expected, completed.stderr)

    def test_both_successful_across_pages_with_other_jobs(self):
        self.check([{"jobs": [job(2), {"name": "SwiftLint"}]},
                    {"jobs": [job(1)]}], 0)

    def test_every_non_successful_matrix_result_fails(self):
        for result in ("failure", "cancelled", "skipped", "", "unknown"):
            with self.subTest(result=result):
                self.check([{"jobs": [job(1), job(2)]}], 1, result=result)

    def test_each_missing_duplicate_incomplete_or_failed_shard_fails(self):
        for shard, other in ((1, 2), (2, 1)):
            with self.subTest(shard=shard):
                self.check([{"jobs": [job(other)]}], 1)
                self.check([{"jobs": [job(other), job(shard), job(shard)]}], 1)
                for state in ("queued", "in_progress", None):
                    self.check([{"jobs": [job(other), job(shard, status=state)]}], 1)
                for conclusion in ("failure", "cancelled", "skipped", "timed_out",
                                   "neutral", "action_required", "stale", None, ""):
                    self.check([{"jobs": [job(other), job(shard, conclusion)]}], 1)

    def test_malformed_or_missing_evidence_fails(self):
        for pages in (None, {}, [], [{}], [{"jobs": None}], [{"jobs": []}],
                      [{"jobs": [None]}]):
            with self.subTest(pages=pages):
                self.check(pages, 1)
        for attempt in (None, "1", 0, True, 2):
            with self.subTest(attempt=attempt):
                self.check([{"jobs": [job(1), job(2, attempt=attempt)]}], 1)
        for attempt in ("0", "invalid", ""):
            self.check([{"jobs": [job(1), job(2)]}], 1, attempt=attempt)
        completed = subprocess.run(
            [sys.executable, str(CHECK), "success", "1"],
            input="truncated JSON", capture_output=True, text=True, check=False)
        self.assertEqual(completed.returncode, 1)

    def test_partial_rerun_reuses_success_but_never_hides_new_failure(self):
        self.check([{"jobs": [job(1), job(2, "failure"), job(2, attempt=2)]}],
                   0, attempt="2")
        self.check([{"jobs": [job(1), job(2), job(2, "failure", attempt=2)]}],
                   1, attempt="2")


if __name__ == "__main__":
    unittest.main()