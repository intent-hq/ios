#!/usr/bin/env python3
"""Credential lifecycle for the workflow's select / prepare / apply steps.

Only reviewed automation from the default-branch workflow revision is executed.
The full-history checkout is source DATA for release_notes.Git, never built.
No repository publication. Preview never uploads artifacts or changes Apple.
"""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

import release_notes
import testflight_notes


def stopped(signum, _frame):
    raise SystemExit(128 + signum)


def main():
    signal.signal(signal.SIGTERM, stopped)
    signal.signal(signal.SIGINT, stopped)
    outcome = {"result": "error", "action": "Workflow setup failed; check credential configuration without printing secret values."}
    status = 1
    try:
        phase, mode = os.environ.get("PROMOTION_PHASE"), os.environ.get("PROMOTION_MODE")
        if phase not in ("select", "prepare", "apply") or mode not in ("preview", "apply") or (
            mode == "apply" and os.environ.get("TESTFLIGHT_INTERNAL_BETA_PROMOTION_ENABLED") != "true"
        ) or (phase == "apply" and (mode != "apply" or not os.environ.get("CHECKPOINT_ID", "").isdigit())):
            raise ValueError
        root = Path(os.environ["RUNNER_TEMP"]) / "testflight"
        root.mkdir(exist_ok=True)
        intent, journal = root / "intent.json", root / "journal.json"
        args = [sys.executable, "scripts/promote_testflight.py", "--repo", "."]
        if phase == "select":
            args += ["--select-only"]
        elif phase == "prepare":
            args += ["--dry-run", "--handoff", str(intent)]
        else:
            frozen = testflight_notes.load(intent, ".")
            if frozen["notes_status"] != "planned" or frozen["assignment_status"] != "not_attempted":
                raise ValueError
            args += ["--apply", "--plan", str(intent), "--handoff", str(journal)]
        key = os.environ.pop("ASC_PRIVATE_KEY", "")
        if not all((key, os.environ.get("ASC_KEY_ID"), os.environ.get("ASC_ISSUER_ID"))):
            raise ValueError
        with tempfile.TemporaryDirectory(prefix="testflight-key-", dir=os.environ["RUNNER_TEMP"]) as directory:
            with tempfile.NamedTemporaryFile(mode="w", dir=directory, suffix=".p8", delete=False) as private_key:
                private_key.write(key)
                key_path = private_key.name
            del key
            child_env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
            child_env["ASC_PRIVATE_KEY_PATH"] = key_path
            completed = subprocess.run(args, env=child_env, capture_output=True, text=True, timeout=120, check=False)
            outcome = json.loads(completed.stdout)
            if not isinstance(outcome, dict) or not {"result", "action"} <= outcome.keys():
                raise ValueError
            status = completed.returncode
        if phase == "select":
            # Identifiers only: no raw API documents or credential material.
            selected = {"result": outcome["result"]}
            if outcome["result"] == "selected":
                selected["build_id"] = release_notes.identifier(outcome["build_id"])
            (root / "selection.json").write_text(json.dumps(selected))
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            if phase == "select" and outcome["result"] == "selected":
                output.write("build_id=" + release_notes.identifier(outcome["build_id"]) + "\n")
            if phase == "prepare" and outcome["result"] == "would_assign":
                frozen = testflight_notes.load(intent, ".")
                selection = release_notes.load_json(root / "selection.json")
                if frozen["payload"]["candidate"]["build_id"] != selection.get("build_id"):
                    raise ValueError
                output.write("fresh_plan=true\n")
    except subprocess.TimeoutExpired:
        status = 1
        outcome = {"result": "error", "action": "Promotion timed out; metadata or assignment may be uncertain. Recover the original intent and run a read-only preview before retrying."}
    except Exception:
        status = 1
        outcome = {"result": "error", "action": "Workflow setup or script output failed. Check credentials and recover the original handoff for a read-only preview; no unsafe details were logged."}
    print(json.dumps(outcome, sort_keys=True, ensure_ascii=True))
    # Escape markup rather than let commit subjects break a Markdown code fence.
    import html
    with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as summary:
        summary.write("\n## TestFlight internal Beta result\n\n<pre>" + html.escape(json.dumps(outcome, indent=2, ensure_ascii=True)) + "</pre>\n\n")
        summary.write("A successful job is not proof of tester availability. Verify Internal Testing > Beta, compliance, What to Test, and tester access. Confirm Beta automatic distribution is off before activation.\n")
    if outcome["result"] in ("blocked", "assigned_pending_testing", "assigned_but_blocked", "recovery_required"):
        print("::warning::Internal testing needs attention; see the action in the job summary.")
    return status


if __name__ == "__main__":
    sys.exit(main())