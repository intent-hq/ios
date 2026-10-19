#!/usr/bin/env python3
"""Functional smoke-shard selection tests using small temporary fixtures."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from ui_smoke_tests import load_shards


SCRIPT = Path(__file__).with_name("ui_smoke_tests.py")
FIRST = "IntentUITests/FirstUITests/testOne"
SECOND = "IntentUITests/SecondUITests/testTwo"
THIRD = "IntentUITests/FirstUITests/testThree"
VALID = f"{FIRST} # shard: 1\n{SECOND} # shard: 2\n"


class SmokeShardTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.path = self.root / "ui-smoke-tests.txt"

    def load(self, content):
        self.path.write_text(content, encoding="utf-8")
        return load_shards(self.path)

    def cli(self, *args):
        script = self.root / SCRIPT.name
        shutil.copyfile(SCRIPT, script)
        return subprocess.run(
            [sys.executable, str(script), *args],
            cwd=self.root.parent,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_partition_preserves_exact_selectors_and_input_order(self):
        content = (
            f"\n# A standalone comment\n  {THIRD}  # shard: 1\n"
            f"{SECOND}\t# shard: 2\n\n  # Another comment\n{FIRST} # shard: 1\n"
        )
        self.assertEqual(self.load(content), {1: [THIRD, FIRST], 2: [SECOND]})

    def test_missing_and_invalid_annotations_are_rejected(self):
        for annotation in ("", "#", "# smoke", "# shard 1", "# shard: one",
                           "# shard: 0", "# shard: 3", "# shard: 01", "# shard: 1 extra",
                           "# shard: 1 # shard: 2"):
            with self.subTest(annotation=annotation), self.assertRaises(ValueError):
                self.load(VALID + f"{THIRD} {annotation}\n")

    def test_malformed_or_broad_selectors_are_rejected(self):
        for selector in (
            "IntentUITests", "IntentUITests/FirstUITests", "IntentTests/First/testOne",
            "IntentUITests//testOne", "IntentUITests/FirstUITests/",
            "IntentUITests/FirstUITests/one", "IntentUITests/FirstUITests/testOne/extra",
            "IntentUITests/FirstUITests/test*", "IntentUITests/FirstUITests/testOne()",
            "IntentUITests/FirstUITests/test One", "-only-testing:" + THIRD,
        ):
            with self.subTest(selector=selector), self.assertRaises(ValueError):
                self.load(VALID + f"{selector} # shard: 1\n")

    def test_duplicate_in_either_shard_is_rejected(self):
        for shard in (1, 2):
            with self.subTest(shard=shard), self.assertRaisesRegex(ValueError, "duplicate"):
                self.load(VALID + f"{FIRST} # shard: {shard}\n")

    def test_empty_or_missing_shard_is_rejected(self):
        for content in ("", "\n# Comment only\n", f"{FIRST} # shard: 1\n",
                        f"{SECOND} # shard: 2\n", f"# shard: 2\n{FIRST} # shard: 1\n"):
            with self.subTest(content=content), self.assertRaisesRegex(ValueError, "no selectors"):
                self.load(content)

    def test_cli_reads_adjacent_file_and_prints_only_the_requested_shard(self):
        self.path.write_text(VALID + f"{THIRD} # shard: 1\n", encoding="utf-8")
        for shard, expected in (("1", f"{FIRST} {THIRD}\n"), ("2", f"{SECOND}\n")):
            with self.subTest(shard=shard):
                result = self.cli("--shard", shard)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)
                self.assertEqual(result.stderr, "")

    def test_cli_rejects_missing_or_unknown_shard_without_output(self):
        self.path.write_text(VALID, encoding="utf-8")
        for args in ((), ("--shard", "0"), ("--shard", "3"), ("--shard", "all")):
            with self.subTest(args=args):
                result = self.cli(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("error:", result.stderr)

    def test_cli_validates_entire_file_before_printing_any_selection(self):
        for content in (VALID + f"{THIRD}\n", VALID + f"{FIRST} # shard: 2\n",
                        f"{FIRST} # shard: 1\n", "IntentUITests # shard: 2\n"):
            with self.subTest(content=content):
                self.path.write_text(content, encoding="utf-8")
                result = self.cli("--shard", "1")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("error:", result.stderr)

    def test_cli_missing_file_fails_without_output(self):
        result = self.cli("--shard", "1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("error:", result.stderr)


if __name__ == "__main__":
    unittest.main()
