#!/usr/bin/env python3
"""Exercise runner-pool selection without GitHub access or credentials."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SELECTOR = Path(__file__).resolve().parents[1] / ".github/scripts/select-macos-runner.sh"
REQUIRED = ["self-hosted", "macOS", "ARM64", "intent-ios"]
HOSTED = '"macos-15-xlarge"'
POOL = '["self-hosted","macOS","ARM64","intent-ios"]'


def runner(name, status="online", labels=None, busy=False):
    return {
        "name": name,
        "status": status,
        "busy": busy,
        "labels": [{"name": label} for label in (REQUIRED if labels is None else labels)],
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

    def select(self, runners, token="fixture", curl_status=0, raw=None, pool_label="intent-ios"):
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
            env = os.environ.copy()
            env.update(
                PATH=f"{root}:{env['PATH']}",
                RUNNER_STATUS_TOKEN=token,
                RUNNER_POOL_LABEL=pool_label,
                GITHUB_REPOSITORY="intent-hq/ios",
                GITHUB_OUTPUT=str(root / "output"),
                TEST_RESPONSE=str(fixture),
                TEST_CALLED=str(root / "called"),
                TEST_CURL_STATUS=str(curl_status),
            )
            subprocess.run(["bash", str(SELECTOR)], env=env, check=True, capture_output=True)
            return (root / "output").read_text().strip(), (root / "called").exists()

    def test_either_machine_can_select_pool(self):
        for name in ["Sams-MacBook-Pro-2-intent-ios", "Sams-MacBook-Pro-intent-ios"]:
            with self.subTest(name=name):
                output, _ = self.select([runner(name)])
                self.assertEqual(output, f"runs-on={POOL}")

    def test_original_offline_second_online(self):
        output, _ = self.select([
            runner("Sams-MacBook-Pro-2-intent-ios", "offline"),
            runner("Sams-MacBook-Pro-intent-ios"),
        ])
        self.assertEqual(output, f"runs-on={POOL}")

    def test_busy_runner_remains_eligible_for_queued_jobs(self):
        output, _ = self.select([runner("busy", busy=True), runner("offline", "offline")])
        self.assertEqual(output, f"runs-on={POOL}")

    def test_missing_any_required_label_uses_hosted(self):
        for label in REQUIRED:
            with self.subTest(label=label):
                output, _ = self.select([runner("wrong-pool", labels=[x for x in REQUIRED if x != label])])
                self.assertEqual(output, f"runs-on={HOSTED}")

    def test_build_pool_is_preferred_over_simulator_pool(self):
        labels = ["self-hosted", "macOS", "ARM64", "intent-ios-build"]
        output, _ = self.select([runner("simulator"), runner("build", labels=labels)],
                                pool_label="intent-ios-build")
        self.assertEqual(output, 'runs-on=["self-hosted","macOS","ARM64","intent-ios-build"]')

    def test_build_pool_falls_back_to_simulator_pool(self):
        labels = ["self-hosted", "macOS", "ARM64", "intent-ios-build"]
        output, _ = self.select([runner("simulator"), runner("build", "offline", labels)],
                                pool_label="intent-ios-build")
        self.assertEqual(output, f"runs-on={POOL}")

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
