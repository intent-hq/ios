#!/usr/bin/env python3
"""Workflow-boundary tests: real YAML/step bodies and helper with fake gh/Xcode.

Python standard library + Ruby's bundled YAML parser; no network, simulator,
credentials or added packages. The engine suite owns partition/result semantics;
this suite owns routing, context collection and authoritative transport receipts.
"""

from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parent.parent
REVISION = "a" * 40
BASE = "repos/intent-hq/ios/actions"
RUN = BASE + "/runs/123"
ATTEMPT = RUN + "/attempts/2"
PREFIX = "ui-trial-" + REVISION + "-123-2-"
UDID = "00000000-0000-0000-0000-000000000001"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
DEVICE = "com.apple.CoreSimulator.SimDeviceType.iPhone-16"


def iso(seconds):
    return datetime.fromtimestamp(seconds, timezone.utc).isoformat().replace("+00:00", "Z")


def expression(text, values):
    """Evaluate only the expression subset used by the actual routing/wiring."""
    def lookup(match):
        return repr(values[match.group()])

    text = text.removeprefix("${{").removesuffix("}}").strip()
    text = re.sub(r"(?:github|inputs|needs|steps|matrix)\.[A-Za-z0-9_.-]+", lookup, text)
    text = text.replace("&&", " and ").replace("||", " or ")
    text = re.sub(r"!(?!=)", " not ", text)
    return eval(text, {"__builtins__": {}, "always": lambda: True,
                       "failure": lambda: values.get("failure", False),
                       "cancelled": lambda: values.get("cancelled", False), "fromJSON": json.loads})


def render(text, values):
    return re.sub(r"\$\{\{.*?\}\}", lambda match: str(expression(match.group(), values)), str(text))


class TrialWorkflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = subprocess.run(["ruby", "-ryaml", "-rjson", "-e",
                                 "puts YAML.load_file(ARGV[0]).to_json", str(ROOT / ".github/workflows/ci.yml")],
                                text=True, capture_output=True, check=True)
        cls.workflow = json.loads(result.stdout)
        cls.jobs = cls.workflow["jobs"]

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "bin").mkdir()
        (self.root / "bin/python3").symlink_to(sys.executable)
        (self.root / "scripts").mkdir()
        for name in ("ui-test-trial.py", "ui-test-shards.py"):
            shutil.copyfile(ROOT / "scripts" / name, self.root / "scripts" / name)
        # Do not forward credentials from a developer's environment to stubs.
        self.env = {"PATH": str(self.root / "bin") + os.pathsep + os.environ["PATH"],
                    "GITHUB_SHA": REVISION, "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2",
                    "GITHUB_REPOSITORY": "intent-hq/ios", "GITHUB_EVENT_NAME": "workflow_dispatch",
                    "GITHUB_OUTPUT": str(self.root / "output"), "GITHUB_ENV": str(self.root / "env"),
                    "GITHUB_STEP_SUMMARY": str(self.root / "summary"), "FIXTURE": str(self.root),
                    "SIM_UDID": UDID, "ImageOS": "macos15", "ImageVersion": "20260920.1"}
        self.executable("bin/git", "import os\nprint(os.environ.get('STUB_HEAD', 'a' * 40))\n")
        self.executable("bin/gh", """import json, os, pathlib, sys
root = pathlib.Path(os.environ['FIXTURE'])
with (root / 'requests').open('a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
responses = json.loads((root / 'api.json').read_text())
assert sys.argv[1] == 'api'
response = responses.get(sys.argv[2])
if response is None:
    sys.exit(1)
if isinstance(response, str):
    sys.stdout.buffer.write((root / response).read_bytes())
else:
    print(json.dumps(response))
""")
        self.executable("scripts/xcodebuild.sh", """import json, os, pathlib, sys
root = pathlib.Path(os.environ['FIXTURE'])
with (root / 'wrapper-calls').open('a') as log:
    log.write(json.dumps({'args': sys.argv[1:], 'configuration': os.environ.get('BUILD_CONFIGURATION'),
        'simulator': os.environ.get('SIM_UDID'), 'shard': {key: value for key, value in os.environ.items()
        if key.startswith('UI_TEST_SHARD_')}}) + '\\n')
if sys.argv[1:] == ['pick-simulator']:
    print(os.environ['SIM_UDID'])
sys.exit(int(os.environ.get('STUB_BUILD_STATUS', '0')))
""")
        self.executable("bin/xcodebuild", "import sys\nassert sys.argv[1:] == ['-version']\nprint('Xcode 26.3\\nBuild version 17C529')\n")
        self.executable("bin/xcrun", """import json, os, pathlib, sys
root = pathlib.Path(os.environ['FIXTURE'])
args = sys.argv[1:]
if args == ['simctl', 'list', '-j']:
    print((root / 'simulator.json').read_text())
elif args == ['--sdk', 'iphonesimulator', '--show-sdk-version']:
    print('26.2')
elif args == ['--sdk', 'iphonesimulator', '--show-sdk-build-version']:
    print('23C54')
else:
    sys.exit(1)
""")
        self.simulator = {"devices": {RUNTIME: [{"udid": UDID, "deviceTypeIdentifier": DEVICE, "isAvailable": True}]},
                          "runtimes": [{"identifier": RUNTIME, "version": "26.2", "buildversion": "23C54", "isAvailable": True}],
                          "devicetypes": [{"identifier": DEVICE}]}
        self.write("simulator.json", self.simulator)

    def executable(self, path, body):
        target = self.root / path
        target.write_text("#!" + sys.executable + "\n" + body)
        target.chmod(0o755)

    def write(self, name, value):
        (self.root / name).write_text(json.dumps(value))

    def step(self, job, name):
        return next(step for step in self.jobs[job]["steps"] if step.get("name") == name)

    def run_step(self, job, name, values=None, extra=None, code=0):
        step = self.step(job, name)
        values = values or {}
        env = dict(self.env, **self.jobs[job].get("env", {}), **(extra or {}))
        env.update({key: render(value, values) for key, value in step.get("env", {}).items() if key != "GH_TOKEN"})
        result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", render(step["run"], values)],
                                cwd=self.root, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result

    def values(self, event="workflow_dispatch", mode="off", filter_value="", result="skipped"):
        return {"github.event_name": event, "inputs.ui_test_trial": mode, "inputs.only_testing": filter_value,
                "needs.ui-trial-inputs.result": result, "needs.ui-trial-worker.result": "failure"}

    def active(self, values):
        return {key for key, job in self.jobs.items() if expression(job.get("if", "always()"), values)}

    def test_actual_yaml_routing_and_check_identities(self):
        normal = {"go-test", "swiftlint", "build-and-test", "ios-ui-tests", "visionos-build"}
        for event, mode, selected, expected in [
            ("pull_request", "", "", normal | {"pr-title"}),
            ("pull_request", "two-shards", "IntentTests", normal | {"pr-title"}),
            ("workflow_dispatch", "off", "", normal),
            ("workflow_dispatch", "", "", normal),
            ("workflow_dispatch", "off", "IntentTests/Suite", {"go-test", "swiftlint", "build-and-test"}),
        ]:
            with self.subTest(event=event, mode=mode, selected=selected):
                values = self.values(event, mode, selected)
                self.assertEqual(self.active(values), expected)
                self.assertEqual(render(self.jobs["build-and-test"]["name"], values),
                                 "iOS Filtered Tests (non-gating)" if event == "workflow_dispatch" and selected else "iOS Build & Test")
        self.assertEqual(self.jobs["ios-ui-tests"]["name"], "iOS UI Tests")
        inputs = self.workflow["true"]["workflow_dispatch"]["inputs"]["ui_test_trial"]
        self.assertEqual((inputs["type"], inputs["default"], inputs["options"]), ("choice", "off", ["off", "serial", "two-shards"]))
        for mode, count in [("serial", 1), ("two-shards", 2)]:
            values = self.values(mode=mode, result="success")
            self.assertEqual(self.active(values), {"ui-trial-inputs", "ui-trial-worker", "ui-trial-result"})
            self.run_step("ui-trial-inputs", "Validate UI trial inputs", values)
            step_outputs = {"steps.validate.outputs." + key: value for key, value in (
                line.split("=", 1) for line in (self.root / "output").read_text().splitlines())}
            outputs = {key: expression(value, step_outputs) for key, value in self.jobs["ui-trial-inputs"]["outputs"].items()}
            self.assertEqual(outputs["count"], str(count))
            values["needs.ui-trial-inputs.outputs.matrix"] = outputs["matrix"]
            self.assertEqual(expression(self.jobs["ui-trial-worker"]["strategy"]["matrix"], values), {"index": list(range(count))})

    def test_invalid_conflicting_inputs_never_schedule_workers(self):
        for mode, selected, message in [("three", "", "invalid trial"), ("serial", "IntentUITests", "conflicts"),
                                         ("two-shards", " ", "conflicts"), ("SERIAL", "", "invalid trial")]:
            values = self.values(mode=mode, filter_value=selected, result="failure")
            self.assertEqual(self.active(values), {"ui-trial-inputs"})
            result = self.run_step("ui-trial-inputs", "Validate UI trial inputs", values, code=1)
            self.assertIn(message, result.stderr)
            self.assertFalse((self.root / "output").exists())

    def test_yaml_build_context_and_step_scoped_sharding(self):
        worker = self.jobs["ui-trial-worker"]
        self.assertEqual(worker["runs-on"], "macos-15")
        self.assertIs(worker["strategy"]["fail-fast"], False)
        self.assertEqual(self.jobs["ui-trial-result"]["needs"], ["ui-trial-inputs", "ui-trial-worker"])
        steps = worker["steps"]
        names = [step.get("name") for step in steps]
        self.assertLess(names.index("Build for testing"), names.index("Record UI trial context"))
        self.assertLess(names.index("Record UI trial context"), names.index("Run UI trial tests"))
        for job_id in ("ui-trial-inputs", "ui-trial-worker", "ui-trial-result"):
            checkout = next(step for step in self.jobs[job_id]["steps"] if step.get("uses", "").startswith("actions/checkout@"))
            self.assertEqual(render(checkout["with"]["ref"], {"github.sha": REVISION}), REVISION)
        for step in steps:
            if step.get("name") != "Run UI trial tests":
                self.assertFalse(any(key.startswith("UI_TEST_SHARD_") for key in step.get("env", {})))
            self.assertFalse(step.get("continue-on-error", False))
        self.assertFalse(any(key.startswith("UI_TEST_SHARD_") for key in worker["env"]))
        for name in ("Cache TailcatKit.xcframework", "Cache SPM packages"):
            self.assertEqual(self.step("ui-trial-worker", name)["with"], self.step("ios-ui-tests", name)["with"])
        self.run_step("ui-trial-worker", "Pick simulator device")
        self.assertEqual((self.root / "env").read_text().strip(), "SIM_UDID=" + UDID)
        self.run_step("ui-trial-worker", "Resolve SPM packages")
        self.run_step("ui-trial-worker", "Build for testing")
        cache = {"steps.spm-cache.outputs.cache-hit": "false", "steps.tailcat-cache.outputs.cache-hit": "true"}
        self.run_step("ui-trial-worker", "Record UI trial context", cache)
        ctx = json.loads((self.root / "trial-context.json").read_text())
        self.assertEqual(ctx["environment"]["runtime"], RUNTIME + " 26.2 23C54")
        self.assertEqual(ctx["environment"]["device_type"], DEVICE)
        self.assertEqual(ctx["environment"]["xcode"], "Xcode 26.3 Build version 17C529")
        self.assertEqual(ctx["cache"], {"spm": "restored", "tailcat": "hit"})
        self.assertLessEqual(ctx["build"]["started_at"], ctx["build"]["finished_at"])
        subprocess.run([sys.executable, str(self.root / "scripts/ui-test-shards.py"), "init",
                        "--context", str(self.root / "trial-context.json"), "--revision", REVISION,
                        "--directory", str(self.root / "engine-request"), "--count", "2", "--index", "0"], check=True)
        for count in (1, 2):
            for index in range(count):
                self.run_step("ui-trial-worker", "Run UI trial tests", {
                    "needs.ui-trial-inputs.outputs.count": str(count), "matrix.index": index})
        calls = [json.loads(line) for line in (self.root / "wrapper-calls").read_text().splitlines()]
        self.assertEqual(calls[:3], [{"args": [command], "configuration": "Debug", "simulator": UDID, "shard": {}}
                                     for command in ("pick-simulator", "resolve", "build-for-testing")])
        self.assertEqual([call["shard"]["UI_TEST_SHARD_INDEX"] for call in calls[3:]], ["0", "0", "1"])
        self.assertTrue(all(call["args"] == ["test-without-building"] and call["simulator"] == UDID for call in calls[3:]))
        upload = self.step("ui-trial-worker", "Upload UI trial evidence")
        self.assertTrue(expression(upload["if"], {"failure": True, "cancelled": True}))
        self.assertEqual(upload["with"]["path"], "trial/worker.json")
        self.assertEqual(upload["with"]["if-no-files-found"], "error")
        self.assertEqual(render(upload["with"]["name"], {"github.sha": REVISION, "github.run_id": "123",
                                                        "github.run_attempt": "2", "matrix.index": 1}), PREFIX + "1")
        self.assertFalse(self.step("ui-trial-result", "Upload verified UI trial result").get("if"))

    def test_failed_build_missing_runtime_or_wrong_checkout_produce_no_context(self):
        self.run_step("ui-trial-worker", "Build for testing", extra={"STUB_BUILD_STATUS": "65"}, code=1)
        self.assertFalse((self.root / "trial-build.json").exists())
        self.run_step("ui-trial-worker", "Build for testing", extra={"STUB_HEAD": "b" * 40}, code=1)
        self.assertFalse((self.root / "trial-build.json").exists())
        self.run_step("ui-trial-worker", "Build for testing")
        self.simulator["devices"] = {}
        self.write("simulator.json", self.simulator)
        self.run_step("ui-trial-worker", "Record UI trial context", {"steps.spm-cache.outputs.cache-hit": "",
                                                                   "steps.tailcat-cache.outputs.cache-hit": ""}, code=1)
        self.assertFalse((self.root / "trial-context.json").exists())

    def fixture(self, count=2):
        cases = ["IntentUITests/Suite/testA", "IntentUITests/Suite/testB"]
        disabled = ["IntentUITests/AppStoreScreenshotTests"]
        assignments = [cases] if count == 1 else [[cases[0]], [cases[1]]]
        digest = hashlib.sha256(json.dumps([cases, disabled], sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        self.api = {ATTEMPT: {"id": 123, "run_attempt": 2, "head_sha": REVISION, "event": "workflow_dispatch",
                             "path": ".github/workflows/ci.yml", "repository": {"full_name": "intent-hq/ios"},
                             "created_at": iso(1000), "run_started_at": iso(1001)}}
        self.worker_jobs, self.artifacts, self.reports = [], [], []
        for index in range(count):
            self.worker_jobs.append({"id": index + 10, "name": render(self.jobs["ui-trial-worker"]["name"], {"matrix.index": index}),
                                     "run_id": 123, "run_attempt": 2, "head_sha": REVISION,
                                     "status": "completed", "conclusion": "success", "started_at": iso(1002),
                                     "completed_at": iso(1100), "steps": [{"name": "Upload UI trial evidence",
                                         "status": "completed", "conclusion": "success",
                                         "started_at": iso(1066), "completed_at": iso(1081)}]})
            ctx = {"schema_version": 1, "run_id": "123", "run_attempt": 2, "revision": REVISION,
                   "environment": {"configuration": "Debug", "xcode": "26.3 17C529", "sdk": "26.2 23C54",
                                   "runtime": RUNTIME + " 26.2 23C54", "device_type": DEVICE,
                                   "runner": "macos-15 macos15 image-test", "architecture": "arm64"},
                   "cache": {"spm": "miss", "tailcat": "hit"}, "build": {"started_at": 1010, "finished_at": 1020}}
            selected = [{"identifier": case, "outcome": "Skipped" if case == cases[1] else "Passed", "duration_seconds": 1}
                        for case in assignments[index]]
            report = {"schema_version": 1, "plan": {"schema_version": 1, "context": ctx, "count": count,
                      "index": index, "simulator_udid": UDID, "catalog": cases, "disabled": disabled,
                      "weights": {case: 150 for case in cases}, "assignments": assignments, "catalog_sha256": digest,
                      "discovery": {"started_at": 1021, "finished_at": 1025}},
                      "attempts": [{"exit_code": 0, "restarted": False, "selectors": assignments[index],
                                    "timing": {"started_at": 1030, "finished_at": 1060}, "cases": selected}],
                      "cases": [dict(case, attempt=1) for case in selected], "exit_code": 0,
                      "validation": {"started_at": 1061, "finished_at": 1065}}
            self.reports.append(report)
            artifact_name = render(self.step("ui-trial-worker", "Upload UI trial evidence")["with"]["name"], {
                "github.sha": REVISION, "github.run_id": "123", "github.run_attempt": "2", "matrix.index": index})
            self.artifacts.append({"id": index + 100, "name": artifact_name, "expired": False,
                                   "workflow_run": {"id": 123, "head_sha": REVISION},
                                   "created_at": iso(1070), "updated_at": iso(1080)})
            self.archive(index)
        self.api[ATTEMPT + "/jobs?per_page=100&page=1"] = {"total_count": count, "jobs": self.worker_jobs}
        self.api[RUN + "/artifacts?per_page=100&page=1"] = {"total_count": count, "artifacts": self.artifacts}

    def archive(self, index, entries=None):
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as archive:
            for name, value in (entries or {"worker.json": json.dumps(self.reports[index])}).items():
                archive.writestr(name, value)
        (self.root / ("archive-%d.zip" % index)).write_bytes(data.getvalue())
        self.artifacts[index].update(digest="sha256:" + hashlib.sha256(data.getvalue()).hexdigest(), size_in_bytes=len(data.getvalue()))
        self.api[BASE + "/artifacts/%d/zip" % (index + 100)] = "archive-%d.zip" % index

    def collect(self, count=2, code=0, message=None):
        self.write("api.json", self.api)
        result = self.run_step("ui-trial-result", "Verify UI trial receipts and coverage",
                               {"needs.ui-trial-inputs.outputs.count": str(count)}, code=code)
        if message:
            self.assertIn(message, result.stderr)
        if code:
            self.assertFalse((self.root / "trial-combined/combined.json").exists())
            self.assertFalse((self.root / "summary").exists())
        return result

    def test_serial_two_shard_collection_and_complete_pagination(self):
        for count in (1, 2):
            with self.subTest(count=count):
                if count == 2:
                    self.temp.cleanup()
                    self.setUp()
                self.fixture(count)
                # Include old-attempt artifacts and ordinary job records on page
                # one; required current workers/evidence are only on page two.
                for path, key, tail in [(ATTEMPT + "/jobs", "jobs", self.worker_jobs),
                                        (RUN + "/artifacts", "artifacts", self.artifacts)]:
                    head = [{"id": 1000 + index, "name": "old-attempt-" + str(index)} for index in range(100)]
                    self.api[path + "?per_page=100&page=1"] = {"total_count": 100 + count, key: head}
                    self.api[path + "?per_page=100&page=2"] = {"total_count": 100 + count, key: tail}
                self.collect(count)
                combined = json.loads((self.root / "trial-combined/combined.json").read_text())
                self.assertEqual(combined["count"], count)
                self.assertEqual([case["outcome"] for case in combined["cases"]], ["Passed", "Skipped"])
                self.assertAlmostEqual(combined["active_ui_runner_minutes"], count * 98 / 60)
                self.assertEqual(combined["jobs"]["run_attempt"], 2)
                requests = (self.root / "requests").read_text()
                self.assertIn("/attempts/2/jobs?per_page=100&page=2", requests)
                self.assertIn("/artifacts?per_page=100&page=2", requests)
                self.assertIn("Other/gaps", (self.root / "summary").read_text())

    def test_missing_ambiguous_stale_failed_or_cancelled_job_receipts(self):
        mutations = [
            (lambda: self.worker_jobs.pop(), "mapping"),
            (lambda: self.worker_jobs[1].update(name=self.worker_jobs[0]["name"]), "mapping"),
            (lambda: self.worker_jobs[1].update(run_attempt=1), "partial-attempt"),
            (lambda: self.worker_jobs[1].update(head_sha="b" * 40), "partial-attempt"),
            (lambda: self.worker_jobs[1].update(conclusion="cancelled"), "cancelled"),
            (lambda: self.worker_jobs[1].update(conclusion="failure"), "failed"),
            (lambda: self.worker_jobs[1].update(status="in_progress"), "incomplete"),
            (lambda: self.worker_jobs[1].update(steps=[]), "upload"),
            (lambda: self.worker_jobs[1]["steps"][0].update(conclusion="failure"), "upload"),
            (lambda: self.worker_jobs[1]["steps"][0].update(completed_at=iso(1101)), "upload interval"),
            (lambda: self.api[ATTEMPT].update(run_attempt=1), "foreign workflow"),
        ]
        for mutation, message in mutations:
            with self.subTest(message=message):
                self.fixture()
                mutation()
                self.api[ATTEMPT + "/jobs?per_page=100&page=1"]["total_count"] = len(self.worker_jobs)
                self.collect(code=1, message=message)
                self.assertFalse((self.root / "trial-combined").exists())

    def test_api_errors_truncation_duplicates_and_changing_totals(self):
        for scenario in ("api-error", "truncated", "duplicate", "changed-total"):
            with self.subTest(scenario=scenario):
                self.fixture()
                path = ATTEMPT + "/jobs?per_page=100&page=1"
                if scenario == "api-error":
                    self.api[path] = None
                    message = "command failed"
                elif scenario == "truncated":
                    self.api[path]["total_count"] = 3
                    message = "truncated"
                elif scenario == "duplicate":
                    self.worker_jobs[1]["id"] = self.worker_jobs[0]["id"]
                    message = "duplicate"
                else:
                    self.api[path] = {"total_count": 102, "jobs": [{"id": 1000 + i, "name": "other"} for i in range(100)]}
                    self.api[ATTEMPT + "/jobs?per_page=100&page=2"] = {"total_count": 103, "jobs": self.worker_jobs}
                    message = "unstable"
                self.collect(code=1, message=message)

    def test_missing_foreign_stale_or_tampered_artifacts(self):
        mutations = [
            (lambda: self.artifacts.pop(), "artifacts"),
            (lambda: self.artifacts[1].update(name=PREFIX + "0"), "artifacts"),
            (lambda: self.artifacts[1].update(name=PREFIX.replace("-2-", "-1-") + "1"), "artifacts"),
            (lambda: self.artifacts[1]["workflow_run"].update(head_sha="b" * 40), "foreign or expired"),
            (lambda: self.artifacts[1].update(expired=True), "foreign or expired"),
            (lambda: self.artifacts[1].update(created_at=iso(1060)), "outside worker upload"),
            (lambda: self.artifacts[1].update(digest="sha256:" + "0" * 64), "digest mismatch"),
            (lambda: self.artifacts[1].update(digest=None), "missing artifact digest"),
            (lambda: self.api.pop(BASE + "/artifacts/101/zip"), "command failed"),
            (lambda: self.archive(1, {"../worker.json": "{}"}), "archive contents"),
            (lambda: (self.reports[1]["plan"]["context"].update(run_attempt=1), self.archive(1)), "foreign artifact payload"),
            (lambda: (self.reports[1].update(exit_code=65), self.archive(1)), "combined coverage validation failed"),
        ]
        for mutation, message in mutations:
            with self.subTest(message=message):
                self.temp.cleanup()
                self.setUp()
                self.fixture()
                mutation()
                self.api[RUN + "/artifacts?per_page=100&page=1"]["total_count"] = len(self.artifacts)
                self.collect(code=1, message=message)


if __name__ == "__main__":
    unittest.main()