"""Execute the actual Actions gate and key lifecycle offline, not a mirrored policy.

Ruby/Psych is the standard-library YAML parser on macOS and ubuntu-latest.
The subprocess boundary substitutes only the separately tested promotion CLI;
no test invokes App Store Connect or reads developer credentials.
"""

from contextlib import redirect_stdout
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[2]


def workflow(path):
    parsed = subprocess.run(
        ["ruby", "-rjson", "-ryaml", "-e", "puts JSON.generate(YAML.load_file(ARGV.fetch(0)))", str(path)],
        check=True, capture_output=True, text=True,
    )
    return json.loads(parsed.stdout)


CONFIG = workflow(ROOT / ".github/workflows/testflight-beta.yml")
JOB = CONFIG["jobs"]["promote"]
GATE, CHECKOUT, PROMOTE, RECOVER, PREPARE, CHECKPOINT, APPLY, OUTCOME = JOB["steps"]

# This stub records what the real workflow supplied at the process boundary.
# Synthetic key bytes remain only in memory and the workflow-owned private file.
CLI_FIXTURE = '''
import hashlib, json, os, signal, stat, sys, time
from pathlib import Path
key = Path(os.environ["ASC_PRIVATE_KEY_PATH"])
info = key.lstat()
receipt = {
    "args": sys.argv[1:], "key_path": str(key),
    "regular": stat.S_ISREG(info.st_mode), "owner": info.st_uid == os.getuid(),
    "mode": stat.S_IMODE(info.st_mode), "directory_mode": stat.S_IMODE(key.parent.stat().st_mode),
    "digest": hashlib.sha256(key.read_bytes()).hexdigest(),
    "raw_key_in_env": "ASC_PRIVATE_KEY" in os.environ,
    "pins": [os.environ.get("ASC_SOURCE_GROUP_ID"), os.environ.get("ASC_DESTINATION_GROUP_ID")],
}
Path("receipt.json").write_text(json.dumps(receipt))
behavior = os.environ.get("FIXTURE_BEHAVIOR", "success")
if behavior in ("SIGTERM", "SIGINT"):
    os.kill(os.getppid(), getattr(signal, behavior))
    time.sleep(5)
print(os.environ["FIXTURE_PRIVATE_MARKER"], file=sys.stderr)
if behavior == "malformed":
    print(os.environ["FIXTURE_PRIVATE_MARKER"])
else:
    print(json.dumps({"result": os.environ.get("FIXTURE_RESULT", "would_assign"),
                      "action": "Fixture: inspect the selected build manually.", "build_id": "200"}))
sys.exit(1 if behavior == "failure" else 0)
'''


class WorkflowExecutionTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="testflight-workflow-test-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / "scripts").mkdir()
        (self.root / "scripts/promote_testflight.py").write_text(CLI_FIXTURE)
        for name in ("testflight_workflow.py", "testflight_notes.py", "release_notes.py"):
            (self.root / "scripts" / name).write_text((ROOT / "scripts" / name).read_text())
        (self.root / "runner").mkdir()
        (self.root / "bin").mkdir()
        # Simulate late runner clocks without a test-only production clock flag.
        date = self.root / "bin/date"
        date.write_text("#!/usr/bin/env python3\nimport datetime, os, sys\n"
                        "now = datetime.datetime.fromisoformat(os.environ['FIXTURE_CLOCK'])\n"
                        "fmt = next((arg[1:] for arg in sys.argv[1:] if arg.startswith('+')), '%c')\n"
                        "print(now.strftime(fmt))\n")
        date.chmod(0o755)
        self.env = {
            "PATH": str(self.root / "bin") + os.pathsep + os.environ["PATH"],
            "RUNNER_TEMP": str(self.root / "runner"),
            "GITHUB_OUTPUT": str(self.root / "output"),
            "GITHUB_STEP_SUMMARY": str(self.root / "summary"),
            "GITHUB_REF": "refs/heads/main", "DEFAULT_BRANCH": "main",
            "GITHUB_EVENT_NAME": "workflow_dispatch", "PROMOTION_MODE": "preview",
            "PROMOTION_PHASE": "select",
            "TESTFLIGHT_INTERNAL_BETA_PROMOTION_ENABLED": "", "PYTHONDONTWRITEBYTECODE": "1",
        }

    def run_step(self, step, **env):
        return subprocess.run(["bash", "-e", "-o", "pipefail", "-c", step["run"]],
                              cwd=self.root, env=dict(self.env, **env), capture_output=True,
                              text=True, timeout=15)

    def gate(self, **env):
        result = self.run_step(GATE, **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return (self.root / "output").read_text().splitlines()[-1]

    def credentials(self):
        key = secrets.token_urlsafe(32) + "\n" + secrets.token_urlsafe(32) + "\n"
        return {"ASC_KEY_ID": "fixture-key-id", "ASC_ISSUER_ID": "fixture-issuer",
                "ASC_PRIVATE_KEY": key, "ASC_SOURCE_GROUP_ID": "101", "ASC_DESTINATION_GROUP_ID": "102",
                "FIXTURE_PRIVATE_MARKER": secrets.token_urlsafe(32)}

    def assert_clean(self):
        self.assertFalse(list((self.root / "runner").rglob("*.p8")))
        self.assertFalse(list((self.root / "runner").glob("testflight-key-*")))

    def test_schedule_and_manual_apply_fail_closed_without_exact_opt_in(self):
        for event in ("schedule", "workflow_dispatch"):
            for enabled in ("", "false", "TRUE", "1", "yes", "true "):
                with self.subTest(event=event, enabled=enabled):
                    self.assertEqual(self.gate(GITHUB_EVENT_NAME=event, PROMOTION_MODE="apply",
                                              TESTFLIGHT_INTERNAL_BETA_PROMOTION_ENABLED=enabled,
                                              TESTFLIGHT_ALPHA_PROMOTION_ENABLED="true"), "mode=skip")
        self.assertIn("explicit approval", (self.root / "summary").read_text())
        self.assertFalse((self.root / "receipt.json").exists())

    def test_manual_preview_does_not_require_activation_and_default_is_read_only(self):
        for mode in ("", "preview"):
            for enabled in ("", "false", "true"):
                with self.subTest(mode=mode, enabled=enabled):
                    self.assertEqual(self.gate(PROMOTION_MODE=mode,
                                              TESTFLIGHT_INTERNAL_BETA_PROMOTION_ENABLED=enabled), "mode=preview")
        self.assertEqual(CONFIG["on"]["workflow_dispatch"]["inputs"]["mode"]["default"], "preview")

    def test_activation_allows_schedule_and_explicit_manual_apply_only(self):
        for event in ("schedule", "workflow_dispatch"):
            with self.subTest(event=event):
                self.assertEqual(self.gate(GITHUB_EVENT_NAME=event, PROMOTION_MODE="apply",
                                          TESTFLIGHT_INTERNAL_BETA_PROMOTION_ENABLED="true"), "mode=apply")

    def test_nondefault_refs_and_missing_default_branch_never_access_asc(self):
        for event in ("schedule", "workflow_dispatch"):
            for ref, branch in (("refs/heads/feature", "main"), ("refs/tags/main", "main"),
                                ("refs/heads/", "")):
                with self.subTest(event=event, ref=ref):
                    self.assertEqual(self.gate(GITHUB_EVENT_NAME=event, GITHUB_REF=ref, DEFAULT_BRANCH=branch,
                                              TESTFLIGHT_INTERNAL_BETA_PROMOTION_ENABLED="true"), "mode=skip")

    def test_unknown_events_and_modes_are_rejected_without_echoing_inputs(self):
        for env in ({"GITHUB_EVENT_NAME": "pull_request"}, {"PROMOTION_MODE": "invalid-$(exit 0)"}):
            with self.subTest(env=env):
                result = self.run_step(GATE, **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "output").exists())
                self.assertNotIn(next(iter(env.values())), result.stdout + result.stderr)

    def test_delayed_native_schedule_is_not_filtered_by_current_hour_or_minute(self):
        # GitHub owns timezone scheduling. These late-start clocks, including
        # the following day and DST changes, must not suppress the event.
        for instant in ("2026-01-15T18:42:00-08:00", "2026-07-15T23:59:00-07:00",
                        "2026-03-08T03:15:00-07:00", "2026-11-01T01:30:00-08:00",
                        "2026-07-16T08:01:00-07:00"):
            with self.subTest(start=instant):
                self.assertEqual(self.gate(GITHUB_EVENT_NAME="schedule", FIXTURE_CLOCK=instant,
                                          TESTFLIGHT_INTERNAL_BETA_PROMOTION_ENABLED="true"), "mode=apply")

    def test_key_is_private_child_arguments_are_safe_and_file_is_cleaned(self):
        for mode in ("preview", "apply"):
            with self.subTest(mode=mode):
                credentials = self.credentials()
                result = self.run_step(PROMOTE, **credentials, PROMOTION_MODE=mode,
                                       TESTFLIGHT_INTERNAL_BETA_PROMOTION_ENABLED="true")
                self.assertEqual(result.returncode, 0, result.stderr)
                receipt = json.loads((self.root / "receipt.json").read_text())
                self.assertEqual(receipt["args"], ["--repo", ".", "--select-only"])
                self.assertTrue(receipt["owner"] and receipt["regular"])
                self.assertEqual((receipt["mode"], receipt["directory_mode"]), (0o600, 0o700))
                self.assertEqual(receipt["digest"], hashlib.sha256(credentials["ASC_PRIVATE_KEY"].encode()).hexdigest())
                self.assertFalse(receipt["raw_key_in_env"])
                self.assertEqual(receipt["pins"], ["101", "102"])
                self.assertFalse(Path(receipt["key_path"]).exists())
                public = result.stdout + result.stderr + (self.root / "summary").read_text()
                for name in ("ASC_PRIVATE_KEY", "FIXTURE_PRIVATE_MARKER"):
                    self.assertNotIn(credentials[name], public)
                self.assertIn("would_assign", public)
                self.assert_clean()

    def test_apply_step_itself_refuses_unapproved_or_invalid_mode(self):
        for mode, enabled in (("apply", ""), ("apply", "false"), ("apply", "TRUE"), ("invalid", "true")):
            with self.subTest(mode=mode, enabled=enabled):
                result = self.run_step(PROMOTE, **self.credentials(), PROMOTION_MODE=mode,
                                       TESTFLIGHT_INTERNAL_BETA_PROMOTION_ENABLED=enabled,
                                       TESTFLIGHT_ALPHA_PROMOTION_ENABLED="true")
                self.assertEqual(result.returncode, 1)
                self.assertFalse((self.root / "receipt.json").exists())
                self.assert_clean()

    def test_missing_credentials_fail_safely_before_invoking_script(self):
        for missing in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY"):
            with self.subTest(missing=missing):
                credentials = self.credentials()
                credentials.pop(missing)
                result = self.run_step(PROMOTE, **credentials)
                self.assertEqual(result.returncode, 1)
                self.assertFalse((self.root / "receipt.json").exists())
                self.assertIn("Check credentials", result.stdout)
                self.assert_clean()

    def test_cli_failure_and_malformed_output_stay_failed_and_clean_without_leaks(self):
        for behavior in ("failure", "malformed"):
            with self.subTest(behavior=behavior):
                credentials = self.credentials()
                result = self.run_step(PROMOTE, **credentials, FIXTURE_BEHAVIOR=behavior, FIXTURE_RESULT="error")
                self.assertEqual(result.returncode, 1)
                public = result.stdout + result.stderr + (self.root / "summary").read_text()
                self.assertIn('"result": "error"', public)
                self.assertNotIn(credentials["FIXTURE_PRIVATE_MARKER"], public)
                self.assert_clean()

    def test_cancellation_unwinds_private_key_directory(self):
        for signum, code in (("SIGTERM", 143), ("SIGINT", 130)):
            with self.subTest(signal=signum):
                result = self.run_step(PROMOTE, **self.credentials(), FIXTURE_BEHAVIOR=signum)
                self.assertEqual(result.returncode, code)
                self.assertFalse(Path(json.loads((self.root / "receipt.json").read_text())["key_path"]).exists())
                self.assert_clean()

    def test_bounded_subprocess_timeout_cleans_key_and_requires_preview_before_retry(self):
        # Run the actual embedded Python, replacing only the process boundary so
        # the timeout path is exercised without an eight-minute sleeping child.
        source = (ROOT / "scripts/testflight_workflow.py").read_text()
        output = io.StringIO()

        def timeout(args, **kwargs):
            self.assertEqual(args[1:], ["scripts/promote_testflight.py", "--repo", ".", "--select-only"])
            self.assertGreater(kwargs["timeout"], 0)
            self.assertLess(kwargs["timeout"], JOB["timeout-minutes"] * 60)
            self.assertTrue(Path(kwargs["env"]["ASC_PRIVATE_KEY_PATH"]).is_file())
            raise subprocess.TimeoutExpired(args, kwargs["timeout"])

        handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
        try:
            with patch.dict(os.environ, dict(self.env, **self.credentials()), clear=True), \
                    patch.object(subprocess, "run", side_effect=timeout), redirect_stdout(output), \
                    self.assertRaises(SystemExit) as stopped:
                sys.path.insert(0, str(ROOT / "scripts"))
                exec(compile(source, "scripts/testflight_workflow.py", "exec"), {"__name__": "__main__"})
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
        self.assertEqual(stopped.exception.code, 1)
        outcome = json.loads(output.getvalue())
        self.assertEqual(outcome["result"], "error")
        self.assertIn("timed out", outcome["action"])
        self.assertIn("read-only preview before retrying", outcome["action"])
        self.assert_clean()

    def test_manual_action_results_are_visible_not_claimed_as_distributed(self):
        for outcome in ("blocked", "assigned_pending_testing", "assigned_but_blocked"):
            with self.subTest(outcome=outcome):
                result = self.run_step(PROMOTE, **self.credentials(), FIXTURE_RESULT=outcome)
                self.assertEqual(result.returncode, 0)
                self.assertIn("::warning::", result.stdout)
                summary = (self.root / "summary").read_text()
                self.assertIn(outcome, summary)
                self.assertIn("inspect the selected build manually", summary)
                self.assertIn("not proof of tester availability", summary)

    def test_live_step_requires_successful_checkpoint_and_exact_activation(self):
        for checkpoint, enabled, mode in (("", "true", "apply"), ("bad", "true", "apply"),
                                          ("123", "false", "apply"), ("123", "true", "preview")):
            with self.subTest(checkpoint=checkpoint, enabled=enabled, mode=mode):
                result = self.run_step(APPLY, **self.credentials(), PROMOTION_PHASE="apply", PROMOTION_MODE=mode,
                                       CHECKPOINT_ID=checkpoint, TESTFLIGHT_INTERNAL_BETA_PROMOTION_ENABLED=enabled)
                self.assertEqual(result.returncode, 1)
                self.assertFalse((self.root / "receipt.json").exists())
                self.assert_clean()


class WorkflowConfigurationTests(unittest.TestCase):
    def test_one_native_pacific_schedule_at_four_pm_including_dst_boundaries(self):
        self.assertEqual(set(CONFIG["on"]), {"schedule", "workflow_dispatch"})
        self.assertEqual(len(CONFIG["on"]["schedule"]), 1)
        schedule = CONFIG["on"]["schedule"][0]
        self.assertEqual(schedule["cron"], "0 16 * * *")
        self.assertEqual(schedule["timezone"], "America/Los_Angeles")
        zone = ZoneInfo(schedule["timezone"])
        for local_day, expected_utc in (
            ("2026-01-15", "2026-01-16T00:00:00+00:00"),
            ("2026-07-15", "2026-07-15T23:00:00+00:00"),
            ("2026-03-07", "2026-03-08T00:00:00+00:00"),
            ("2026-03-08", "2026-03-08T23:00:00+00:00"),
            ("2026-10-31", "2026-10-31T23:00:00+00:00"),
            ("2026-11-01", "2026-11-02T00:00:00+00:00"),
        ):
            with self.subTest(day=local_day):
                minute, hour, *_ = schedule["cron"].split()
                local = datetime.fromisoformat(local_day).replace(hour=int(hour), minute=int(minute), tzinfo=zone)
                self.assertEqual(local.astimezone(timezone.utc).isoformat(), expected_utc)

    def test_credentials_are_gated_env_only_and_runs_are_serialized_with_read_permissions(self):
        self.assertEqual(CONFIG["permissions"], {"contents": "read"})
        self.assertEqual(JOB["permissions"], {"contents": "read", "actions": "read"})
        self.assertEqual(CONFIG["concurrency"]["cancel-in-progress"], False)
        self.assertTrue(CONFIG["concurrency"]["group"])
        self.assertNotIn("${{", CONFIG["concurrency"]["group"])
        self.assertLessEqual(JOB["timeout-minutes"], 10)
        self.assertEqual(JOB["runs-on"], "ubuntu-latest")
        self.assertFalse(CHECKOUT["with"]["persist-credentials"])
        self.assertEqual(CHECKOUT["with"]["fetch-depth"], 0)
        self.assertFalse(CHECKOUT["with"]["submodules"])
        self.assertFalse(CHECKOUT["with"]["lfs"])
        allowed = "steps.gate.outputs.mode == 'preview' || steps.gate.outputs.mode == 'apply'"
        self.assertEqual(CHECKOUT["if"], allowed)
        self.assertEqual(PROMOTE["if"], allowed)
        for step in (GATE, PROMOTE):
            self.assertEqual(step["env"]["TESTFLIGHT_INTERNAL_BETA_PROMOTION_ENABLED"],
                             "${{ vars.TESTFLIGHT_INTERNAL_BETA_PROMOTION_ENABLED }}")
        for name in ("ASC_SOURCE_GROUP_ID", "ASC_DESTINATION_GROUP_ID"):
            self.assertEqual(PROMOTE["env"][name], "${{ vars." + name + " }}")
        self.assertNotIn("secrets.", json.dumps(GATE))
        for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY"):
            self.assertEqual(PROMOTE["env"][name], "${{ secrets." + name + " }}")
        self.assertNotIn("${{", PROMOTE["run"])

    def test_checkpoint_and_recovery_are_separate_from_credentials_and_preview_has_no_uploads(self):
        self.assertEqual(PREPARE["if"], PROMOTE["if"])
        self.assertEqual(RECOVER["if"], PROMOTE["if"])
        self.assertNotIn("ASC_", json.dumps(RECOVER))
        self.assertEqual(RECOVER["env"]["GH_TOKEN"], "${{ github.token }}")
        self.assertNotIn("GH_TOKEN", json.dumps([PROMOTE, PREPARE, APPLY]))
        self.assertEqual(CHECKPOINT["if"], "steps.gate.outputs.mode == 'apply' && steps.prepare.outputs.fresh_plan == 'true'")
        self.assertIn("steps.checkpoint.outputs.artifact-id != ''", APPLY["if"])
        self.assertEqual(OUTCOME["if"], "always() && steps.gate.outputs.mode == 'apply'")
        for step in (CHECKPOINT, OUTCOME):
            self.assertEqual(step["uses"], "actions/upload-artifact@v7")
            self.assertEqual(step["with"]["retention-days"], 90)
            self.assertNotIn("overwrite", step["with"])
            for path in step["with"]["path"].splitlines():
                self.assertIn(path, ("${{ runner.temp }}/testflight/intent.json", "${{ runner.temp }}/testflight/journal.json"))


if __name__ == "__main__":
    unittest.main()