#!/usr/bin/env python3
"""Exercise runner-pool selection without GitHub access or credentials."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zlib


SELECTOR = Path(__file__).resolve().parents[1] / ".github/scripts/select-macos-runner.sh"
REQUIRED = ["self-hosted", "macOS", "ARM64", "intent-ios"]
HOSTED = '"macos-26-xlarge"'


def routing_id(name):
    return zlib.crc32(name.encode())


def routed_pool(name, pool="intent-ios"):
    return json.dumps(["self-hosted", "macOS", "ARM64", pool, f"intent-ios-runner-{routing_id(name)}"],
                      separators=(",", ":"))


def runner(name, status="online", labels=None, busy=False, routing=True):
    registered = list(REQUIRED if labels is None else labels)
    if routing:
        registered.append(f"intent-ios-runner-{routing_id(name)}")
    return {
        "id": routing_id(name),
        "name": name,
        "status": status,
        "busy": busy,
        "labels": [{"name": label} for label in registered],
    }


class RunnerSelectionTests(unittest.TestCase):
    def test_no_depot_runner_labels(self):
        # Depot was retired; hosted fallbacks are GitHub-hosted labels.
        import re
        root = SELECTOR.parents[2]
        paths = [*(root / ".github").rglob("*.yml"), *(root / ".github").rglob("*.yaml"), *(root / ".github").rglob("*.sh")]
        self.assertIn(SELECTOR, paths)
        for path in paths:
            self.assertEqual(re.findall(r"depot-(?:ubuntu|windows|macos)[\w.-]*", path.read_text()), [], str(path))

    def select(self, runners, token="fixture", curl_status=0, raw=None, pool_label="intent-ios", reservations=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / "response.json"
            fixture.write_text(json.dumps({"runners": runners}) if raw is None else raw)
            stub = root / "curl"
            stub.write_text(
                '#!/bin/bash\nset -eu\n'
                'touch "$TEST_CALLED"\n'
                'if [ "$TEST_CURL_STATUS" != 0 ]; then exit "$TEST_CURL_STATUS"; fi\n'
                'while [ "$1" != -o ]; do shift; done\n'
                'cp "$TEST_RESPONSE" "$2"\n'
            )
            stub.chmod(0o755)
            allocation = root / "reserved.json"
            if reservations is not None:
                allocation.write_text(json.dumps(reservations))
            env = os.environ.copy()
            env.update(
                PATH=f"{root}:{env['PATH']}",
                RUNNER_STATUS_TOKEN=token,
                RUNNER_POOL_LABEL=pool_label,
                RUNNER_RESERVATIONS_FILE=str(allocation) if reservations is not None else "",
                GITHUB_REPOSITORY="intent-hq/ios",
                GITHUB_OUTPUT=str(root / "output"),
                TEST_RESPONSE=str(fixture),
                TEST_CALLED=str(root / "called"),
                TEST_CURL_STATUS=str(curl_status),
            )
            subprocess.run(["bash", str(SELECTOR)], env=env, check=True, capture_output=True)
            if reservations is not None:
                reservations[:] = json.loads(allocation.read_text())
            return (root / "output").read_text().strip(), (root / "called").exists()

    def test_either_machine_can_select_pool(self):
        for name in ["Sams-MacBook-Pro-2-intent-ios", "Sams-MacBook-Pro-intent-ios"]:
            with self.subTest(name=name):
                output, _ = self.select([runner(name)])
                self.assertEqual(output, f"runs-on={routed_pool(name)}")

    def test_original_offline_second_online(self):
        output, _ = self.select([
            runner("Sams-MacBook-Pro-2-intent-ios", "offline"),
            runner("Sams-MacBook-Pro-intent-ios"),
        ])
        self.assertEqual(output, f"runs-on={routed_pool('Sams-MacBook-Pro-intent-ios')}")

    def test_busy_runners_use_hosted(self):
        for runners in ([runner("busy", busy=True), runner("offline", "offline")],
                        [runner("busy-1", busy=True), runner("busy-2", busy=True)]):
            with self.subTest(runners=runners):
                output, _ = self.select(runners)
                self.assertEqual(output, f"runs-on={HOSTED}")

    def test_idle_runner_is_preferred_when_another_is_busy(self):
        output, _ = self.select([runner("busy", busy=True), runner("idle")])
        self.assertEqual(output, f"runs-on={routed_pool('idle')}")

    def test_missing_any_required_label_uses_hosted(self):
        for label in REQUIRED:
            with self.subTest(label=label):
                output, _ = self.select([runner("wrong-pool", labels=[x for x in REQUIRED if x != label])])
                self.assertEqual(output, f"runs-on={HOSTED}")

    def test_each_idle_runner_is_allocated_only_once(self):
        reservations = []
        runners = [runner("first"), runner("second")]
        for expected in (routed_pool("first"), routed_pool("second"), HOSTED):
            output, _ = self.select(runners, reservations=reservations)
            self.assertEqual(output, f"runs-on={expected}")
        self.assertEqual(reservations, ["first", "second"])

    def test_build_reservation_is_shared_with_simulator_pool(self):
        reservations = []
        runners = [runner("shared", labels=REQUIRED + ["intent-ios-build"])]
        output, _ = self.select(runners, pool_label="intent-ios-build", reservations=reservations)
        self.assertEqual(output, f"runs-on={routed_pool('shared', 'intent-ios-build')}")
        output, _ = self.select(runners, reservations=reservations)
        self.assertEqual(output, f"runs-on={HOSTED}")
        self.assertEqual(reservations, ["shared"])

    def test_builds_and_ui_jobs_overflow_after_four_idle_services(self):
        reservations = []
        runners = [runner("phone-1"), runner("build", labels=REQUIRED[:-1] + ["intent-ios-build"]),
                   runner("phone-2"), runner("shared", labels=REQUIRED + ["intent-ios-build"])]
        for pool, expected in (("intent-ios", routed_pool("phone-1")),
                               ("intent-ios-build", routed_pool("build", "intent-ios-build")),
                               ("intent-ios", routed_pool("phone-2")),
                               ("intent-ios", routed_pool("shared")), ("intent-ios", HOSTED)):
            output, _ = self.select(runners, pool_label=pool, reservations=reservations)
            self.assertEqual(output, f"runs-on={expected}")
        self.assertEqual(len(set(reservations)), 4)

    def test_build_pool_is_preferred_over_simulator_pool(self):
        labels = ["self-hosted", "macOS", "ARM64", "intent-ios-build"]
        output, _ = self.select([runner("simulator"), runner("build", labels=labels)],
                                pool_label="intent-ios-build")
        self.assertEqual(output, f"runs-on={routed_pool('build', 'intent-ios-build')}")

    def test_build_pool_falls_back_to_simulator_pool(self):
        labels = ["self-hosted", "macOS", "ARM64", "intent-ios-build"]
        output, _ = self.select([runner("simulator"), runner("build", "offline", labels)],
                                pool_label="intent-ios-build")
        self.assertEqual(output, f"runs-on={routed_pool('simulator')}")

    def test_busy_build_pool_falls_back_to_idle_simulator_pool(self):
        labels = ["self-hosted", "macOS", "ARM64", "intent-ios-build"]
        output, _ = self.select([runner("simulator"), runner("build", labels=labels, busy=True)],
                                pool_label="intent-ios-build")
        self.assertEqual(output, f"runs-on={routed_pool('simulator')}")

    def test_busy_build_and_simulator_pools_use_hosted(self):
        labels = ["self-hosted", "macOS", "ARM64", "intent-ios-build"]
        output, _ = self.select([runner("simulator", busy=True), runner("build", labels=labels, busy=True)],
                                pool_label="intent-ios-build")
        self.assertEqual(output, f"runs-on={HOSTED}")

    def test_idle_build_pool_is_preferred_when_simulator_pool_is_busy(self):
        labels = ["self-hosted", "macOS", "ARM64", "intent-ios-build"]
        output, _ = self.select([runner("simulator", busy=True), runner("build", labels=labels)],
                                pool_label="intent-ios-build")
        self.assertEqual(output, f"runs-on={routed_pool('build', 'intent-ios-build')}")

    def test_missing_unique_routing_label_uses_hosted(self):
        output, _ = self.select([runner("unlabelled", routing=False)])
        self.assertEqual(output, f"runs-on={HOSTED}")

    def test_routing_label_duplicated_on_another_service_is_rejected(self):
        duplicate = runner("other", "offline", labels=REQUIRED + [f"intent-ios-runner-{routing_id('idle')}"])
        output, _ = self.select([runner("idle"), duplicate])
        self.assertEqual(output, f"runs-on={HOSTED}")

    def test_reservations_route_to_exact_services_in_overlapping_pools(self):
        reservations = []
        runners = [runner("build", labels=REQUIRED[:-1] + ["intent-ios-build"]),
                   runner("shared", labels=REQUIRED + ["intent-ios-build"])]
        selections = []
        for pool in ("intent-ios-build", "intent-ios"):
            output, _ = self.select(runners, pool_label=pool, reservations=reservations)
            required = json.loads(output.removeprefix("runs-on="))
            matches = [item["name"] for item in runners if set(required) <= {label["name"] for label in item["labels"]}]
            self.assertEqual(len(matches), 1)
            selections.extend(matches)
        self.assertEqual(selections, ["build", "shared"])
        self.assertEqual(selections, reservations)

    def test_simulator_jobs_do_not_select_build_only_runner(self):
        labels = ["self-hosted", "macOS", "ARM64", "intent-ios-build"]
        output, _ = self.select([runner("build", labels=labels)])
        self.assertEqual(output, f"runs-on={HOSTED}")

    def test_build_pool_without_any_online_mac_uses_hosted(self):
        output, _ = self.select([], pool_label="intent-ios-build")
        self.assertEqual(output, f"runs-on={HOSTED}")

    def test_no_online_runners_uses_hosted(self):
        for runners in [[], [runner("offline", "offline")]]:
            with self.subTest(runners=runners):
                output, _ = self.select(runners)
                self.assertEqual(output, f"runs-on={HOSTED}")

    def test_no_token_skips_api_and_uses_hosted(self):
        output, called = self.select([runner("online")], token="")
        self.assertEqual(output, f"runs-on={HOSTED}")
        self.assertFalse(called)

    def test_api_error_uses_hosted(self):
        output, _ = self.select([], curl_status=22)
        self.assertEqual(output, f"runs-on={HOSTED}")

    def test_malformed_response_uses_hosted(self):
        output, _ = self.select([], raw="not-json")
        self.assertEqual(output, f"runs-on={HOSTED}")


if __name__ == "__main__":
    unittest.main()
