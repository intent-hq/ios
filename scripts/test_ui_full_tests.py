#!/usr/bin/env python3
"""Full UI partition and cross-lane evidence regressions; no Xcode required."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from ui_full_tests import inventory, partition, verify_plans


SCRIPT = Path(__file__).with_name("ui_full_tests.py")
TESTS = [f"IntentUITests/{suite}/test{number}" for suite in ("Long", "Middle", "New") for number in (1, 2)]
DISABLED = ["IntentUITests/AppStoreScreenshotTests/testCapture"]


def catalog(enabled=TESTS, disabled=DISABLED):
    return {"errors": [], "values": [{"enabledTests": [{"identifier": value + "()"} for value in enabled],
                                      "disabledTests": disabled}]}


class FullShardTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def plan(self, shard):
        shards, seconds = partition(TESTS, {"Long": 100, "Middle": 60})
        return {"version": 1, "revision": "revision", "shard": shard, "catalog": TESTS,
                "disabled": DISABLED, "shards": shards, "estimatedSeconds": seconds}

    def write_lane(self, shard, plan=None):
        directory = self.root / str(shard)
        directory.mkdir(exist_ok=True)
        plan = plan or self.plan(shard)
        (directory / "ui-test-shard-plan.json").write_text(json.dumps(plan))
        selected = plan["shards"][str(plan["shard"])]
        identities = {selector: [selector + "()"] for selector in selected}
        (directory / "ui-test-identities.json").write_text(json.dumps({"version": 1, "selectors": identities}))
        return directory

    def test_catalog_uses_enabled_built_identities_and_retains_exclusions(self):
        document = catalog()
        document["values"].append({"enabledTests": ["IntentTests/Unit/testOne()"]})
        self.assertEqual(inventory(document), (sorted(TESTS), DISABLED))

    def test_corrupt_empty_duplicate_and_conflicting_catalogs_fail(self):
        cases = [None, {}, catalog([]), {"errors": ["load failed"], "values": catalog()["values"]},
                 catalog(TESTS + [TESTS[0]]), catalog(TESTS, [TESTS[0]]),
                 catalog(TESTS + ["IntentUITests/New/test with space"]),
                 catalog(TESTS + DISABLED), {"enabledTests": [42]}, {"enabledTests": "not a list"}]
        for value in cases:
            with self.subTest(value=value), self.assertRaises(ValueError):
                inventory(value)

    def test_partition_is_balanced_complete_deterministic_and_keeps_suites_together(self):
        shards, seconds = partition(TESTS, {"Long": 100, "Middle": 60})
        self.assertEqual(seconds, {"1": 100, "2": 100})
        self.assertEqual(shards, partition(list(reversed(TESTS)), {"Middle": 60, "Long": 100})[0])
        flat = shards["1"] + shards["2"]
        self.assertCountEqual(flat, TESTS)
        self.assertEqual(len(flat), len(set(flat)))
        for suite in ("Long", "Middle", "New"):
            self.assertEqual(sum(any(f"/{suite}/" in test for test in values) for values in shards.values()), 1)

    def test_new_suites_and_new_methods_are_included_without_timing_updates(self):
        enabled, _ = inventory(catalog(TESTS + ["IntentUITests/BrandNew/testAdded", "IntentUITests/Long/testAdded"]))
        shards, _ = partition(enabled, {"Long": 100, "Middle": 60})
        self.assertCountEqual(shards["1"] + shards["2"], enabled)

    def test_empty_shards_and_invalid_used_weights_fail(self):
        with self.assertRaises(ValueError):
            partition([TESTS[0]], {})
        for value in (0, -1, True, "fast", float("nan"), float("inf")):
            with self.subTest(value=value), self.assertRaises(ValueError):
                partition(TESTS, {"Long": value})

    def test_matching_lane_plans_and_exact_resolved_identities_pass(self):
        self.write_lane(1)
        self.write_lane(2)
        self.assertEqual(verify_plans(self.root, "revision"), len(TESTS))

    def test_missing_duplicate_and_wrong_revision_lanes_fail(self):
        self.write_lane(1)
        with self.assertRaisesRegex(ValueError, "exactly two"):
            verify_plans(self.root, "revision")
        self.write_lane(2, self.plan(1))
        with self.assertRaisesRegex(ValueError, "duplicate shard"):
            verify_plans(self.root, "revision")
        self.write_lane(2)
        with self.assertRaisesRegex(ValueError, "revision"):
            verify_plans(self.root, "different")

    def test_cross_lane_inventory_or_partition_disagreement_fails(self):
        self.write_lane(1)
        for change in ("catalog", "partition", "disabled"):
            plan = self.plan(2)
            if change == "catalog":
                plan["catalog"] = TESTS + ["IntentUITests/New/testExtra"]
                plan["shards"]["2"].append("IntentUITests/New/testExtra")
            elif change == "partition":
                plan["shards"]["1"], plan["shards"]["2"] = plan["shards"]["2"], plan["shards"]["1"]
            else:
                plan["disabled"] = []
            self.write_lane(2, plan)
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, "disagree"):
                verify_plans(self.root, "revision")

    def test_missing_extra_duplicate_or_empty_planned_tests_fail(self):
        self.write_lane(1)
        for change in ("missing", "extra", "duplicate", "empty"):
            plan = self.plan(2)
            if change == "missing":
                plan["shards"]["2"].pop()
            elif change == "extra":
                plan["shards"]["2"].append("IntentUITests/Unknown/testExtra")
            elif change == "duplicate":
                plan["shards"]["2"].append(plan["shards"]["1"][0])
            else:
                plan["shards"]["2"] = []
            self.write_lane(2, plan)
            with self.subTest(change=change), self.assertRaises(ValueError):
                verify_plans(self.root, "revision")

    def test_missing_or_broader_resolved_identity_fails(self):
        self.write_lane(1)
        directory = self.write_lane(2)
        identities = directory / "ui-test-identities.json"
        original = json.loads(identities.read_text())
        for change in ("missing", "extra", "wrong", "multiple"):
            value = copy.deepcopy(original)
            first = next(iter(value["selectors"]))
            if change == "missing":
                del value["selectors"][first]
            elif change == "extra":
                value["selectors"]["IntentUITests/Extra/testExtra"] = []
            elif change == "wrong":
                value["selectors"][first] = ["IntentUITests/Other/testWrong()"]
            else:
                value["selectors"][first] *= 2
            identities.write_text(json.dumps(value))
            with self.subTest(change=change), self.assertRaises(ValueError):
                verify_plans(self.root, "revision")

    def test_cli_selects_from_catalog_writes_evidence_and_fails_before_output(self):
        source, weights, plan = (self.root / name for name in ("catalog.json", "weights.json", "plan.json"))
        source.write_text(json.dumps(catalog()))
        weights.write_text(json.dumps({"suiteSeconds": {"Long": 100, "Middle": 60}}))
        args = [sys.executable, str(SCRIPT), "--catalog", str(source), "--weights", str(weights),
                "--shard", "1", "--plan", str(plan), "--revision", "revision"]
        result = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), self.plan(1)["shards"]["1"])
        self.assertEqual(json.loads(plan.read_text())["revision"], "revision")
        source.write_text("not JSON")
        result = subprocess.run(args, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_committed_timing_data_is_valid_and_tied_to_observed_run(self):
        weights = json.loads(SCRIPT.with_name("ui-full-test-durations.json").read_text())
        self.assertEqual(weights["source"]["runId"], "40179093584")
        enabled = [f"IntentUITests/{suite}/testOne" for suite in weights["suiteSeconds"]]
        partition(enabled, weights["suiteSeconds"])


if __name__ == "__main__":
    unittest.main()
