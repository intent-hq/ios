"""Offline process-boundary recovery and workflow tests with real generated plans.

These own cross-run durability/producer trust, not generator rendering. gh and
Apple's transport are synthetic; actual workflow helpers/CLI/Git validation run.
"""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
import zipfile

import test_promote_testflight as fixtures

SCRIPTS = Path(__file__).resolve().parents[1]


class ArtifactRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.owner = fixtures.PromotionTests()
        self.owner.setUp()
        self.addCleanup(self.owner.doCleanups)
        self.root, self.repo = self.owner.root, self.owner.repo
        self.intent = self.root / "original.json"
        status, result = self.owner.run_cli(extra=("--handoff", str(self.intent)))
        self.assertEqual(status, 0, result)
        self.frozen = json.loads(self.intent.read_text())
        (self.repo / "scripts").mkdir()
        for name in ("testflight_artifacts.py", "testflight_workflow.py", "release_notes.py", "testflight_notes.py"):
            (self.repo / "scripts" / name).write_text((SCRIPTS / name).read_text())
        self.runner = self.root / "runner"
        self.runner.mkdir()
        (self.runner / "testflight").mkdir()
        (self.runner / "testflight/selection.json").write_text('{"result":"selected","build_id":"200"}')
        self.bin = self.root / "bin"
        self.bin.mkdir()
        gh = self.bin / "gh"
        gh.write_text(f"#!{sys.executable}\n" + '''import json, os, sys
from pathlib import Path
root = Path(os.environ['FIXTURE_ROOT']) if 'FIXTURE_ROOT' in os.environ else Path.cwd().parent
args = sys.argv[1:]
with (root / 'gh-calls.jsonl').open('a') as out: out.write(json.dumps(args) + '\\n')
assert args[:5] == ['api', '--hostname', 'github.com', '--method', 'GET']
endpoint = args[5]
data = json.loads((root / 'github.json').read_text())
if '/artifacts?' in endpoint: print(json.dumps(data['list']))
elif endpoint.endswith('/runs/77'): print(json.dumps(data['run']))
elif endpoint.endswith('/artifacts/88/zip'): sys.stdout.buffer.write((root / 'artifact.zip').read_bytes())
else: sys.exit(19)
''')
        gh.chmod(0o755)
        self.github = {"list": {"total_count": 1, "artifacts": [
            {"id": 88, "name": "testflight-beta-intent-200", "expired": False, "workflow_run": {"id": 77}}]},
            "run": {"path": ".github/workflows/testflight-beta.yml", "head_branch": "main", "event": "schedule",
                    "head_repository": {"full_name": "intent-hq/ios"}}}
        self.archive()
        self.env = {"PATH": str(self.bin) + os.pathsep + os.defpath, "GITHUB_REPOSITORY": "intent-hq/ios",
                    "GITHUB_REF": "refs/heads/main", "DEFAULT_BRANCH": "main", "GITHUB_RUN_ID": "77",
                    "GITHUB_RUN_ATTEMPT": "1", "RUNNER_TEMP": str(self.runner), "PYTHONDONTWRITEBYTECODE": "1",
                    "GITHUB_STEP_SUMMARY": str(self.root / "summary"), "GITHUB_OUTPUT": str(self.root / "output")}

    def archive(self, name="intent.json", content=None):
        with zipfile.ZipFile(self.root / "artifact.zip", "w") as archive:
            archive.writestr(name, json.dumps(self.frozen) if content is None else content)

    def run_script(self, name, **env):
        (self.root / "github.json").write_text(json.dumps(self.github))
        return subprocess.run([sys.executable, "scripts/" + name], cwd=self.repo,
                              env=dict(self.env, **env), capture_output=True, text=True, timeout=20)

    def test_exact_candidate_artifact_is_validated_and_restored_without_writes(self):
        result = self.run_script("testflight_artifacts.py")
        self.assertEqual(result.returncode, 0, result.stderr)
        restored = json.loads((self.runner / "testflight/intent.json").read_text())
        self.assertEqual(restored, self.frozen)
        calls = [json.loads(line) for line in (self.root / "gh-calls.jsonl").read_text().splitlines()]
        self.assertEqual(len(calls), 3)
        self.assertTrue(all(c[:5] == ["api", "--hostname", "github.com", "--method", "GET"] for c in calls))
        self.assertIn("name=testflight-beta-intent-200", calls[0][-1])

    def test_rerun_restores_original_build_even_after_new_alpha_upload(self):
        (self.runner / "testflight/selection.json").write_text('{"result":"selected","build_id":"201"}')
        result = self.run_script("testflight_artifacts.py", GITHUB_RUN_ATTEMPT="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        restored = json.loads((self.runner / "testflight/intent.json").read_text())
        self.assertEqual(restored["payload"]["candidate"]["build_id"], "200")
        calls = (self.root / "gh-calls.jsonl").read_text()
        self.assertIn("runs/77/artifacts", calls)
        self.assertNotIn("intent-201", calls)

    def test_untrusted_incomplete_expired_or_ambiguous_artifacts_stop_without_a_fresh_plan(self):
        original = copy.deepcopy(self.github)
        for case in ("expired", "fork", "pr", "branch", "workflow", "incomplete", "duplicate", "tampered", "zip-path", "candidate"):
            with self.subTest(case=case):
                self.github = copy.deepcopy(original)
                self.archive()
                if case == "expired":
                    self.github["list"]["artifacts"][0]["expired"] = True
                elif case == "fork":
                    self.github["run"]["head_repository"]["full_name"] = "other/ios"
                elif case in ("pr", "branch", "workflow"):
                    field, value = {"pr": ("event", "pull_request"), "branch": ("head_branch", "feature"),
                                    "workflow": ("path", ".github/workflows/other.yml")}[case]
                    self.github["run"][field] = value
                elif case == "incomplete":
                    self.github["list"]["total_count"] = 101
                elif case == "duplicate":
                    self.github["list"]["artifacts"] *= 2
                    self.github["list"]["total_count"] = 2
                elif case == "tampered":
                    altered = copy.deepcopy(self.frozen)
                    altered["payload"]["plain_text"] = "untrusted text"
                    self.archive(content=json.dumps(altered))
                elif case == "candidate":
                    (self.runner / "testflight/selection.json").write_text('{"result":"selected","build_id":"intent-200"}')
                else:
                    self.archive(name="../../intent.json")
                result = self.run_script("testflight_artifacts.py")
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertFalse((self.runner / "testflight/intent.json").exists())

    def test_no_artifact_allows_only_a_new_run_not_a_blind_rerun(self):
        self.github["list"] = {"total_count": 0, "artifacts": []}
        self.assertEqual(self.run_script("testflight_artifacts.py").returncode, 0)
        self.assertEqual(self.run_script("testflight_artifacts.py", GITHUB_RUN_ATTEMPT="2").returncode, 1)
        self.assertFalse((self.runner / "testflight/intent.json").exists())

    def test_workflow_prepare_apply_and_recovery_execute_real_cli_with_frozen_payload(self):
        # The stub replaces ONLY credential creation and Apple's network transport;
        # the real CLI, generator, on-disk journal and workflow wrapper execute.
        wrapper = f'''import json, sys, unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, {str(SCRIPTS / 'tests')!r})
import test_promote_testflight as f
api = f.FixtureAPI(unittest.TestCase())
api.notes_api.data['runs']['199']['data'][0]['attributes']['sourceCommit']['commitSha'] = {self.owner.base!r}
api.notes_api.data['runs']['200']['data'][0]['attributes']['sourceCommit']['commitSha'] = {self.owner.head!r}
state = Path('api-state.json')
saved = json.loads(state.read_text()) if state.exists() else {{'data': api.data, 'localizations': [], 'writes': []}}
api.data, api.localizations = saved['data'], saved['localizations']
with patch.object(f.promotion, 'Credentials') as creds, patch.object(f.promotion.urllib.request, 'build_opener', return_value=api):
    creds.return_value.token.return_value = 'synthetic'
    status = f.promotion.main(sys.argv[1:])
assert not api.contract_errors and not api.notes_api.errors
state.write_text(json.dumps({{'data':api.data, 'localizations':api.localizations, 'writes':saved['writes'] + api.writes}}))
sys.exit(status)
'''
        (self.repo / "scripts/promote_testflight.py").write_text(wrapper)
        env = {"PROMOTION_MODE": "apply", "TESTFLIGHT_INTERNAL_BETA_PROMOTION_ENABLED": "true",
               "ASC_KEY_ID": "synthetic-key", "ASC_ISSUER_ID": "synthetic-issuer", "ASC_PRIVATE_KEY": "synthetic-private-fixture"}
        self.github["list"] = {"total_count": 0, "artifacts": []}
        result = self.run_script("testflight_workflow.py", **env, PROMOTION_PHASE="select")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.run_script("testflight_artifacts.py").returncode, 0)
        result = self.run_script("testflight_workflow.py", **env, PROMOTION_PHASE="prepare")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("fresh_plan=true", (self.root / "output").read_text())
        state = json.loads((self.repo / "api-state.json").read_text())
        self.assertEqual(state["writes"], [])
        checkpoint = (self.runner / "testflight/intent.json").read_text()
        result = self.run_script("testflight_workflow.py", **env, PROMOTION_PHASE="apply", CHECKPOINT_ID="88")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        outcome = json.loads(result.stdout)
        self.assertEqual((outcome["notes_status"], outcome["assignment_status"]), ("verified", "confirmed"))
        state = json.loads((self.repo / "api-state.json").read_text())
        self.assertEqual(len(state["writes"]), 2)
        frozen = json.loads(checkpoint)
        self.assertEqual(json.loads((self.runner / "testflight/journal.json").read_text())["payload"], frozen["payload"])
        # Simulate a hosted rerun whose final outcome upload was lost. Recover
        # ONLY the pre-write intent, so observations must be read again.
        self.runner = self.root / "retry-runner"
        (self.runner / "testflight").mkdir(parents=True)
        self.env["RUNNER_TEMP"] = str(self.runner)
        self.github["list"] = {"total_count": 1, "artifacts": [{"id": 88, "name": "testflight-beta-intent-200", "expired": False}]}
        self.archive(content=checkpoint)
        self.assertEqual(self.run_script("testflight_workflow.py", **env, PROMOTION_PHASE="select").returncode, 0)
        self.assertEqual(self.run_script("testflight_artifacts.py", GITHUB_RUN_ATTEMPT="2").returncode, 0)
        (self.root / "output").write_text("")
        result = self.run_script("testflight_workflow.py", **env, PROMOTION_PHASE="prepare")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["result"], "already_assigned")
        self.assertNotIn("fresh_plan=true", (self.root / "output").read_text())
        self.assertEqual(len(json.loads((self.repo / "api-state.json").read_text())["writes"]), 2)
        self.assertEqual(json.loads(result.stdout)["payload"], frozen["payload"])
        self.assertFalse(list(self.root.rglob("*.p8")))


if __name__ == "__main__":
    unittest.main()