#!/usr/bin/env python3
"""Public workflow gate and temporary Apple credential lifecycle; no Apple writes."""

import html
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

import release_notes as notes


def gate():
    env = os.environ
    branch = env.get("DEFAULT_BRANCH")
    notes.require(env.get("GITHUB_REPOSITORY") == "intent-hq/ios" and branch
                  and env.get("GITHUB_REF") == "refs/heads/" + branch
                  and env.get("GITHUB_EVENT_NAME") == "workflow_dispatch", "Manual default-branch runs only.")
    mode = env.get("PUBLICATION_MODE") or "preview"
    notes.require(mode in ("preview", "publish"), "Unsupported publication mode.")
    recovery = env.get("RECOVERY_RUN", "")
    rerun = int(env["GITHUB_RUN_ATTEMPT"]) > 1
    if rerun:
        # Reruns never contact Apple or perform new GitHub writes. The original
        # producer is immutable; another dispatch is needed after human review.
        recovery, mode = recovery or env["GITHUB_RUN_ID"], "preview"
    if mode == "publish":
        notes.require(env.get("RELEASE_NOTES_PUBLICATION_ENABLED") == "true", "Repository publication is disabled.")
    if recovery:
        notes.require(recovery.isdigit() and int(recovery) > 0, "Invalid recovery producer run.")
        channel = env.get("RECOVERY_CHANNEL", "app-store")
        notes.require(channel in ("beta", "app-store"), "Unknown recovery channel.")
    else:
        notes.identifier(env.get("CANDIDATE_BUILD"))
        channel = "app-store"
    return {"generate": "false" if recovery else "true", "mode": mode,
            "source_run": recovery or env["GITHUB_RUN_ID"], "channel": channel}


def stopped(signum, _frame):
    raise SystemExit(128 + signum)


def generate():
    decision = gate()
    notes.require(decision["generate"] == "true", "Recovery cannot access Apple; use the publisher only.")
    root = Path(os.environ["RUNNER_TEMP"]) / "app-store-notes"
    root.mkdir(exist_ok=True)
    intent = root / "intent.json"
    notes.require(not intent.exists(), "Retain the original intent; never regenerate on retry.")
    sources = os.environ.get("SOURCE_MAPPINGS") or "{}"
    notes.require(len(sources.encode()) <= 64 * 1024, "Mapping input exceeds the safety bound.")
    mapping = root / "sources.json"
    mapping.write_text(sources)
    notes.load_json(mapping)
    key = os.environ.pop("ASC_PRIVATE_KEY", "")
    notes.require(key and os.environ.get("ASC_KEY_ID") and os.environ.get("ASC_ISSUER_ID"), "Apple credential setup is missing.")
    with tempfile.TemporaryDirectory(prefix="public-notes-key-", dir=os.environ["RUNNER_TEMP"]) as directory:
        with tempfile.NamedTemporaryFile(mode="w", dir=directory, suffix=".p8", delete=False) as handle:
            handle.write(key)
            path = handle.name
        del key
        env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN", "SOURCE_MAPPINGS")}
        env["ASC_PRIVATE_KEY_PATH"] = path
        result = subprocess.run([sys.executable, "scripts/app_store_notes.py", "--candidate", os.environ["CANDIDATE_BUILD"],
                                 "--output", str(intent), "--sources", str(mapping)], env=env,
                                capture_output=True, timeout=180)
        notes.require(result.returncode == 0 and len(result.stdout) <= notes.MAX_BYTES, "Public generation failed; inspect source/baseline setup.")
        payload = json.loads(result.stdout)
        notes.require(payload.get("status") == "draft", "Unexpected generation result.")
    with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as summary:
        summary.write("## Public draft — review only\n\n<pre>" + html.escape(json.dumps(payload, indent=2, ensure_ascii=True)) + "</pre>\n")


def main():
    signal.signal(signal.SIGTERM, stopped)
    signal.signal(signal.SIGINT, stopped)
    try:
        if os.environ.get("RELEASE_PHASE") == "gate":
            values = gate()
            with Path(os.environ["GITHUB_OUTPUT"]).open("a") as out:
                out.write("".join(k + "=" + v + "\n" for k, v in values.items()))
        elif os.environ.get("RELEASE_PHASE") == "generate":
            generate()
        else:
            raise ValueError
        return 0
    except Exception:
        print("Public draft stopped safely. No Apple writes. Verify default branch, explicit candidate, separate publication approval, baseline and source mappings; recovery uses original artifacts without Apple access.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())