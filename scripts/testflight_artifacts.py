#!/usr/bin/env python3
"""Restore the original Beta intent using read-only GitHub artifact APIs.

Run without Apple credentials. Only same-repository default-branch runs of this
workflow are trusted; PR artifacts, ambiguity, expiry and incomplete lists block.
A rerun restores its own intent even when a newer Alpha build now exists. Fresh
runs look up the exact candidate. Retain intent artifacts for 90 days (TestFlight
build lifetime); never manually delete recovery evidence for an eligible build.
The original intent is a conservative write-intent record, not proof of success:
restoration always enters the CLI's read-only reconciliation path.
"""

import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.parse import urlencode
import zipfile

import release_notes as notes
import testflight_notes


def api(endpoint, binary=False):
    # No headers, tokens, signed download URLs or raw error bodies reach logs.
    env = {k: os.environ[k] for k in ("PATH", "GH_TOKEN") if k in os.environ}
    with tempfile.TemporaryFile() as output:
        result = subprocess.run(["gh", "api", "--hostname", "github.com", "--method", "GET", endpoint],
                                env=env, stdout=output, stderr=subprocess.DEVNULL, timeout=30)
        notes.require(result.returncode == 0 and output.tell() <= notes.MAX_BYTES, "Artifact read failed or exceeded limits; no new plan allowed.")
        output.seek(0)
        raw = output.read()
    return raw if binary else json.loads(raw)


def main():
    try:
        notes.require(os.environ.get("GITHUB_REPOSITORY") == "intent-hq/ios", "Wrong workflow repository.")
        branch = notes.text(os.environ.get("DEFAULT_BRANCH"), 200)
        notes.require(os.environ.get("GITHUB_REF") == "refs/heads/" + branch, "Artifact recovery requires the default branch.")
        root = Path(os.environ["RUNNER_TEMP"]) / "testflight"
        selection = notes.load_json(root / "selection.json")
        rerun = int(os.environ["GITHUB_RUN_ATTEMPT"]) > 1
        prefix = "repos/intent-hq/ios/actions/"
        if rerun:
            run_id = os.environ["GITHUB_RUN_ID"]
            notes.require(run_id.isdigit(), "Invalid workflow run identity.")
            endpoint = prefix + f"runs/{run_id}/artifacts?per_page=100"
        elif selection.get("result") == "selected":
            build_id = notes.identifier(selection.get("build_id"))
            endpoint = prefix + "artifacts?" + urlencode({"name": "testflight-beta-intent-" + build_id, "per_page": 100})
        else:
            return 0
        page = api(endpoint)
        rows = page.get("artifacts")
        notes.require(isinstance(rows, list) and type(page.get("total_count")) is int and page["total_count"] == len(rows),
                      "Incomplete artifact list; no fresh promotion allowed.")
        intents = [a for a in rows if isinstance(a.get("name"), str) and a["name"].startswith("testflight-beta-intent-")]
        notes.require(len(intents) <= 1, "Multiple original intents; reconcile manually without replacing evidence.")
        if not intents:
            # Reruns never create a fresh write plan: checkpoint failure/cancellation
            # needs a new, deliberately started run instead of reusing this run.
            notes.require(not rerun, "Rerun has no recoverable intent; inspect the original run before starting a new run.")
            return 0
        artifact = intents[0]
        notes.require(artifact.get("expired") is False, "Original intent expired; human recovery is required.")
        artifact_id = artifact.get("id")
        notes.require(type(artifact_id) is int and artifact_id > 0, "Invalid artifact identity.")
        run_id = artifact.get("workflow_run", {}).get("id") if not rerun else int(os.environ["GITHUB_RUN_ID"])
        notes.require(type(run_id) is int and run_id > 0, "Missing artifact workflow identity.")
        run = api(prefix + f"runs/{run_id}")
        notes.require(run.get("path") == ".github/workflows/testflight-beta.yml" and run.get("head_branch") == branch
                      and run.get("event") in ("schedule", "workflow_dispatch")
                      and run.get("head_repository", {}).get("full_name") == "intent-hq/ios",
                      "Artifact was not produced by the trusted default-branch Beta workflow.")
        raw = api(prefix + f"artifacts/{artifact_id}/zip", binary=True)
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            entries = archive.infolist()
            notes.require(len(entries) == 1 and entries[0].filename == "intent.json" and entries[0].file_size <= notes.MAX_BYTES,
                          "Unexpected artifact contents; no archive paths are extracted.")
            with tempfile.TemporaryDirectory(prefix="beta-artifact-") as temporary:
                path = Path(temporary) / "intent.json"
                path.write_bytes(archive.read(entries[0]))
                frozen = testflight_notes.load(path, ".")
        expected_name = "testflight-beta-intent-" + frozen["payload"]["candidate"]["build_id"]
        notes.require(artifact["name"] == expected_name and (rerun or frozen["payload"]["candidate"]["build_id"] == build_id),
                      "Artifact candidate mismatch.")
        testflight_notes.save_new(root / "intent.json", frozen)
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write(f"source_run={run_id}\n")
        print("Original Beta intent restored; this run will reconcile without Apple writes.")
        return 0
    except Exception:
        print("Beta intent recovery failed safely. Keep the original artifacts; inspect their identity, retention and source history. No fresh plan or writes are allowed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())