#!/usr/bin/env python3
"""Disposable simulator/CI contract tests; no Xcode or real devices are used."""

import copy
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import threading
import unittest
from unittest.mock import patch
import uuid

import ci_simulator as route


RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
TYPE = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4"
PHONE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-16"
OLD = "11111111-1111-4111-8111-111111111111"
NEW = "22222222-2222-4222-8222-222222222222"
SELECTORS = "IntentUITests/HomeActionMenuUITests/testIPadConversationKeepsDraftAndRailAvailable IntentTests/PersonalPairingPermissionsTests"


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
        self.sdk_version = "26.2"
        self.lock = threading.Lock()
        self.created = 0
        self.results = result_document(CASES)
        self.retry_results = result_document([])
        self.document = {
            "runtimes": [{"identifier": RUNTIME, "version": "26.2", "name": "iOS 26.2", "isAvailable": True}],
            "devicetypes": [{"identifier": TYPE, "name": "iPad Pro (M4)", "productFamily": "iPad"},
                            {"identifier": PHONE_TYPE, "name": "iPhone 16", "productFamily": "iPhone"}],
            "devices": {RUNTIME: [{"udid": OLD, "name": "My existing iPad", "deviceTypeIdentifier": TYPE, "isAvailable": True}]},
        }

    def __call__(self, args):
        with self.lock:
            return self.call(args)

    def call(self, args):
        self.calls.append(args)
        status, output = 0, ""
        if args == ["xcrun", "simctl", "list", "--json"]:
            output = json.dumps(self.document)
        elif args[:3] == ["xcrun", "simctl", "create"]:
            udid = NEW if self.created == 0 else str(uuid.uuid4()).upper()
            self.created += 1
            self.document["devices"].setdefault(args[5], []).append({"udid": udid, "name": args[3],
                "deviceTypeIdentifier": args[4], "isAvailable": True})
            status, output = int(self.fail_create), udid + "\n"
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
        elif args == ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"]:
            output = self.sdk_version + "\n"
        elif args[:6] == ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path"]:
            output = json.dumps(self.retry_results if args[6].endswith("-retry") else self.results)
        else:
            raise AssertionError(f"Unexpected host command: {args}")
        return subprocess.CompletedProcess(args, status, output, "injected failure" if status else "")


class OrdinaryCITests(unittest.TestCase):
    def test_full_pre_pr_gate_requires_unfiltered_iphone_dispatch(self):
        base = {"GITHUB_EVENT_NAME": "workflow_dispatch", "FULL_PRE_PR_GATE": "1"}
        self.assertEqual(route.validate(base), ("iphone", []))
        for changes in (
            {"ONLY_TESTING": "IntentTests"},
            {"ONLY_TESTING": "IntentUITests/ScriptMonitorsUITests"},
            {"SIMULATOR_FAMILY": "ipad", "ONLY_TESTING": SELECTORS},
            {"GITHUB_EVENT_NAME": "pull_request"},
            {"GITHUB_EVENT_NAME": "merge_group"},
            {"FULL_PRE_PR_GATE": "true"},
        ):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                route.validate(dict(base, **changes))
        self.assertEqual(route.validate({"GITHUB_EVENT_NAME": "pull_request"}), ("iphone", []))

    def test_full_gate_builds_ios_through_the_wrapper(self):
        workflow = (Path(__file__).resolve().parent.parent / ".github/workflows/ci.yml").read_text()
        section = workflow.split("      - name: Build iOS for pre-PR gate\n", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn("if: env.FULL_PRE_PR_GATE == '1'", section)
        command = section.split("        run: ", 1)[1].strip()
        for status in (0, 65):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "scripts").mkdir()
                wrapper = root / "scripts/xcodebuild.sh"
                wrapper.write_text('#!/bin/bash\nprintf "%s\\n" "$*" > calls\nexit ' + str(status) + '\n')
                wrapper.chmod(0o755)
                result = subprocess.run(["bash", "-e", "-c", command], cwd=root, capture_output=True, text=True)
                self.assertEqual(result.returncode, status)
                self.assertEqual((root / "calls").read_text().splitlines(), ["build-ios"])

    def test_full_pre_pr_gate_executes_wrapper_once_and_preserves_failure_log(self):
        workflow = (Path(__file__).resolve().parent.parent / ".github/workflows/ci.yml").read_text()
        section = workflow.split("      - name: Run full pre-PR gate\n", 1)[1].split("\n      - name:", 1)[0]
        command = textwrap.dedent(section.split("        run: |\n", 1)[1])
        for status in (0, 65):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "scripts").mkdir()
                wrapper = root / "scripts/xcodebuild.sh"
                wrapper.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> calls\necho gate-output\necho gate-error >&2\nexit ' + str(status) + '\n')
                wrapper.chmod(0o755)
                result = subprocess.run(["bash", "-e", "-c", command], cwd=root, capture_output=True, text=True)
                self.assertEqual(result.returncode, status)
                self.assertEqual((root / "calls").read_text().splitlines(), ["test-ios"])
                self.assertEqual((root / "pre-pr-gate.log").read_text(), "gate-output\ngate-error\n")
        build = workflow.split("  build-and-test:\n", 1)[1].split("  ios-ui-test-lanes:\n", 1)[0]
        for name in ("Build for testing", "Run unit tests"):
            step = build.split("      - name: " + name + "\n", 1)[1].split("\n      - name:", 1)[0]
            self.assertIn("if: env.FULL_PRE_PR_GATE != '1'", step)
        ui_job = workflow.split("  ios-ui-tests:\n", 1)[1].split("    steps:\n", 1)[0]
        self.assertIn("inputs.pre_pr_gate", ui_job)
        lanes = workflow.split("  ios-ui-test-lanes:\n", 1)[1].split("    steps:\n", 1)[0]
        self.assertIn("inputs.pre_pr_gate", lanes)
        self.assertIn("TestResults-retry", build)
        self.assertIn("pre-pr-gate.log", build)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.host = Host()
        self.patcher = patch.object(route, "run", self.host)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def allocation(self, family="iphone", name="job"):
        directory = self.directory / name
        directory.mkdir()
        env = {"SIMULATOR_FAMILY": family, "GITHUB_ENV": str(directory / "environment"),
               "GITHUB_JOB": name, "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2",
               "GITHUB_EVENT_NAME": "pull_request"}
        return env, directory

    def test_unfiltered_ci_allocates_both_families_and_keeps_existing_devices(self):
        for family, device_type in (("iphone", PHONE_TYPE), ("ipad", TYPE)):
            with self.subTest(family=family):
                env, directory = self.allocation(family, family)
                route.prepare_ci(env, directory)
                plan = json.loads((directory / "ownership.json").read_text())
                self.assertEqual(plan["family"], family)
                self.assertEqual(plan["sdkVersion"], "26.2")
                self.assertEqual(plan["deviceType"]["identifier"], device_type)
                self.assertEqual(plan["runtime"]["identifier"], RUNTIME)
                self.assertIn(f"{family}-123-2", plan["name"])
                self.assertEqual(plan["provenance"]["GITHUB_JOB"], family)
                self.assertEqual((directory / "environment").read_text(), f"SIM_UDID={plan['createdUDID']}\n")
                route.cleanup(directory)
                route.cleanup(directory)  # Idempotent after deletion.
                self.assertEqual([device["udid"] for _, device in route.device_rows(self.host.document)], [OLD])
        self.assertFalse(any("boot" in call for call in self.host.calls))

    def test_iphone_creation_does_not_require_a_preexisting_phone(self):
        self.host.document["devices"] = {}
        env, directory = self.allocation()
        del env["SIMULATOR_FAMILY"]
        route.prepare_ci(env, directory)
        self.assertEqual(json.loads((directory / "ownership.json").read_text())["family"], "iphone")

    def test_both_families_use_newest_available_ios_runtime_matching_sdk_major(self):
        for version, available in (("26.3.1", True), ("26.4", False), ("27.0", True), ("18.6", True)):
            runtime = RUNTIME.rsplit("iOS-", 1)[0] + "iOS-" + version.replace(".", "-")
            self.host.document["runtimes"].append({"identifier": runtime, "version": version,
                                                  "name": "iOS " + version, "isAvailable": available})
            self.host.document["devices"][runtime] = copy.deepcopy(self.host.document["devices"][RUNTIME])
        self.host.document["runtimes"].append({"identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-26-9",
                                              "version": "26.9", "name": "tvOS 26.9", "isAvailable": True})
        for family in ("iphone", "ipad"):
            with self.subTest(family=family):
                env, directory = self.allocation(family, family)
                route.prepare_ci(env, directory)
                plan = json.loads((directory / "ownership.json").read_text())
                self.assertEqual(plan["runtime"]["version"], "26.3.1")
                self.assertIn(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], self.host.calls)

    def test_unusable_sdk_or_runtime_fails_before_creation_for_both_families(self):
        for family in ("iphone", "ipad"):
            for version in ("", "not-a-version", "27.0", "18.6"):
                with self.subTest(family=family, sdk=version):
                    env, directory = self.allocation(family, family + version)
                    self.host.sdk_version = version
                    with self.assertRaises(ValueError):
                        route.prepare_ci(env, directory)
                    self.assertFalse((directory / "ownership.json").exists())
                    self.assertFalse((directory / "environment").exists())
        self.assertFalse(any("create" in call for call in self.host.calls))

    def test_missing_family_device_never_falls_back(self):
        for family in ("iphone", "ipad"):
            with self.subTest(family=family):
                self.host.document = copy.deepcopy(Host().document)
                if family == "iphone":
                    self.host.document["devicetypes"][1].update(identifier=PHONE_TYPE + "-Pro", name="iPhone 16 Pro")
                else:
                    self.host.document["devices"][RUNTIME][0]["isAvailable"] = False
                env, directory = self.allocation(family, family)
                with self.assertRaises(ValueError):
                    route.prepare_ci(env, directory)
        self.assertFalse(any("create" in call for call in self.host.calls))

    def test_invalid_family_is_rejected_without_host_commands(self):
        env, directory = self.allocation("visionos")
        with self.assertRaises(ValueError):
            route.prepare_ci(env, directory)
        self.assertEqual(self.host.calls, [])

    def test_concurrent_jobs_get_distinct_devices_and_cleanup_only_their_own(self):
        first = self.allocation(name="unit")
        second = self.allocation(name="ui")
        barrier = threading.Barrier(2, timeout=10)
        local = threading.local()

        def simultaneous_inventory(args):
            result = self.host(args)
            if args == ["xcrun", "simctl", "list", "--json"] and not getattr(local, "listed", False):
                local.listed = True
                barrier.wait()  # Both jobs see the same pre-creation inventory.
            return result

        with patch.object(route, "run", simultaneous_inventory), ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(route.prepare_ci, *item) for item in (first, second)]
            for future in futures:
                future.result(timeout=15)
        plans = [json.loads((directory / "ownership.json").read_text()) for _, directory in (first, second)]
        self.assertNotEqual(plans[0]["name"], plans[1]["name"])
        self.assertNotEqual(plans[0]["createdUDID"], plans[1]["createdUDID"])
        self.assertEqual(plans[0]["preexisting"], plans[1]["preexisting"])
        route.cleanup(first[1])
        self.assertEqual({device["udid"] for _, device in route.device_rows(self.host.document)},
                         {OLD, plans[1]["createdUDID"]})
        route.cleanup(second[1])
        self.assertEqual([device["udid"] for _, device in route.device_rows(self.host.document)], [OLD])

    def test_shared_evidence_directory_cannot_overwrite_another_creation_intent(self):
        env, directory = self.allocation()
        barrier = threading.Barrier(2, timeout=10)
        original = route.write_json

        def simultaneous_intent(path, value, **kwargs):
            if kwargs.get("exclusive"):
                barrier.wait()
            original(path, value, **kwargs)

        with patch.object(route, "write_json", simultaneous_intent), ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(route.prepare_ci, env, directory) for _ in range(2)]
            outcomes = [future.exception(timeout=15) for future in futures]
        self.assertEqual(sum(error is None for error in outcomes), 1)
        self.assertEqual(sum(isinstance(error, FileExistsError) for error in outcomes), 1)
        self.assertEqual(self.host.created, 1)
        route.cleanup(directory)
        self.assertEqual([device["udid"] for _, device in route.device_rows(self.host.document)], [OLD])

    def test_creation_failure_and_interrupted_evidence_or_export_are_recoverable(self):
        for family in ("iphone", "ipad"):
            for failure in ("create", "creation.json", "ownership.json", "export"):
                with self.subTest(family=family, failure=failure):
                    env, directory = self.allocation(family, family + failure)
                    original = route.write_json

                    def fail_write(path, value, **kwargs):
                        if path.name == failure and not kwargs.get("exclusive"):
                            raise OSError("injected post-create write failure")
                        original(path, value, **kwargs)

                    self.host.fail_create = failure == "create"
                    if failure == "export":
                        env["GITHUB_ENV"] = str(directory / "absent" / "environment")
                    with patch.object(route, "write_json", fail_write), self.assertRaises((OSError, RuntimeError)):
                        route.prepare_ci(env, directory)
                    self.assertFalse((directory / "environment").exists())
                    route.cleanup(directory)
                    self.assertEqual([device["udid"] for _, device in route.device_rows(self.host.document)], [OLD])

    def test_create_requires_complete_receipt_before_mutating_host(self):
        env, directory = self.allocation()
        original = route.write_json

        def reject_intent(path, value, **kwargs):
            if kwargs.get("exclusive"):
                raise OSError("cannot save creation intent")
            original(path, value, **kwargs)

        with patch.object(route, "write_json", reject_intent), self.assertRaises(OSError):
            route.prepare_ci(env, directory)
        route.cleanup(directory)
        self.assertEqual(self.host.created, 0)
        self.assertFalse(any("shutdown" in call or "delete" in call for call in self.host.calls))

    def test_atomic_receipt_replace_failure_preserves_recoverable_intent(self):
        env, directory = self.allocation()
        original = Path.replace

        def fail_replace(path, target):
            if target == directory / "ownership.json":
                raise OSError("interrupted atomic receipt replacement")
            return original(path, target)

        with patch.object(Path, "replace", fail_replace), self.assertRaises(OSError):
            route.prepare_ci(env, directory)
        self.assertIsNone(json.loads((directory / "ownership.json").read_text())["createdUDID"])
        route.cleanup(directory)
        self.assertIn(["xcrun", "simctl", "delete", NEW], self.host.calls)

    def test_returned_preexisting_or_unowned_udid_is_never_exported(self):
        for reply in (OLD, "invalid", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"):
            with self.subTest(reply=reply):
                env, directory = self.allocation(name=reply)

                def wrong_reply(args):
                    result = self.host(args)
                    if args[:3] == ["xcrun", "simctl", "create"]:
                        result.stdout = reply + "\n"
                    return result

                with patch.object(route, "run", wrong_reply), self.assertRaises(ValueError):
                    route.prepare_ci(env, directory)
                self.assertFalse((directory / "environment").exists())
                route.cleanup(directory)
                self.assertEqual([device["udid"] for _, device in route.device_rows(self.host.document)], [OLD])

    def test_ambiguous_or_changed_ownership_never_deletes_devices(self):
        for change in ("name", "deviceTypeIdentifier", "runtime", "duplicate", "createdUDID", "createAttempted"):
            with self.subTest(change=change):
                self.host.document = copy.deepcopy(Host().document)
                env, directory = self.allocation(name=change)
                route.prepare_ci(env, directory)
                device = self.host.document["devices"][RUNTIME][-1]
                if change in ("name", "deviceTypeIdentifier"):
                    device[change] = "someone else's device"
                elif change == "runtime":
                    self.host.document["devices"][RUNTIME].remove(device)
                    self.host.document["devices"]["another runtime"] = [device]
                elif change == "duplicate":
                    self.host.document["devices"][RUNTIME].append(dict(device, udid=str(uuid.uuid4())))
                else:
                    receipt = directory / "ownership.json"
                    plan = json.loads(receipt.read_text())
                    plan[change] = OLD if change == "createdUDID" else False
                    route.write_json(receipt, plan)
                with self.assertRaises(ValueError):
                    route.cleanup(directory)
        self.assertFalse(any("shutdown" in call or "delete" in call for call in self.host.calls))

    def test_cli_prefers_generic_evidence_directory_and_supports_legacy_fallback(self):
        for generic in (True, False):
            with self.subTest(generic=generic):
                env, directory = self.allocation(name=str(generic))
                legacy = directory / "legacy"
                env["IPAD_EVIDENCE_DIR"] = str(legacy)
                evidence = directory / "generic" if generic else legacy
                if generic:
                    env["SIMULATOR_EVIDENCE_DIR"] = str(evidence)
                with patch.dict(os.environ, env, clear=True):
                    with patch.object(sys, "argv", ["ci_simulator.py", "prepare-ci"]):
                        route.main()
                    self.assertTrue((evidence / "ownership.json").exists())
                    if generic:
                        self.assertFalse(legacy.exists())
                    with patch.object(sys, "argv", ["ci_simulator.py", "cleanup"]):
                        route.main()
                self.assertEqual(json.loads((evidence / "cleanup.json").read_text())["deleteExit"], 0)

    def test_cli_retains_failure_evidence_without_exporting_a_destination(self):
        env, directory = self.allocation()
        env["SIMULATOR_EVIDENCE_DIR"] = str(directory)
        self.host.fail_create = True
        with patch.dict(os.environ, env, clear=True), patch.object(sys, "argv", ["ci_simulator.py", "prepare-ci"]):
            with self.assertRaises(RuntimeError):
                route.main()
        self.assertIn("simctl create failed", json.loads((directory / "prepare-ci-error.json").read_text())["error"])
        self.assertFalse((directory / "environment").exists())
        route.cleanup(directory)

    def test_ui_workflow_uses_separate_owned_destinations_and_cleans_failures_or_skips(self):
        scripts = Path(__file__).resolve().parent
        workflow = (scripts.parent / ".github/workflows/ci.yml").read_text()
        job = workflow.split("  ios-ui-test-lanes:\n", 1)[1].split("  ios-ui-tests:\n", 1)[0]

        def step(name):
            section = job.split("      - name: " + name + "\n", 1)[1].split("\n      - name:", 1)[0]
            command = section.split("        run: ", 1)[1]
            return textwrap.dedent(command[2:]) if command.startswith("|\n") else command.strip()

        self.assertIn("fail-fast: false", job)
        self.assertIn("family: [iphone, ipad]", job)
        self.assertIn("matrix.family == 'ipad' && 'depot-macos-latest'", job)
        self.assertLess(job.index("name: Create owned UI simulator"), job.index("name: Pre-boot simulator"))
        cleanup = job.split("      - name: Clean up owned UI simulator\n", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn("if: always()", cleanup)
        for outcome in ("passed", "failed", "skipped", "create-failed"):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                for name in ("scripts", "bin", "runner temp"):
                    (root / name).mkdir()
                (root / "scripts/ci_simulator.py").write_text((scripts / "ci_simulator.py").read_text())
                host_stub = root / "bin/host-stub"
                host_stub.write_text(f"#!{sys.executable}\n" + textwrap.dedent(f"""\
                    import json, os, sys
                    from pathlib import Path
                    sys.path.insert(0, {str(scripts)!r})
                    from test_ci_simulator import Host
                    path = Path(os.environ['HOST_STATE'])
                    state = json.loads(path.read_text()) if path.exists() else None
                    host = Host()
                    if state:
                        host.document, host.created = state['document'], state['created']
                    host.fail_create = os.environ.get('FAIL_CREATE') == '1'
                    result = host([Path(sys.argv[0]).name, *sys.argv[1:]])
                    path.write_text(json.dumps({{'document': host.document, 'created': host.created}}))
                    sys.stdout.write(result.stdout)
                    sys.stderr.write(result.stderr)
                    sys.exit(result.returncode)
                    """))
                host_stub.chmod(0o755)
                for name in ("xcrun", "xcodebuild", "git"):
                    (root / "bin" / name).symlink_to(host_stub)
                wrapper = root / "scripts/xcodebuild.sh"
                wrapper.write_text('#!/bin/bash\nprintf "%s\\n" "$*" "$SIM_UDID" > "$CALLS"\nexit "$TEST_EXIT"\n')
                wrapper.chmod(0o755)
                env = dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"],
                           RUNNER_TEMP=str(root / "runner temp"), GITHUB_ENV=str(root / "environment"),
                           GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="2", GITHUB_JOB="ios-ui-test-lanes",
                           HOST_STATE=str(root / "host.json"),
                           CALLS=str(root / "calls"), TEST_EXIT="65" if outcome == "failed" else "0")
                env.pop("SIMULATOR_EVIDENCE_DIR", None)
                env.pop("IPAD_EVIDENCE_DIR", None)

                def execute(name, overrides=None):
                    return subprocess.run(["bash", "-e", "-o", "pipefail", "-c", step(name)],
                                          cwd=root, env=dict(env, **(overrides or {})), text=True, capture_output=True)

                def import_environment():
                    env.update(line.split("=", 1) for line in (root / "environment").read_text().splitlines())

                lanes = {}
                for family in ("iphone", "ipad"):
                    env["SIMULATOR_FAMILY"] = family
                    result = execute("Use isolated build directory")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    import_environment()
                    result = execute("Create owned UI simulator", {"FAIL_CREATE": "1" if family == "ipad" and outcome == "create-failed" else "0"})
                    self.assertEqual(result.returncode, 1 if family == "ipad" and outcome == "create-failed" else 0, result.stderr)
                    import_environment()
                    lanes[family] = dict(env)
                phone = json.loads((Path(lanes["iphone"]["SIMULATOR_EVIDENCE_DIR"]) / "ownership.json").read_text())
                ipad = json.loads((Path(lanes["ipad"]["SIMULATOR_EVIDENCE_DIR"]) / "ownership.json").read_text())
                self.assertNotEqual(lanes["iphone"]["DERIVED_DATA_DIR"], lanes["ipad"]["DERIVED_DATA_DIR"])
                self.assertNotEqual(phone["createdUDID"], ipad["createdUDID"])
                self.assertEqual(lanes["iphone"]["SIM_UDID"], phone["createdUDID"])
                if outcome != "create-failed":
                    self.assertEqual(lanes["ipad"]["SIM_UDID"], ipad["createdUDID"])
                if outcome != "skipped":
                    if outcome != "create-failed":
                        result = execute("Run iPad sidebar regression tests", lanes["ipad"])
                        self.assertEqual(result.returncode, int(env["TEST_EXIT"]), result.stderr)
                        self.assertEqual((root / "calls").read_text().splitlines(),
                                         ["test-without-building-ui", ipad["createdUDID"]])
                    else:
                        self.assertFalse((root / "calls").exists())
                result = execute("Clean up owned UI simulator", lanes["ipad"])
                self.assertEqual(result.returncode, 0, result.stderr)
                state = json.loads((root / "host.json").read_text())
                self.assertEqual({device["udid"] for _, device in route.device_rows(state["document"])},
                                 {OLD, phone["createdUDID"]})
                result = execute("Clean up owned UI simulator", lanes["iphone"])
                self.assertEqual(result.returncode, 0, result.stderr)
                state = json.loads((root / "host.json").read_text())
                self.assertEqual([device["udid"] for _, device in route.device_rows(state["document"])], [OLD])

    def test_iphone_ui_step_selects_smoke_or_full_and_preserves_failures(self):
        scripts = Path(__file__).resolve().parent
        workflow = (scripts.parent / ".github/workflows/ci.yml").read_text()
        section = workflow.split("      - name: Run UI tests\n", 1)[1].split("\n      - name:", 1)[0]
        command = textwrap.dedent(section.split("        run: |\n", 1)[1])
        smoke_list = (scripts / "ui-smoke-tests.txt").read_text()
        smoke = " ".join(line.split("#", 1)[0].strip() for line in smoke_list.splitlines()).split()
        for full in (False, True):
            for exit_code in (0, 65):
                with self.subTest(full=full, exit_code=exit_code), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    (root / "scripts").mkdir()
                    (root / "scripts/ui-smoke-tests.txt").write_text(smoke_list)
                    wrapper = root / "scripts/xcodebuild.sh"
                    wrapper.write_text(f"#!{sys.executable}\n" + textwrap.dedent("""\
                        import json, os, sys
                        from pathlib import Path
                        Path('calls.json').write_text(json.dumps({
                            'args': sys.argv[1:],
                            'selectors': os.environ['ONLY_TESTING'].split(),
                        }))
                        sys.exit(int(os.environ['TEST_EXIT']))
                        """))
                    wrapper.chmod(0o755)
                    env = dict(os.environ, FULL_UI_SUITE="1" if full else "", TEST_EXIT=str(exit_code),
                               GITHUB_STEP_SUMMARY=str(root / "summary"))
                    result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", command],
                                            cwd=root, env=env, text=True, capture_output=True)
                    self.assertEqual(result.returncode, exit_code, result.stderr)
                    call = json.loads((root / "calls.json").read_text())
                    self.assertEqual(call["args"], ["test-without-building-ui"])
                    self.assertEqual(call["selectors"], ["IntentUITests"] if full else smoke)

    def test_ui_completion_check_rejects_unsuccessful_lanes(self):
        workflow = (Path(__file__).resolve().parent.parent / ".github/workflows/ci.yml").read_text()
        job = workflow.split("  ios-ui-tests:\n", 1)[1].split("  visionos-build:\n", 1)[0]
        self.assertIn("needs: ios-ui-test-lanes", job)
        self.assertIn("always()", job)
        self.assertIn("UI_RESULT: ${{ needs.ios-ui-test-lanes.result }}", job)
        command = textwrap.dedent(job.split("        run: |\n", 1)[1])
        for result in ("success", "failure", "cancelled", "skipped", ""):
            with self.subTest(result=result):
                process = subprocess.run(["bash", "-e", "-c", command],
                                         env=dict(os.environ, UI_RESULT=result), text=True, capture_output=True)
                self.assertEqual(process.returncode, 0 if result == "success" else 1, process.stderr)


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
        self.export_resolution(CASES)

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

    def test_filtered_ipad_dispatch_matches_selected_xcode_sdk_major(self):
        other = RUNTIME.replace("26-2", "27-0")
        self.host.document["runtimes"].append({"identifier": other, "version": "27.0", "name": "iOS 27.0", "isAvailable": True})
        self.host.document["devices"][other] = copy.deepcopy(self.host.document["devices"][RUNTIME])
        route.prepare(self.env, self.directory)
        plan = json.loads((self.directory / "ownership.json").read_text())
        self.assertEqual(plan["runtime"]["identifier"], RUNTIME)
        self.assertEqual(plan["sdkVersion"], "26.2")
        self.assertEqual(plan["selectors"], SELECTORS.split())

    def test_filtered_ipad_dispatch_refuses_runtime_mismatch_before_creation(self):
        self.host.sdk_version = "25.0"
        with self.assertRaises(ValueError):
            route.prepare(self.env, self.directory)
        self.assertFalse(any("create" in call for call in self.host.calls))
        self.assertFalse((self.directory / "environment").exists())

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
        def reject_recorded_udid(path, value, **kwargs):
            if path.name == "ownership.json" and value.get("createdUDID"):
                raise OSError("injected receipt write failure")
            original(path, value, **kwargs)
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
        self.export_resolution(cases)
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
                resolved = self.export_resolution(parameterized if label in ("complete", "recovered") else CASES)
                env = {"ONLY_TESTING_RESOLVED": resolved.stdout}
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

    def export_resolution(self, cases):
        evidence = self.directory / "resolved-tests.json"
        resolved = self.resolve_catalog([item[0] for item in cases], self.env["ONLY_TESTING"].split(),
                                        {"ONLY_TESTING_IDENTITIES_PATH": str(evidence)})
        self.assertEqual(resolved.returncode, 0, resolved.stderr)
        self.assertTrue(evidence.exists(), "Actual resolver did not export matched identities")
        return resolved

    def actual_summary(self, primary, retried=None, interrupted=None, catalog=CASES):
        resolved = self.export_resolution(catalog)
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
                                  *self.env["ONLY_TESTING"].split()], env=env, text=True, capture_output=True)
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

    def test_retry_cannot_import_unrequested_cases_from_an_interrupted_suite(self):
        first, suite = SELECTORS.split()
        self.env["ONLY_TESTING"] = first + " " + suite + "/test0"
        self.actual_summary(CASES[:1], CASES[1:2], suite)
        route.verify_execution(self.env, self.directory)
        self.actual_summary(CASES[:1], CASES[1:], suite)
        with self.assertRaisesRegex(ValueError, "outside the interrupted and requested scope"):
            route.verify_execution(self.env, self.directory)

    def test_valid_retry_preserves_uninterrupted_skips_and_failures(self):
        suite = SELECTORS.split()[1]
        for result in ("Skipped", "Failed"):
            with self.subTest(primary=result):
                self.actual_summary([(CASES[0][0], result)], CASES[1:], suite)
                with self.assertRaises(ValueError):
                    route.verify_execution(self.env, self.directory)

    def test_resolved_parameter_identity_uses_existing_optional_parameter_semantics(self):
        suite = SELECTORS.split()[1]
        catalog = CASES[:1] + [(suite + "/test0(role:)", "Passed")] + CASES[2:]
        for method, accepted in (("test0(role:)", True), ("test0", True),
                                 ("test0(other:)", False), ("test0()", False)):
            with self.subTest(method=method):
                results = CASES[:1] + [(suite + "/" + method, "Passed")] + CASES[2:]
                self.actual_summary(results, catalog=catalog)
                if accepted:
                    route.verify_execution(self.env, self.directory)
                else:
                    with self.assertRaisesRegex(ValueError, "absent or ambiguous"):
                        route.verify_execution(self.env, self.directory)
        ambiguous = catalog[:2] + [(suite + "/test0(other:)", "Passed")] + CASES[3:]
        self.actual_summary(CASES[:1] + [(suite + "/test0", "Passed")] + CASES[2:], catalog=ambiguous)
        with self.assertRaisesRegex(ValueError, "absent or ambiguous"):
            route.verify_execution(self.env, self.directory)

    def test_missing_or_mismatched_identity_evidence_cannot_prove_execution(self):
        self.actual_summary(CASES)
        path = self.directory / "resolved-tests.json"
        correct = json.loads(path.read_text())
        wrong_membership = copy.deepcopy(correct)
        wrong_membership["selectors"][SELECTORS.split()[1]][-1] = "IntentTests/AnotherSuite/test3()"
        duplicate = copy.deepcopy(correct)
        duplicate["selectors"][SELECTORS.split()[1]][-1] = CASES[1][0]
        for value in ({}, {"version": 2, "selectors": correct["selectors"]},
                      {"version": 1, "selectors": {}}, wrong_membership, duplicate):
            with self.subTest(evidence=value):
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    route.verify_execution(self.env, self.directory)
        path.unlink()
        with self.assertRaises(OSError):
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
                    stub.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" > "$CALLS"\n'
                                    'printf "primary stdout\\n"\nprintf "crash/retry stderr\\n" >&2\nprintf "retry stdout\\n"\nexit "$STUB_TEST_EXIT"\n')
                    stub.chmod(0o755)
                    env = {"PATH": os.environ["PATH"], "SIMULATOR_FAMILY": family, "RUNNER_TEMP": str(root / "runner"),
                           "IPAD_EVIDENCE_DIR": str(root / "evidence"), "STUB_TEST_EXIT": str(exit_code),
                           "CALLS": str(root / "calls")}
                    result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", command], cwd=root, env=env,
                                            text=True, capture_output=True)
                    self.assertEqual(result.returncode, exit_code, result.stderr)
                    self.assertEqual((root / "calls").read_text().strip(),
                                     "test-without-building-unit" if phase == "keychain" else "test-without-building")
                    self.assertEqual((root / "Intent/owned-source").read_text(), "retained")
                    transcript = root / "evidence" / (phase + ".log")
                    if family == "ipad":
                        self.assertTrue(transcript.exists(), f"{phase} transcript missing from the uploaded evidence directory")
                        self.assertEqual(transcript.read_text(), "primary stdout\ncrash/retry stderr\nretry stdout\n")
                    else:
                        self.assertFalse(transcript.exists(), "Default iPhone path unexpectedly changed")

    def test_keychain_phase_retains_failure_and_retry_transcripts(self):
        self.check_phase_transcript("Run Keychain conformance and existing registry/publisher tests", "keychain")

    def test_keychain_pass_only_runs_for_filtered_dispatches_and_reuses_the_build(self):
        workflow = (Path(__file__).resolve().parent.parent / ".github/workflows/ci.yml").read_text()
        section = workflow.split("      - name: Run Keychain conformance and existing registry/publisher tests\n", 1)[1].split("\n      - name:", 1)[0]
        condition = section.split("        if: ${{ ", 1)[1].split(" }}", 1)[0]
        condition = condition.replace("github.event_name", '"$EVENT"').replace("inputs.only_testing", '"$SELECTION"')
        command = textwrap.dedent(section.split("        run: |\n", 1)[1])
        selectors = section.split("          ONLY_TESTING: ", 1)[1].splitlines()[0]
        for family in ("iphone", "ipad"):
            for event in ("pull_request", "merge_group", "schedule", "workflow_dispatch"):
                for selection in ("", "IntentUITests", SELECTORS):
                    with self.subTest(family=family, event=event, selection=selection), tempfile.TemporaryDirectory() as temporary:
                        root = Path(temporary)
                        (root / "scripts").mkdir()
                        stub = root / "scripts/xcodebuild.sh"
                        stub.write_text('#!/bin/bash\nprintf "%s\\n" "$*" "$ONLY_TESTING" > "$CALLS"\n')
                        stub.chmod(0o755)
                        env = {"PATH": os.environ["PATH"], "EVENT": event, "SELECTION": selection,
                               "SIMULATOR_FAMILY": family, "ONLY_TESTING": selectors,
                               "CALLS": str(root / "calls"), "IPAD_EVIDENCE_DIR": str(root)}
                        result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c",
                                                 f"if [[ {condition} ]]; then\n{command}\nfi"],
                                                cwd=root, env=env, text=True, capture_output=True)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        if event == "workflow_dispatch" and selection == SELECTORS:
                            self.assertEqual((root / "calls").read_text().splitlines(), ["test-without-building-unit", selectors])
                            self.assertEqual(set(selectors.split()), {
                                "IntentTests/BackendKeychainConformanceTests", "IntentTests/BackendKeychainFixtureTests",
                                "IntentTests/SyncedBackendRegistryTests", "IntentTests/SyncedBackendPublisherTests"})
                        else:
                            self.assertFalse((root / "calls").exists())

    def test_source_moved_phase_retains_failure_and_retry_transcripts(self):
        self.check_phase_transcript("Source-independence check (ios#320)", "source-moved")

    def test_selected_tests_preserve_ui_build_pairing_and_ipad_evidence(self):
        workflow = (Path(__file__).resolve().parent.parent / ".github/workflows/ci.yml").read_text()
        section = workflow.split("      - name: Run unit tests\n", 1)[1].split("\n      - name:", 1)[0]
        command = textwrap.dedent(section.split("        run: |\n", 1)[1])
        cases = [("iphone", "", "test-without-building-unit"),
                 ("iphone", "IntentUITests", "test-without-building-ui"),
                 ("iphone", SELECTORS, "test-without-building"),
                 ("ipad", SELECTORS, "test-without-building")]
        for family, selectors, subcommand in cases:
            for exit_code in (0, 65):
                with self.subTest(family=family, selectors=selectors, exit_code=exit_code), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    (root / "scripts").mkdir()
                    evidence = root / "evidence"
                    evidence.mkdir()
                    stub = root / "scripts/xcodebuild.sh"
                    stub.write_text('#!/usr/bin/env bash\n'
                                    'printf "%s\\n" "$*" "$ONLY_TESTING" "${ONLY_TESTING_IDENTITIES_PATH:-}" > "$CALLS"\n'
                                    'printf "test stdout\\n"\nprintf "test stderr\\n" >&2\nexit "$STUB_TEST_EXIT"\n')
                    stub.chmod(0o755)
                    env = {"PATH": os.environ["PATH"], "SIMULATOR_FAMILY": family, "ONLY_TESTING": selectors,
                           "IPAD_EVIDENCE_DIR": str(evidence), "CALLS": str(root / "calls"),
                           "STUB_TEST_EXIT": str(exit_code)}
                    result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", command], cwd=root, env=env,
                                            text=True, capture_output=True)
                    self.assertEqual(result.returncode, exit_code, result.stderr)
                    identities = str(evidence / "resolved-tests.json") if family == "ipad" else ""
                    self.assertEqual((root / "calls").read_text().splitlines(), [subcommand, selectors, identities])
                    if family == "ipad":
                        self.assertEqual((evidence / "test.log").read_text(), "test stdout\ntest stderr\n")
                    else:
                        self.assertFalse((evidence / "test.log").exists())

    def test_validation_step_initializes_and_persists_runner_evidence_directory(self):
        scripts = Path(__file__).resolve().parent
        workflow = (scripts.parent / ".github/workflows/ci.yml").read_text()
        section = workflow.split("      - name: Validate simulator request\n", 1)[1].split("\n      - name:", 1)[0]
        lines = section.splitlines()
        index = next(i for i, line in enumerate(lines) if line.startswith("        run:"))
        command = lines[index].split("run:", 1)[1].strip()
        if command == "|":
            command = textwrap.dedent("\n".join(lines[index + 1:]))
        for family in ("iphone", "ipad"):
            with self.subTest(family=family), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "scripts").mkdir()
                (root / "scripts/ci_simulator.py").write_text((scripts / "ci_simulator.py").read_text())
                runner = root / "runner temp with spaces"
                runner.mkdir()
                environment = root / "github-environment"
                directory = runner / "intent-simulator-123-2-unit"
                env = {"PATH": os.environ["PATH"], "RUNNER_TEMP": str(runner), "GITHUB_ENV": str(environment),
                       "SIMULATOR_EVIDENCE_DIR": str(directory),
                       "SIMULATOR_FAMILY": family, "GITHUB_EVENT_NAME": "workflow_dispatch", "ONLY_TESTING": SELECTORS}
                result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", command], cwd=root, env=env,
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads((directory / "request.json").read_text())["family"], family)
                self.assertEqual(environment.read_text(), f"IPAD_EVIDENCE_DIR={directory}\n")
        job_inputs = workflow.split("  build-and-test:\n", 1)[1].split("    steps:\n", 1)[0]
        self.assertNotIn("${{ runner.", job_inputs, "Runner context is unavailable in job-level inputs")

    def test_workflow_retains_required_default_paths_and_always_collects_owned_cleanup(self):
        workflow = (Path(__file__).resolve().parent.parent / ".github/workflows/ci.yml").read_text()
        build = workflow.split("  build-and-test:\n", 1)[1].split("  ios-ui-test-lanes:\n", 1)[0]
        self.assertIn("(inputs.only_testing != '' || inputs.simulator_family == 'ipad') && 'iOS Filtered Tests (non-gating)' || 'iOS Build & Test'", build)
        self.assertIn("scripts/xcodebuild.sh test-without-building-unit", build)
        self.assertIn("name: Source-independence check", build)
        self.assertIn("set -o pipefail\n            scripts/xcodebuild.sh test-without-building 2>&1 | tee", build)
        self.assertIn("name: Clean up owned simulator\n        if: always() && env.SIMULATOR_EVIDENCE_DIR != ''", build)
        self.assertIn("name: Upload iPad execution evidence\n        if: always() && env.SIMULATOR_FAMILY == 'ipad'", build)
        self.assertLess(build.index("ci_simulator.py cleanup"), build.index("name: Upload iPad execution evidence"))
        self.assertNotIn("${{ inputs", "\n".join(line for line in build.splitlines() if line.startswith("          ") and not line.lstrip().startswith("ONLY_TESTING:")))

    def test_simulator_selection_preserves_filtered_ipad_and_owns_ordinary_devices(self):
        workflow = (Path(__file__).resolve().parent.parent / ".github/workflows/ci.yml").read_text()
        build = workflow.split("  build-and-test:\n", 1)[1].split("  ios-ui-test-lanes:\n", 1)[0]
        step = build.split("      - name: Create owned simulator\n", 1)[1].split("\n      - name:", 1)[0]
        command = textwrap.dedent(step.split("        run: |\n", 1)[1])
        for family in ("iphone", "ipad"):
            for runner in ("github-hosted", "self-hosted"):
                for exit_code in (0, 1):
                    with self.subTest(family=family, runner=runner, exit_code=exit_code), tempfile.TemporaryDirectory() as temporary:
                        root = Path(temporary)
                        for directory in ("scripts", ".github/scripts", "bin"):
                            (root / directory).mkdir(parents=True)
                        for path, name in (("bin/python3", "owned"), (".github/scripts/select-local-simulator.sh", "local"),
                                           ("scripts/xcodebuild.sh", "hosted")):
                            stub = root / path
                            output = 'printf "SIM_UDID=owned-device\\n" >> "$GITHUB_ENV"' if name == "owned" else f'printf "{name}-device\\n"'
                            stub.write_text(f'#!/bin/bash\nprintf "{name}:%s\\n" "$*" >> "$CALLS"\n'
                                            f'[ "$STUB_EXIT" = 0 ] || exit "$STUB_EXIT"\n{output}\n')
                            stub.chmod(0o755)
                        environment = root / "environment"
                        environment.touch()
                        env = {"PATH": str(root / "bin") + os.pathsep + os.environ["PATH"], "SIMULATOR_FAMILY": family,
                               "GITHUB_ENV": str(environment), "CALLS": str(root / "calls"), "STUB_EXIT": str(exit_code)}
                        result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c",
                                                 command.replace("${{ runner.environment }}", runner)],
                                                cwd=root, env=env, text=True, capture_output=True)
                        calls = (root / "calls").read_text().splitlines()
                        action = "prepare" if family == "ipad" else "prepare-ci"
                        self.assertEqual(calls, [f"owned:scripts/ci_simulator.py {action}"])
                        self.assertEqual(result.returncode, exit_code, result.stderr)
                        self.assertEqual(environment.read_text(), "" if exit_code else "SIM_UDID=owned-device\n")


if __name__ == "__main__":
    unittest.main()
