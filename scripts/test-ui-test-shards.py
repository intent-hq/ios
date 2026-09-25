#!/usr/bin/env python3
"""Executable CLI contracts; no Xcode, simulator, network or third-party packages."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT = Path(__file__).with_name("ui-test-shards.py")
REVISION = "a" * 40
A, B, C, D = ["IntentUITests/Suite/test" + letter for letter in "ABCD"]
SCREENSHOT = "IntentUITests/AppStoreScreenshotTests/testCapture"


class ShardCLI(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.context = {
            "schema_version": 1, "run_id": "trial-123", "run_attempt": 1, "revision": REVISION,
            "environment": {"configuration": "Debug", "xcode": "26.3 17C529", "sdk": "26.2",
                            "runtime": "iOS 26.2 build-test", "device_type": "iPhone 16",
                            "runner": "macos-15 image-test", "architecture": "arm64"},
            "cache": {"spm": "hit", "tailcat": "hit"}, "build": {"started_at": 2, "finished_at": 3}}
        self.ctx = self.write("context.json", self.context)
        self.catalog = self.write("catalog.json", self.catalog_document([A, B, C, D]))
        self.hints = self.write("weights.json", {"schema_version": 1, "seconds": {A: 90, B: 80, C: 20, D: 10}})

    def write(self, name, doc):
        path = self.root / name
        path.write_text(json.dumps(doc))
        return path

    def read(self, path):
        return json.loads(Path(path).read_text())

    def cli(self, *args, code=0, message=None):
        result = subprocess.run([sys.executable, str(SCRIPT), *map(str, args)], capture_output=True, text=True)
        self.assertEqual(result.returncode, code, result.stderr + result.stdout)
        if message:
            self.assertIn(message, result.stderr)
        return result

    @staticmethod
    def catalog_document(cases):
        return {"errors": [], "values": [{"enabledTests": [{"identifier": item + "()"} for item in cases],
                                          "disabledTests": [{"identifier": "IntentUITests/AppStoreScreenshotTests"}]}]}

    def plan(self, index=0, count=2, name=None, catalog=None, hints=True, code=0):
        directory = self.root / (name or "worker-" + str(index))
        self.cli("init", "--directory", directory, "--context", self.ctx, "--revision", REVISION,
                 "--count", count, "--index", index)
        extra = ["--weights", self.hints] if hints else []
        result = self.cli("plan", "--directory", directory, "--catalog", catalog or self.catalog,
                          "--simulator-udid", "00000000-0000-0000-0000-000000000001",
                          "--started-at", 4, "--finished-at", 5, *extra, code=code)
        return directory, result

    @staticmethod
    def results(cases):
        return {"testNodes": [{"nodeType": "UI test bundle", "name": "IntentUITests", "children": [
            {"nodeType": "Test Case", "nodeIdentifier": ident.split("/", 1)[1] + "()",
             "result": outcome, "duration": "1.25s"} for ident, outcome in cases]}]}

    def attempt(self, directory, status=0, restarted=0, selectors="", start=6):
        self.cli("attempt", "--directory", directory, "--status", status, "--restarted", restarted,
                 "--selectors", selectors, "--started-at", start, "--finished-at", start + 1)

    def finish(self, directory, cases, status=0, retry=None, code=0, message=None):
        primary = self.write(directory.name + "-results.json", self.results(cases))
        extra = []
        if retry is not None:
            extra = ["--retry-results", self.write(directory.name + "-retry.json", self.results(retry))]
        self.cli("finish", "--directory", directory, "--results", primary, "--status", status,
                 "--started-at", time.time(), *extra, code=code, message=message)
        return directory / "worker.json"

    def workers(self, count=2):
        reports = []
        # Explicit expected partition, not calculated by the implementation.
        selections = [[A, B, C, D]] if count == 1 else [[A, D], [B, C]]
        for index, selected in enumerate(selections):
            directory, result = self.plan(index, count)
            self.assertEqual(result.stdout.splitlines(), selected)
            self.attempt(directory)
            reports.append(self.finish(directory, [(ident, "Skipped" if ident == C else "Passed") for ident in selected]))
        return reports

    def aggregate(self, reports, count=2, jobs=None, code=0, message=None):
        if jobs is None:
            jobs = {"schema_version": 1, "run_id": "trial-123", "run_attempt": 1, "revision": REVISION,
                    "workflow_created_at": 0, "workers": [
                        {"index": index, "conclusion": "success", "started_at": 1, "completed_at": time.time()}
                        for index in range(count)]}
        path = self.write("jobs.json", jobs)
        self.cli("aggregate", "--count", count, "--revision", REVISION, "--run-id", "trial-123",
                 "--run-attempt", 1, "--jobs", path, "--output", self.root / "aggregate.json",
                 *reports, code=code, message=message)

    def test_balanced_partition_order_disabled_and_new_methods(self):
        directory, result = self.plan()
        self.assertEqual(result.stdout.splitlines(), [A, D])
        reverse = self.write("reverse.json", self.catalog_document([D, C, B, A, SCREENSHOT]))
        shuffled, result = self.plan(name="shuffled", catalog=reverse)
        self.assertEqual(result.stdout.splitlines(), [A, D])
        self.assertEqual(self.read(directory / "plan.json")["assignments"], [[A, D], [B, C]])
        new = "IntentUITests/NewSuite/testAdded"
        renamed = "IntentUITests/Suite/testRenamed"
        changed = self.write("changed.json", self.catalog_document([B, C, D, new, renamed]))
        added, _ = self.plan(name="added", catalog=changed)
        plan = self.read(added / "plan.json")
        self.assertEqual(plan["catalog"], sorted([B, C, D, new, renamed]))
        self.assertEqual(plan["weights"][new], 150)
        self.assertEqual(plan["weights"][renamed], 150)
        self.assertNotIn(A, plan["weights"])
        absent, _ = self.plan(name="no-hints", hints=False)
        self.assertEqual(set(self.read(absent / "plan.json")["weights"].values()), {150})
        self.write("weights.json", {"schema_version": 1, "seconds": {}})
        empty, _ = self.plan(name="empty-hints")
        self.assertEqual(self.read(absent / "plan.json")["assignments"], self.read(empty / "plan.json")["assignments"])
        self.assertEqual(self.read(empty / "plan.json")["assignments"], [[A, C], [B, D]])

    def test_invalid_catalog_and_weights_fail_before_selection(self):
        examples = [({}, 83), ({"errors": ["failure"], "values": []}, 83),
                    (self.catalog_document([]), 82), (self.catalog_document([A, A]), 83),
                    (self.catalog_document([A]), 82), (self.catalog_document(["IntentUITests/Suite"]), 83)]
        for index, (doc, code) in enumerate(examples):
            with self.subTest(index=index):
                self.plan(name="bad-" + str(index), catalog=self.write("bad.json", doc), code=code)
        for index, value in enumerate([0, -1, "15", float("nan")]):
            self.write("weights.json", {"schema_version": 1, "seconds": {A: value}})
            self.plan(name="bad-weight-" + str(index), code=83)

    def test_invalid_request_and_stale_directory(self):
        for count, index in [(0, 0), (3, 0), (2, -1), (2, 2), (1, 1)]:
            self.cli("init", "--directory", self.root / "invalid", "--context", self.ctx,
                     "--revision", REVISION, "--count", count, "--index", index, code=1)
        self.cli("init", "--directory", self.root / "foreign", "--context", self.ctx,
                 "--revision", "b" * 40, "--count", 1, "--index", 0, code=83, message="revision")
        directory, _ = self.plan()
        self.cli("init", "--directory", directory, "--context", self.ctx,
                 "--revision", REVISION, "--count", 2, "--index", 0, code=83)

    def test_serial_and_two_worker_coverage_include_runtime_skip(self):
        reports = self.workers()
        self.aggregate(reports)
        merged = self.read(self.root / "aggregate.json")
        self.assertEqual(merged["catalog"], [A, B, C, D])
        self.assertEqual([case["outcome"] for case in merged["cases"]], ["Passed", "Passed", "Skipped", "Passed"])
        self.assertGreater(merged["active_ui_runner_minutes"], 0)
        self.assertNotIn(SCREENSHOT, merged["catalog"])
        # Same immutable catalog, different number of workers, no hidden skip policy.
        self.temp.cleanup()
        self.setUp()
        self.aggregate(self.workers(count=1), count=1)
        self.assertEqual(self.read(self.root / "aggregate.json")["cases"], merged["cases"])

    def test_terminal_result_failure_propagation(self):
        rows = [([(A, "Passed")], 82, "missing"),
                ([(A, "Passed"), (A, "Passed"), (D, "Passed")], 83, "duplicate"),
                ([(A, "Passed"), (D, "Mystery")], 83, "unknown"),
                ([(A, "Passed"), (D, "Failed")], 65, "failed terminal"),
                ([(A, "Passed"), (D, "Passed"), (B, "Passed")], 83, "unassigned")]
        for index, (cases, code, message) in enumerate(rows):
            with self.subTest(index=index):
                directory, _ = self.plan(name="bad-result-" + str(index))
                self.attempt(directory)
                report = self.finish(directory, cases, code=code, message=message)
                self.assertEqual(self.read(report)["exit_code"], code)
        directory, _ = self.plan(name="failed-process")
        self.attempt(directory, status=65)
        self.finish(directory, [], status=65, code=65)

    def test_crash_recovery_requires_every_retry_method(self):
        directory, _ = self.plan()
        self.attempt(directory, status=65, restarted=1)
        self.attempt(directory, selectors=A + " " + D, start=8)
        report = self.finish(directory, [(A, "Failed")], retry=[(A, "Passed"), (D, "Expected Failure")])
        self.assertEqual([case["attempt"] for case in self.read(report)["cases"]], [2, 2])
        self.finish(directory, [(A, "Failed"), (D, "Passed")], retry=[(A, "Passed")],
                    code=82, message="unrecovered")
        self.finish(directory, [(A, "Failed")], code=83, message="retry evidence missing")
        stopped, _ = self.plan(name="crash-stopped")
        self.attempt(stopped, status=65, restarted=1)
        self.finish(stopped, [(A, "Failed")], status=80, code=80)
        crashed, _ = self.plan(name="crash-twice")
        self.attempt(crashed, status=65, restarted=1)
        self.attempt(crashed, status=65, restarted=1, selectors=A + " " + D, start=8)
        self.finish(crashed, [], status=80, retry=[(A, "Failed"), (D, "Passed")], code=80)
        failed, _ = self.plan(name="retry-assertion-failed")
        self.attempt(failed, status=65, restarted=1)
        self.attempt(failed, status=65, selectors=A + " " + D, start=8)
        self.finish(failed, [], status=65, retry=[(A, "Failed"), (D, "Passed")], code=65)

    def test_result_format_and_content_are_fail_closed(self):
        directory, _ = self.plan()
        self.attempt(directory)
        for doc in [{}, {"testNodes": []}, {"testNodes": [None]}, self.results([(A, "Passed"), (D, "Passed")])]:
            with self.subTest(doc=doc):
                if doc.get("testNodes") and isinstance(doc["testNodes"][0], dict):
                    doc["testNodes"][0]["name"] = "IntentTests"
                path = self.write("bad-result.json", doc)
                self.cli("finish", "--directory", directory, "--results", path, "--status", 0,
                         "--started-at", time.time(), code=82 if doc == {"testNodes": []} else 83)
        self.cli("finish", "--directory", directory, "--results", self.root / "missing.json", "--status", 0,
                 "--started-at", time.time(), code=83, message="unreadable")

    def test_aggregate_rejects_missing_duplicate_foreign_and_tampered_evidence(self):
        reports = self.workers()
        self.aggregate(reports[:1], code=83, message="missing or extra worker")
        self.aggregate([reports[0], reports[0]], code=83, message="duplicate or missing shard")
        original = self.read(reports[1])
        mutations = [
            (lambda r: r["plan"]["context"].update(revision="b" * 40), "foreign worker"),
            (lambda r: r["plan"]["context"].update(run_attempt=2), "foreign worker"),
            (lambda r: r["plan"]["context"]["environment"].update(runtime="different"), "environment mismatch"),
            (lambda r: r["plan"]["catalog"].pop(), "weights do not cover"),
            (lambda r: r["plan"]["assignments"][1].pop(), "assignment differs"),
            (lambda r: r["cases"].pop(), "terminal outcomes differ"),
            (lambda r: r["attempts"][0]["cases"].append(r["attempts"][0]["cases"][0]), "duplicate test"),
            (lambda r: r.update(exit_code=65), "did not finish"),
            (lambda r: r.update(schema_version=2), "did not finish"),
        ]
        for mutate, message in mutations:
            with self.subTest(message=message):
                report = copy.deepcopy(original)
                mutate(report)
                self.write("worker-1/worker.json", report)
                self.aggregate(reports, code=83, message=message)
        reports[1].write_text('{"schema_version":1,"schema_version":1}')
        self.aggregate(reports, code=83, message="duplicate JSON key")
        reports[1].write_text("not JSON")
        self.aggregate(reports, code=83, message="malformed")
        self.aggregate([reports[0], self.root / "missing.json"], code=83, message="unreadable")

    def test_individually_valid_different_catalog_cannot_be_combined(self):
        reports = self.workers()
        # Added method is genuinely selected and passed, not just a damaged digest.
        renamed = "IntentUITests/Suite/testE"
        new_catalog = self.write("new-catalog.json", self.catalog_document([A, B, C, renamed]))
        directory, result = self.plan(index=1, name="different-catalog", catalog=new_catalog)
        self.assertEqual(result.stdout.splitlines(), [A, B])
        self.attempt(directory)
        report = self.finish(directory, [(A, "Passed"), (B, "Passed")])
        self.aggregate([reports[0], report], code=83, message="catalog, assignment or environment mismatch")

    def test_job_receipts_are_independent_required_evidence(self):
        reports = self.workers()
        jobs = {"schema_version": 1, "run_id": "trial-123", "run_attempt": 1, "revision": REVISION,
                "workflow_created_at": 0, "workers": [
                    {"index": index, "conclusion": "success", "started_at": 1, "completed_at": time.time()}
                    for index in range(2)]}
        for conclusion in ["failure", "cancelled", "skipped", "in_progress", None]:
            bad = copy.deepcopy(jobs)
            bad["workers"][1]["conclusion"] = conclusion
            self.aggregate(reports, jobs=bad, code=83, message="cancelled or incomplete")
        bad = copy.deepcopy(jobs)
        bad["workers"][1]["index"] = 0
        self.aggregate(reports, jobs=bad, code=83, message="duplicate or missing worker job")
        jobs["run_attempt"] = 2
        self.aggregate(reports, jobs=jobs, code=83, message="foreign job manifest")


if __name__ == "__main__":
    unittest.main()