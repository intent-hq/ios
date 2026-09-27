#!/usr/bin/env python3
"""Disposable simulator/CI contract tests; no Xcode or real devices are used."""

import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import ci_simulator as route


RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
TYPE = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4"
OLD = "11111111-1111-4111-8111-111111111111"
NEW = "22222222-2222-4222-8222-222222222222"
SELECTORS = "IntentUITests/HomeActionMenuUITests/testIPadConversationKeepsSendAndMenuAvailable IntentTests/PersonalPairingPermissionsTests"


class Host:
    def __init__(self):
        self.calls = []
        self.fail_create = False
        self.fail_delete = False
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
        else:
            raise AssertionError(f"Unexpected host command: {args}")
        return subprocess.CompletedProcess(args, status, output, "injected failure" if status else "")


class SimulatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.env = {"SIMULATOR_FAMILY": "ipad", "GITHUB_EVENT_NAME": "workflow_dispatch", "ONLY_TESTING": SELECTORS,
                    "GITHUB_ENV": str(self.directory / "environment"), "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"}
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
