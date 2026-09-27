"""Execute YAML-selected entry points, env projection and permission-scoped gh.

The small expression interpreter rejects unknown syntax; it does not copy gates.
Hosted runner authorization remains an explicitly unverified prerequisite.
"""

from contextlib import redirect_stdout, redirect_stderr
import io
import json
import os
from pathlib import Path
import re
import shlex
import signal
import stat
import subprocess
import unittest
from unittest.mock import patch

import test_release_delivery as delivery
import test_testflight_workflow as workflow_fixture

ROOT = delivery.ROOT
PUBLIC = workflow_fixture.workflow(ROOT / ".github/workflows/release-notes.yml")
PUBLISH = workflow_fixture.workflow(ROOT / ".github/workflows/release-notes-publish.yml")
BETA = workflow_fixture.CONFIG


def expression(value, context):
    if not isinstance(value, str): return value
    value = value.removeprefix("${{").removesuffix("}}").strip()
    def get(name):
        current = context
        for field in name.split("."):
            current = current.get(field, "") if isinstance(current, dict) else ""
        return current
    tokens = re.findall(r"'(?:[^']|'')*'|[A-Za-z_][\w.-]*|\d+|==|!=|&&|\|\||[(),]", value)
    compact = re.sub(r"\s+", "", value)
    if re.sub(r"\s+", "", "".join(tokens)) != compact: raise AssertionError("Unsupported expression syntax")
    parts = []
    for token in tokens:
        if token.startswith("'") or token.isdigit() or token in ("==", "!=", "(", ")", ","):
            parts.append(token)
        elif token in ("&&", "||"): parts.append("and" if token == "&&" else "or")
        elif token in ("format", "always"): parts.append(token)
        else: parts.append("get(" + repr(token) + ")")
    return eval(" ".join(parts), {"__builtins__": {}, "get": get, "format": lambda s, *a: s.format(*a), "always": lambda: True})


def project(values, context):
    return {k: str(expression(v, context)) if isinstance(v, str) and v.startswith("${{") else str(v)
            for k, v in values.items()}


class DeliveryWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.owner = delivery.DeliveryTests()
        self.owner.setUp()
        self.addCleanup(self.owner.doCleanups)
        self.addCleanup(lambda: self.assertEqual(self.owner.github.errors, []))
        self.root = self.owner.owner.root
        self.output = self.root / "output"
        self.context = {"github": {"repository": "intent-hq/ios", "ref": "refs/heads/main", "run_attempt": 1,
                                   "run_id": "42", "event": {"repository": {"default_branch": "main"}}},
                        "inputs": {"candidate": "200", "mode": "preview", "recovery_channel": "app-store"},
                        "vars": {}, "secrets": {"ASC_KEY_ID": "fixture-id", "ASC_ISSUER_ID": "fixture-issuer",
                                                 "ASC_PRIVATE_KEY": "synthetic-private-material"},
                        "runner": {"temp": str(self.root)}, "steps": {}, "needs": {}}
        self.env = {k: v for k, v in self.owner.env.items() if k.startswith("GITHUB_") or k in ("PATH", "RUNNER_TEMP")}
        self.env.update(GITHUB_RUN_ID="42", GITHUB_EVENT_NAME="workflow_dispatch",
                        GITHUB_OUTPUT=str(self.output), GITHUB_STEP_SUMMARY=str(self.root / "summary"))
        self.calls, self.errors = [], []
        self.failure = False
        self.addCleanup(lambda: self.assertEqual(self.errors, []))

    def subprocess(self, args, **kwargs):
        if args[0] in ("git", "gh"): return self.owner.github(args, **kwargs)
        try:
            self.assertEqual(args[1:4], ["scripts/app_store_notes.py", "--candidate", "200"])
            env = kwargs["env"]
            self.assertNotIn("GH_TOKEN", env)
            self.assertNotIn("GITHUB_TOKEN", env)
            self.assertNotIn("ASC_PRIVATE_KEY", env)
            key = Path(env["ASC_PRIVATE_KEY_PATH"])
            self.assertEqual(stat.S_IMODE(key.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(key.parent.stat().st_mode), 0o700)
            self.assertEqual(key.read_text(), self.context["secrets"]["ASC_PRIVATE_KEY"])
            self.calls.append(args)
            if self.failure: raise subprocess.TimeoutExpired(args, kwargs["timeout"])
            target = Path(args[args.index("--output") + 1])
            target.write_text(json.dumps({"schema_version": 1, "payload": self.owner.payload}))
            return subprocess.CompletedProcess(args, 0, json.dumps(self.owner.payload).encode(), b"")
        except AssertionError as error:
            self.errors.append(str(error))
            raise

    def run_step(self, job, step):
        if not expression(step.get("if", "always()"), self.context): return None
        permissions = job.get("permissions", PUBLIC["permissions"])
        self.context["github"]["token"] = "fixture-write" if permissions.get("contents") == "write" else "fixture-read"
        env = dict(self.env, **project(job.get("env", {}), self.context))
        env.update(project(step.get("env", {}), self.context))
        env["GITHUB_REF"] = self.context["github"]["ref"]
        env["GITHUB_RUN_ATTEMPT"] = str(self.context["github"]["run_attempt"])
        if "run" not in step: return step.get("uses")
        command = shlex.split(step["run"])
        self.assertEqual(command[0], "python3")
        handlers = {s: signal.getsignal(s) for s in (signal.SIGINT, signal.SIGTERM)}
        previous = os.getcwd()
        try:
            os.chdir(self.owner.owner.repo)
            with patch.dict(os.environ, env, clear=True), patch.object(subprocess, "run", side_effect=self.subprocess), \
                    redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                try:
                    exec(compile((ROOT / command[1]).read_text(), command[1], "exec"), {"__name__": "__main__"})
                except SystemExit as outcome:
                    result = outcome.code
        finally:
            os.chdir(previous)
            for s, handler in handlers.items(): signal.signal(s, handler)
        if "id" in step and self.output.exists():
            outputs = dict(line.split("=", 1) for line in self.output.read_text().splitlines())
            self.context["steps"][step["id"]] = {"outputs": outputs}
        return result

    def test_public_workflow_default_and_exact_publish_gate_run_before_credentials(self):
        job = PUBLIC["jobs"]["generate"]
        checkout, gate, generate, checkpoint = job["steps"]
        self.assertEqual(job["permissions"], {"contents": "read"})
        self.assertFalse(checkout["with"]["persist-credentials"])
        self.assertEqual(PUBLIC["on"]["workflow_dispatch"]["inputs"]["mode"]["default"], "preview")
        for enabled in ("", "false", "TRUE", "1", "true "):
            self.context["inputs"]["mode"] = "publish"
            self.context["vars"]["RELEASE_NOTES_PUBLICATION_ENABLED"] = enabled
            self.assertEqual(self.run_step(job, gate), 1)
            self.assertFalse(self.calls)
        self.context["inputs"]["mode"] = "preview"
        self.assertEqual(self.run_step(job, gate), 0)
        self.assertEqual(self.run_step(job, generate), 0)
        self.assertIsNone(self.run_step(job, checkpoint))
        self.assertEqual(len(self.calls), 1)
        self.assertFalse(list(self.root.glob("public-notes-key-*")))
        self.assertNotIn(self.context["secrets"]["ASC_PRIVATE_KEY"], (self.root / "summary").read_text())

    def test_recovery_and_rerun_never_invoke_apple_and_reconcile_original_read_only(self):
        job = PUBLIC["jobs"]["generate"]
        _, gate, generate, checkpoint = job["steps"]
        for channel in ("app-store", "beta"):
            self.context["inputs"].update(recovery_run="42", recovery_channel=channel)
            self.assertEqual(self.run_step(job, gate), 0)
            self.assertIsNone(self.run_step(job, generate))
            self.assertIsNone(self.run_step(job, checkpoint))
            original = self.owner.payload_for(channel)
            self.owner.github.freeze(original, channel)
            self.context["inputs"].update(mode="preview", source_run="42", channel=channel)
            preview = PUBLISH["jobs"]["preview"]
            self.assertTrue(expression(preview["if"], self.context))
            self.assertEqual(self.run_step(preview, preview["steps"][1]), 0)
        self.context["github"]["run_attempt"] = 2
        self.context["inputs"].update(mode="publish", recovery_run="")
        self.assertEqual(self.run_step(job, gate), 0)
        self.assertEqual(self.context["steps"]["gate"]["outputs"]["mode"], "preview")
        self.assertIsNone(self.run_step(job, generate))
        self.assertFalse(self.calls)
        self.assertFalse(self.owner.github.writes)

    def test_new_publish_executes_permission_scoped_github_without_apple_secrets(self):
        self.context["inputs"].update(mode="publish", source_run="42", channel="app-store")
        self.context["vars"]["RELEASE_NOTES_PUBLICATION_ENABLED"] = "true"
        generate = PUBLIC["jobs"]["generate"]
        self.assertEqual(self.run_step(generate, generate["steps"][1]), 0)
        self.assertEqual(self.run_step(generate, generate["steps"][2]), 0)
        self.assertEqual(self.run_step(generate, generate["steps"][3]), "actions/upload-artifact@v7")
        self.context["steps"]["checkpoint"] = {"outputs": {"artifact-id": "8"}}
        self.context["needs"] = {"generate": {"outputs": {k: expression(v, self.context) for k, v in generate["outputs"].items()}}}
        # GitHub serializes boolean job outputs as strings.
        self.context["needs"]["generate"]["outputs"]["delivery"] = str(self.context["needs"]["generate"]["outputs"]["delivery"]).lower()
        self.assertTrue(expression(PUBLIC["jobs"]["deliver"]["if"], self.context))
        self.assertEqual(PUBLISH["permissions"], {})
        job = PUBLISH["jobs"]["publish"]
        self.assertEqual(job["permissions"], {"contents": "write", "pull-requests": "write", "actions": "read"})
        self.assertTrue(expression(job["if"], self.context))
        self.assertEqual(self.run_step(job, job["steps"][1]), 0)
        self.assertEqual(len(self.owner.github.writes), 3)
        self.assertFalse(list(self.root.glob("public-notes-key-*")))

    def test_shared_workflow_gates_beta_default_and_no_credential_inheritance(self):
        beta = BETA["jobs"]["deliver"]
        public = PUBLIC["jobs"]["deliver"]
        self.assertEqual(beta["uses"], public["uses"])
        self.assertEqual(PUBLISH["concurrency"], {"group": "release-notes-changelog", "cancel-in-progress": False})
        self.assertNotIn("secrets", beta)
        self.assertNotIn("secrets", public)
        self.context["needs"] = {"promote": {"outputs": {"mode": "apply"}}}
        for mode, enabled, attempt, ref in (("", "true", 1, "main"), ("publish", "", 1, "main"),
                                           ("publish", "TRUE", 1, "main"), ("publish", "true", 2, "main"),
                                           ("publish", "true", 1, "feature")):
            self.context["inputs"]["publish_mode"] = mode
            self.context["vars"]["RELEASE_NOTES_PUBLICATION_ENABLED"] = enabled
            self.context["github"].update(run_attempt=attempt, ref="refs/heads/" + ref)
            self.assertFalse(expression(beta["if"], self.context))
        self.context["github"].update(run_attempt=1, ref="refs/heads/main")
        self.assertTrue(expression(beta["if"], self.context))
        self.assertFalse(self.owner.github.writes)

    def test_generation_timeout_cleans_key_and_preserves_failure(self):
        job = PUBLIC["jobs"]["generate"]
        self.assertEqual(self.run_step(job, job["steps"][1]), 0)
        self.failure = True
        self.assertEqual(self.run_step(job, job["steps"][2]), 1)
        self.assertFalse(list(self.root.glob("public-notes-key-*")))
        self.assertFalse((self.root / "app-store-notes/intent.json").exists())


if __name__ == "__main__":
    unittest.main()