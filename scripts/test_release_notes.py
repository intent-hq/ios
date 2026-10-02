#!/usr/bin/env python3
"""Exercise the release-note CLI using real, disposable Git histories."""

import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().with_name("release_notes.py")


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.env = os.environ.copy()
        self.env.update(
            GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
            GIT_AUTHOR_NAME="Release Notes Test", GIT_AUTHOR_EMAIL="test@example.invalid",
            GIT_COMMITTER_NAME="Release Notes Test", GIT_COMMITTER_EMAIL="test@example.invalid",
        )
        self.git("init", "-q", "-b", "main")
        self.commit("feat: excluded base commit")
        self.base = self.git("rev-parse", "HEAD").strip()

    def git(self, *args):
        return subprocess.run(
            ["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=" + os.devnull, *args],
            cwd=self.root, env=self.env, check=True, capture_output=True,
            text=True, encoding="utf-8",
        ).stdout

    def commit(self, message):
        self.git("commit", "--allow-empty", "-q", "-m", message)

    def generate(self, base=None, head="HEAD"):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--", base or self.base, head],
            cwd=self.root, env=self.env, capture_output=True, text=True, encoding="utf-8",
        )

    def test_grouping_and_maintenance_filtering(self):
        for message in [
            "fix(ui): restore menus (#10)",
            "feat(sync)!: add shared workspaces (#11)",
            "perf: reuse date parsers (#12)",
            "docs: explain reconnecting",
            "Support older servers",
            "feat: add quick actions (#13)",
            "chore: bump build number (#14)",
            "ci(ios): cache dependencies (#15)",
            "test: cover reconnection (#16)",
        ]:
            self.commit(message)
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout,
                         "Features\n- add shared workspaces (#11)\n- add quick actions (#13)\n"
                         "\nFixes\n- restore menus (#10)\n"
                         "\nPerformance\n- reuse date parsers (#12)\n"
                         "\nOther\n- explain reconnecting\n- Support older servers\n")

    def test_pr_numbers_from_squash_and_merge_commits(self):
        self.commit("fix: use native menu (#600) (#659)")
        self.git("checkout", "-q", "-b", "feature")
        self.commit("feat: internal implementation detail")
        self.commit("fix: internal follow-up")
        self.git("checkout", "-q", "main")
        self.git("merge", "--no-ff", "-m",
                 "Merge pull request #700 from example/feature\n\nfeat: share notes (#699)", "feature")
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Features\n- share notes (#699) (#700)\n"
                         "\nFixes\n- use native menu (#600) (#659)\n")

    def test_requested_range_excludes_base_and_later_commits(self):
        self.git("tag", "previous-alpha")
        self.commit("fix: included change (#20)")
        self.git("tag", "next-alpha")
        self.commit("feat: not in this build")
        result = self.generate(base="previous-alpha", head="next-alpha")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Fixes\n- included change (#20)\n")

    def test_truncation_counts_omitted_entries_and_keeps_complete_pr_numbers(self):
        titles = []
        for index in range(60):
            title = f"Change {index}: " + "é" * 80 + f" (#{1000 + index})"
            titles.append(title)
            kind = "feat" if index < 30 else "fix"
            self.commit(f"{kind}: {title}")
        for kind in ["chore", "ci", "test"]:
            self.commit(f"{kind}: ignored maintenance")
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLessEqual(len(result.stdout), 4000)
        self.assertGreater(len(result.stdout), 3800)
        marker = re.search(r"\n…and (\d+) more\n$", result.stdout)
        self.assertIsNotNone(marker)
        bullets = [line for line in result.stdout.splitlines() if line.startswith("- ")]
        self.assertEqual(len(bullets) + int(marker[1]), 60)
        self.assertEqual(bullets, ["- " + title for title in titles[:len(bullets)]])
        self.assertIn("\nFixes\n", result.stdout)

    def test_exact_limit_and_single_oversized_entry(self):
        for size, expected in [(3991, "Fixes\n- " + "x" * 3991 + "\n"), (3992, "…and 1 more\n")]:
            with self.subTest(title_length=size):
                base = self.git("rev-parse", "HEAD").strip()
                self.commit("fix: " + "x" * size)
                result = self.generate(base=base)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)
                self.assertLessEqual(len(result.stdout), 4000)

    def test_empty_range_has_distinct_skip_status(self):
        result = self.generate()
        self.assertEqual(result.returncode, 3)
        self.assertEqual(result.stdout, "No changes.\n")
        self.assertEqual(result.stderr, "")

    def test_maintenance_only_range_is_not_empty(self):
        for kind in ["chore", "ci", "test"]:
            self.commit(f"{kind}: internal update")
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Other\n- Internal maintenance updates (3 commits).\n")

    def test_invalid_refs_fail_instead_of_skipping_or_expanding_the_range(self):
        self.commit("fix: visible change")
        for base, head in [("missing", "HEAD"), (self.base, "missing"), ("--all", "HEAD")]:
            with self.subTest(base=base, head=head):
                result = self.generate(base=base, head=head)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("Could not read Git history", result.stderr)


if __name__ == "__main__":
    unittest.main()