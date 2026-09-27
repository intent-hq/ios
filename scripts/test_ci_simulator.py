#!/usr/bin/env python3
"""Disposable simulator/CI contract tests; no Xcode or real devices are used."""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch

import ci_simulator as route


RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
TYPE = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4"
OLD = "11111111-1111-4111-8111-111111111111"
NEW = "22222222-2222-4222-8222-222222222222"
SELECTORS = "IntentUITests/HomeActionMenuUITests/testIPadConversationKeepsSendAndMenuAvailable IntentTests/PersonalPairingPermissionsTests"


def result_document(cases):
    bundles = {}
    for identifier, result in cases:
        bundle, test = identifier.split("/", 1)
        bundles.setdefault(bundle, []).append({"nodeType": "Test Case", "nodeIdentifier": test, "result": result})
    return {"testNodes": [{"nodeType": "Test Bundle", "name": name, "children": children}
                          for name, children in bundles.items()]}


CASES = [(SELECTORS.split()[0] + "()", "Passed")] + [
    (f"IntentTests/PersonalPairingPermissionsTests/test{index}()", "Passed") for index in range(4)]


class Host:
    def __init__(self):
        self.calls = []
        self.fail_create = False
        self.fail_delete = False
        self.results = result_document(CASES)
        self.retry_results = result_document([])
        self.document = {
            "runtimes": [{"identifier": RUNTIME, "version": "26.2", "name": "iOS 26.2", "isAvailable": True}],
            "devicetypes": [{"identifier": TYPE, "name": "iPad Pro (M4)", "productFamily": "iPad"}],
            "devices": {RUNTIME: [{"udid": OLD, "name": "My existing iPad", "deviceTypeIdentifier": TYPE, "isAvailable": True}]},
        }

    def __call__(self, args):
        self.calls.append(args)
        status, output = 0, ""
        if args == ["xcrun", "simctl", "list", "--json"]:
            output = json.dumps(self.document)
        elif args[:3] == ["xcrun", "simctl", "create"]:
            self.document["devices"][args[5]].append({"udid": NEW, "name": args[3],
                "deviceTypeIdentifier": args[4], "isAvailable": True})
            status, output = int(self.fail_create), NEW + "\n"
        elif args[:3] == ["xcrun", "simctl", "delete"]:
            status = int(self.fail_delete)
            if not status:
                for devices in self.document["devices"].values():
                    devices[:] = [device for device in devices if device["udid"] != args[3]]
        elif args[:3] == ["xcrun", "simctl", "shutdown"]:
            status = 1  # Already shutdown is harmless; deletion must still run.
        elif args[:2] == ["git", "rev-parse"]:
            output = ("a" if args[-1] == "HEAD" else "b") * 40 + "\n"
        elif args[:2] == ["git", "show"]:
            output = "c" * 40 + "\n"
        elif args == ["xcodebuild", "-version"]:
            output = "Xcode 26.3\nBuild version test\n"
        elif args[:6] == ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path"]:
            output = json.dumps(self.retry_results if args[6].endswith("-retry") else self.results)
        else:
            raise AssertionError(f"Unexpected host command: {args}")
        return subprocess.CompletedProcess(args, status, output, "injected failure" if status else "")


class SimulatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.env = {"SIMULATOR_FAMILY": "ipad", "GITHUB_EVENT_NAME": "workflow_dispatch", "ONLY_TESTING": SELECTORS,
                    "GITHUB_ENV": str(self.directory / "environment"), "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1",
                    "RESULT_BUNDLE": str(self.directory / "TestResults")}
        Path(self.env["RESULT_BUNDLE"]).mkdir()
        self.host = Host()
        self.patcher = patch.object(route, "run", self.host)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def test_default_iphone_requests_keep_existing_wrapper_validation(self):
        for event in ("pull_request", "merge_group", "workflow_dispatch"):
            for selection in ("", "IntentTests", "ExistingSelector.swift"):
                family, _ = route.validate({"GITHUB_EVENT_NAME": event, "ONLY_TESTING": selection})
                self.assertEqual(family, "iphone")
        self.assertEqual(self.host.calls, [])

    def test_ipad_requires_bounded_safe_filtered_dispatch(self):
        invalid = [dict(GITHUB_EVENT_NAME="pull_request"), dict(GITHUB_EVENT_NAME="merge_group"),
                   dict(ONLY_TESTING=" \n"), dict(ONLY_TESTING="IntentUITests"), dict(ONLY_TESTING="-sdk iphoneos"),
                   dict(ONLY_TESTING="IntentTests/$(touch-owned)"), dict(SIMULATOR_FAMILY="visionos"),
                   dict(ONLY_TESTING=" ".join(f"IntentTests/Suite{i}" for i in range(21)))]
        for change in invalid:
            with self.subTest(change=change), self.assertRaises(ValueError):
                route.prepare(dict(self.env, **change), self.directory)
        self.assertEqual(self.host.calls, [])
        self.assertFalse((self.directory / "environment").exists())

    def test_creation_persists_exact_destination_and_cleanup_only_deletes_owned_device(self):
        route.prepare(self.env, self.directory)
        self.assertEqual((self.directory / "environment").read_text(), f"SIM_UDID={NEW}\n")
        plan = json.loads((self.directory / "ownership.json").read_text())
        self.assertEqual(plan["createdUDID"], NEW)
        self.assertEqual(plan["checkout"], "a" * 40)
        self.assertEqual(plan["tree"], "b" * 40)
        self.assertEqual(plan["runtime"]["identifier"], RUNTIME)
        with self.assertRaises(ValueError):
            route.prepare(self.env, self.directory)
        route.cleanup(self.directory)
        self.assertEqual(self.host.document["devices"][RUNTIME][0]["udid"], OLD)
        self.assertEqual(len(self.host.document["devices"][RUNTIME]), 1)
        self.assertEqual([call for call in self.host.calls if "delete" in call], [["xcrun", "simctl", "delete", NEW]])
        self.assertEqual(json.loads((self.directory / "cleanup.json").read_text())["deleteExit"], 0)

    def test_no_available_ipad_or_ios_runtime_never_creates_or_falls_back(self):
        for key in ("runtime", "device", "family"):
            document = copy.deepcopy(Host().document)
            if key == "runtime":
                document["runtimes"][0]["isAvailable"] = False
            elif key == "device":
                document["devices"][RUNTIME][0]["isAvailable"] = False
            else:
                document["devicetypes"][0].update(name="iPhone 16", productFamily="iPhone")
            self.host.document = document
            with self.subTest(key=key), self.assertRaises(ValueError):
                route.prepare(self.env, self.directory)
        self.assertFalse(any("create" in call for call in self.host.calls))

    def test_newest_available_compatible_runtime_is_selected(self):
        other = RUNTIME.replace("26-2", "27-0")
        self.host.document["runtimes"].append({"identifier": other, "version": "27.0", "name": "iOS 27.0", "isAvailable": True})
        self.host.document["devices"][other] = copy.deepcopy(self.host.document["devices"][RUNTIME])
        self.assertEqual(route.choose_ipad(self.host.document)["runtime"]["identifier"], other)
        self.host.document["runtimes"][-1]["isAvailable"] = False
        self.assertEqual(route.choose_ipad(self.host.document)["runtime"]["identifier"], RUNTIME)

    def test_failed_create_with_partial_device_is_recovered_by_unique_ownership_intent(self):
        self.host.fail_create = True
        with self.assertRaises(RuntimeError):
            route.prepare(self.env, self.directory)
        self.assertFalse((self.directory / "environment").exists())
        route.cleanup(self.directory)
        self.assertEqual([device["udid"] for device in self.host.document["devices"][RUNTIME]], [OLD])
        self.assertEqual(json.loads((self.directory / "creation.json").read_text())["exitCode"], 1)

    def test_interrupted_receipt_update_keeps_creation_intent_for_cleanup(self):
        original = route.write_json
        def reject_recorded_udid(path, value):
            if path.name == "ownership.json" and value.get("createdUDID"):
                raise OSError("injected receipt write failure")
            original(path, value)
        with patch.object(route, "write_json", reject_recorded_udid), self.assertRaises(OSError):
            route.prepare(self.env, self.directory)
        self.assertIsNone(json.loads((self.directory / "ownership.json").read_text())["createdUDID"])
        route.cleanup(self.directory)
        self.assertIn(["xcrun", "simctl", "delete", NEW], self.host.calls)

    def test_setup_failure_without_receipt_never_shuts_down_any_device(self):
        route.cleanup(self.directory)
        self.assertEqual(self.host.calls, [])

    def test_preexisting_udid_cannot_be_exported_or_deleted_as_owned(self):
        def wrong_create_reply(args):
            result = self.host(args)
            if args[:3] == ["xcrun", "simctl", "create"]:
                result.stdout = OLD + "\n"
            return result
        with patch.object(route, "run", wrong_create_reply), self.assertRaises(ValueError):
            route.prepare(self.env, self.directory)
        self.assertFalse((self.directory / "environment").exists())
        route.cleanup(self.directory)
        self.assertEqual([device["udid"] for device in self.host.document["devices"][RUNTIME]], [OLD])
        self.assertNotIn(["xcrun", "simctl", "delete", OLD], self.host.calls)

    def test_changed_ownership_refuses_cleanup_and_preserves_both_devices(self):
        route.prepare(self.env, self.directory)
        self.host.document["devices"][RUNTIME][-1]["name"] = "Someone else"
        with self.assertRaises(ValueError):
            route.cleanup(self.directory)
        self.assertFalse(any("shutdown" in call or "delete" in call for call in self.host.calls))

    def test_cleanup_failure_is_retained_and_not_reported_as_deleted(self):
        route.prepare(self.env, self.directory)
        self.host.fail_delete = True
        with self.assertRaises(RuntimeError):
            route.cleanup(self.directory)
        self.assertEqual(json.loads((self.directory / "cleanup.json").read_text())["deleteExit"], 1)
        self.assertEqual(len(self.host.document["devices"][RUNTIME]), 2)

    def test_execution_requires_all_selected_rows_without_skips_or_unknowns(self):
        selectors = SELECTORS.split()
        passing = f"  {selectors[0]} 1 1 0 0 0\n  {selectors[1]} 4 4 0 0 0\n"
        (self.directory / "test.log").write_text(passing)
        route.verify_execution(self.env, self.directory)
        for counts in ("1 0 1 0 0", "1 0 0 0 0", "0 0 0 0 0", "1 1 0 1 0", "1 0 0 0 1", "? 1 0 0 0"):
            (self.directory / "test.log").write_text(passing.replace("1 1 0 0 0", counts))
            with self.subTest(counts=counts), self.assertRaises(ValueError):
                route.verify_execution(self.env, self.directory)
        (self.directory / "test.log").write_text(passing.splitlines()[1])
        with self.assertRaises(ValueError):
            route.verify_execution(self.env, self.directory)

    def test_partly_missing_resolved_suite_is_not_platform_proof(self):
        first, suite = SELECTORS.split()
        (self.directory / "test.log").write_text(f"  {first} 1 1 0 0 0\n  {suite} 4 1 0 0 0\n")
        self.host.results = result_document(CASES[:2])
        with self.assertRaises(ValueError):
            route.verify_execution(self.env, self.directory)

    def test_repeated_attempts_cannot_replace_missing_resolved_cases(self):
        first, suite = SELECTORS.split()
        (self.directory / "test.log").write_text(f"notice: re-running the interrupted suite(s) once, alone: {suite}\n"
                                               f"  {first} 1 1 0 0 0\n  {suite} 4 4 0 0 0\n")
        self.host.retry_results = result_document([CASES[1]] * 4)
        Path(self.env["RESULT_BUNDLE"] + "-retry").mkdir()
        for initial in (CASES[:2], CASES):
            self.host.results = result_document(initial)
            with self.subTest(initial=len(initial)), self.assertRaises(ValueError):
                route.verify_execution(self.env, self.directory)

    def test_complete_parameterized_declarations_and_recovered_retry_are_proof(self):
        first, suite = SELECTORS.split()
        (self.directory / "test.log").write_text(f"notice: re-running the interrupted suite(s) once, alone: {suite}\n"
                                               f"  {first} 1 1 0 0 0\n  {suite} 4 4 0 0 0\n")
        cases = [CASES[0], (suite + "/test0(role:)", "Passed"), (CASES[2][0], "Failed")] + CASES[3:]
        self.host.results = result_document(cases)
        # Parameter invocations live below the declaration's Test Case. They
        # are not extra resolved declarations or a substitute for another one.
        self.host.results["testNodes"][1]["children"][0]["children"] = [
            {"nodeType": "Test Case Run", "name": "member", "result": "Passed"},
            {"nodeType": "Test Case Run", "name": "owner", "result": "Passed"}]
        self.host.retry_results = copy.deepcopy(self.host.results)
        self.host.retry_results["testNodes"] = self.host.retry_results["testNodes"][1:]
        self.host.retry_results["testNodes"][0]["children"][1]["result"] = "Passed"
        Path(self.env["RESULT_BUNDLE"] + "-retry").mkdir()
        route.verify_execution(self.env, self.directory)

    def test_actual_wrapper_summary_uses_compatible_case_and_retry_accounting(self):
        wrapper = (Path(__file__).resolve().parent / "xcodebuild.sh").read_text()
        code = "".join(wrapper.split(name + "='", 1)[1].split("\n'\n", 1)[0]
                       for name in ("ONLY_TESTING_MATCH_PY", "ONLY_TESTING_SUMMARY_PY"))
        first, suite = SELECTORS.split()
        parameterized = [CASES[0], (suite + "/test0(role:)", "Passed")] + CASES[2:]
        for label, primary, retried, accepted in (
            ("complete", parameterized, None, True),
            ("missing", CASES[:2], None, False),
            ("recovered", parameterized, parameterized[1:], True),
            ("duplicates", CASES, [CASES[1]] * 4, False),
        ):
            with self.subTest(label=label):
                self.host.results = result_document(primary)
                results = self.directory / "wrapper-primary.json"
                results.write_text(json.dumps(self.host.results))
                env = {"ONLY_TESTING_RESOLVED": f"1\t{first}\n4\t{suite}"}
                retry_bundle = Path(self.env["RESULT_BUNDLE"] + "-retry")
                prefix = ""
                if retried is not None:
                    self.host.retry_results = result_document(retried)
                    retry_results = self.directory / "wrapper-retry.json"
                    retry_results.write_text(json.dumps(self.host.retry_results))
                    env.update(ONLY_TESTING_RETRY_RESULTS=str(retry_results), ONLY_TESTING_RETRY_SELECTORS=suite)
                    retry_bundle.mkdir(exist_ok=True)
                    prefix = f"notice: re-running the interrupted suite(s) once, alone: {suite}\n"
                result = subprocess.run([sys.executable, "-S", "-c", code, str(results), "", self.env["RESULT_BUNDLE"],
                                         first, suite], env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                (self.directory / "test.log").write_text(prefix + result.stdout)
                if accepted:
                    route.verify_execution(self.env, self.directory)
                else:
                    with self.assertRaises(ValueError):
                        route.verify_execution(self.env, self.directory)

    def wrapper_python(self, *names):
        wrapper = (Path(__file__).resolve().parent / "xcodebuild.sh").read_text()
        return "".join(wrapper.split(name + "='", 1)[1].split("\n'\n", 1)[0] for name in names)

    def resolve_catalog(self, identifiers, selectors=None, extra_env=None):
        catalog = self.directory / "catalog.json"
        catalog.write_text(json.dumps({"values": [{"enabledTests": [{"identifier": item} for item in identifiers]}]}))
        code = self.wrapper_python("ONLY_TESTING_MATCH_PY", "ONLY_TESTING_RESOLVER_PY")
        return subprocess.run([sys.executable, "-S", "-c", code, str(catalog), *(selectors or SELECTORS.split())],
                              env=extra_env or {}, text=True, capture_output=True)

    def actual_summary(self, primary, retried=None, interrupted=None):
        first, suite = SELECTORS.split()
        resolved = self.resolve_catalog([item[0] for item in CASES])
        self.assertEqual(resolved.returncode, 0, resolved.stderr)
        self.assertEqual(resolved.stdout, f"1\t{first}\n4\t{suite}\n")
        # The baseline helper has no identity input yet. Supply the intended
        # proof from this known catalog while its existing resolver verifies
        # every identity; the correction will consume the resolver's export.
        (self.directory / "resolved-tests.json").write_text(json.dumps({"version": 1, "selectors": {
            first: [CASES[0][0]], suite: [item[0] for item in CASES[1:]]}}))
        self.host.results = result_document(primary)
        result_path = self.directory / "wrapper-primary.json"
        result_path.write_text(json.dumps(self.host.results))
        env = {"ONLY_TESTING_RESOLVED": resolved.stdout}
        prefix = ""
        if retried is not None:
            self.host.retry_results = result_document(retried)
            retry_path = self.directory / "wrapper-retry.json"
            retry_path.write_text(json.dumps(self.host.retry_results))
            Path(self.env["RESULT_BUNDLE"] + "-retry").mkdir(exist_ok=True)
            env.update(ONLY_TESTING_RETRY_RESULTS=str(retry_path), ONLY_TESTING_RETRY_SELECTORS=interrupted)
            prefix = f"notice: re-running the interrupted suite(s) once, alone: {interrupted}\n"
        code = self.wrapper_python("ONLY_TESTING_MATCH_PY", "ONLY_TESTING_SUMMARY_PY")
        summary = subprocess.run([sys.executable, "-S", "-c", code, str(result_path), "", self.env["RESULT_BUNDLE"],
                                  *SELECTORS.split()], env=env, text=True, capture_output=True)
        self.assertEqual(summary.returncode, 0, summary.stderr)
        (self.directory / "test.log").write_text(prefix + summary.stdout)

    def test_retry_cannot_replace_uninterrupted_primary_outcomes(self):
        suite = SELECTORS.split()[1]
        for result in ("Skipped", "Failed", None):
            with self.subTest(primary=result):
                primary = [(CASES[0][0], result)] if result else []
                self.actual_summary(primary, CASES, suite)
                with self.assertRaises(ValueError):
                    route.verify_execution(self.env, self.directory)

    def test_same_count_wrong_identity_cannot_replace_enumerated_test(self):
        wrong = SELECTORS.split()[1] + "/test99()"
        rejected = self.resolve_catalog([item[0] for item in CASES], [wrong])
        self.assertEqual(rejected.returncode, 1, rejected.stderr)
        self.assertIn("matched no test", rejected.stderr)
        self.actual_summary(CASES[:-1] + [(wrong, "Passed")])
        with self.assertRaises(ValueError):
            route.verify_execution(self.env, self.directory)

    def test_complete_catalog_and_interrupted_only_retry_are_proof(self):
        self.actual_summary(CASES)
        route.verify_execution(self.env, self.directory)
        self.actual_summary(CASES[:1], CASES[1:], SELECTORS.split()[1])
        route.verify_execution(self.env, self.directory)

    def test_optional_identity_export_preserves_resolver_output_and_exits(self):
        first, suite = SELECTORS.split()
        evidence = self.directory / "optional.json"
        identifiers = [CASES[0][0], suite + "/test0(role:)"] + [item[0] for item in CASES[2:]]
        requested = [first, suite, suite + "/test0"]
        for selectors, expected_exit in ((requested, 0), ([suite + "/test99"], 1),
                                         (["-skip-testing:IntentUITests", first], 1)):
            with self.subTest(selectors=selectors):
                evidence.unlink(missing_ok=True)
                default = self.resolve_catalog(identifiers, selectors)
                self.assertFalse(evidence.exists())
                exported = self.resolve_catalog(identifiers, selectors, {"ONLY_TESTING_IDENTITIES_PATH": str(evidence)})
                self.assertEqual(default.returncode, expected_exit, default.stderr)
                self.assertEqual((exported.returncode, exported.stdout, exported.stderr),
                                 (default.returncode, default.stdout, default.stderr))
                if expected_exit == 0:
                    self.assertEqual(json.loads(evidence.read_text()), {"version": 1, "selectors": {
                        first: identifiers[:1], suite: identifiers[1:], suite + "/test0": identifiers[1:2]}})
                else:
                    self.assertFalse(evidence.exists())

    def test_identity_export_failure_is_unverified_without_changing_default(self):
        identities = [item[0] for item in CASES]
        failed = self.resolve_catalog(identities, extra_env={"ONLY_TESTING_IDENTITIES_PATH": str(self.directory)})
        self.assertEqual(failed.returncode, 2, failed.stderr)
        self.assertIn("requested resolved identity export could not be written", failed.stderr)
        default = self.resolve_catalog(identities)
        self.assertEqual(default.returncode, 0, default.stderr)
        self.assertEqual(failed.stdout, default.stdout)

    def check_phase_transcript(self, step_name, phase):
        workflow = (Path(__file__).resolve().parent.parent / ".github/workflows/ci.yml").read_text()
        section = workflow.split("      - name: " + step_name + "\n", 1)[1].split("\n      - name:", 1)[0]
        lines = section.splitlines()
        index = next(i for i, line in enumerate(lines) if line.startswith("        run:"))
        command = lines[index].split("run:", 1)[1].strip()
        if command == "|":
            command = textwrap.dedent("\n".join(lines[index + 1:]))
        for family in ("iphone", "ipad"):
            for exit_code in (0, 65, 80):
                with self.subTest(phase=phase, family=family, exit_code=exit_code), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    for name in ("scripts", "Intent", "IntentTests", "runner", "evidence"):
                        (root / name).mkdir()
                    (root / "Info-visionOS.plist").write_text("fixture")
                    (root / "Intent/owned-source").write_text("retained")
                    stub = root / "scripts/xcodebuild.sh"
                    stub.write_text('#!/usr/bin/env bash\nprintf "primary stdout\\n"\nprintf "crash/retry stderr\\n" >&2\nprintf "retry stdout\\n"\nexit "$STUB_TEST_EXIT"\n')
                    stub.chmod(0o755)
                    env = {"PATH": os.environ["PATH"], "SIMULATOR_FAMILY": family, "RUNNER_TEMP": str(root / "runner"),
                           "IPAD_EVIDENCE_DIR": str(root / "evidence"), "STUB_TEST_EXIT": str(exit_code)}
                    result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", command], cwd=root, env=env,
                                            text=True, capture_output=True)
                    self.assertEqual(result.returncode, exit_code, result.stderr)
                    self.assertEqual((root / "Intent/owned-source").read_text(), "retained")
                    transcript = root / "evidence" / (phase + ".log")
                    if family == "ipad":
                        self.assertTrue(transcript.exists(), f"{phase} transcript missing from the uploaded evidence directory")
                        self.assertEqual(transcript.read_text(), "primary stdout\ncrash/retry stderr\nretry stdout\n")
                    else:
                        self.assertFalse(transcript.exists(), "Default iPhone path unexpectedly changed")

    def test_keychain_phase_retains_failure_and_retry_transcripts(self):
        self.check_phase_transcript("Run Keychain conformance and existing registry/publisher tests", "keychain")

    def test_source_moved_phase_retains_failure_and_retry_transcripts(self):
        self.check_phase_transcript("Source-independence check (ios#320)", "source-moved")

    def test_workflow_retains_required_default_paths_and_always_collects_owned_cleanup(self):
        workflow = (Path(__file__).resolve().parent.parent / ".github/workflows/ci.yml").read_text()
        build = workflow.split("  build-and-test:\n", 1)[1].split("  ios-ui-tests:\n", 1)[0]
        self.assertIn("(inputs.only_testing != '' || inputs.simulator_family == 'ipad') && 'iOS Filtered Tests (non-gating)' || 'iOS Build & Test'", build)
        self.assertIn("echo \"SIM_UDID=$(scripts/xcodebuild.sh pick-simulator)\" >> \"$GITHUB_ENV\"", build)
        self.assertIn("scripts/xcodebuild.sh test-without-building-unit", build)
        self.assertIn("scripts/xcodebuild.sh test-ios-unit", build)
        self.assertIn("name: Source-independence check", build)
        self.assertIn("set -o pipefail\n            scripts/xcodebuild.sh test-without-building 2>&1 | tee", build)
        self.assertIn("name: Clean up owned iPad simulator\n        if: always() && env.SIMULATOR_FAMILY == 'ipad'", build)
        self.assertIn("name: Upload iPad execution evidence\n        if: always() && env.SIMULATOR_FAMILY == 'ipad'", build)
        self.assertLess(build.index("ci_simulator.py cleanup"), build.index("name: Upload iPad execution evidence"))
        self.assertNotIn("${{ inputs", "\n".join(line for line in build.splitlines() if line.startswith("          ") and not line.lstrip().startswith("ONLY_TESTING:")))


if __name__ == "__main__":
    unittest.main()
