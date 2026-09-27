#!/usr/bin/env python3
"""Credential-separated, bounded GitHub-only publication using frozen originals.

Only trusted same-repository/default-branch producers are read. Hashes verify
integrity, NOT origin; REST run/workflow/artifact identity is checked separately.
All mutations use gh, never main, never merge. One shared branch/PR prevents
interleaved channels from dropping pending PM edits. Changed base/ownership stops
for human reconciliation; no automatic rebase, force-push or uncertain retry.
"""

import base64
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
from urllib.parse import urlencode
import zipfile

import changelog
import release_notes as notes
import testflight_notes
from testflight_artifacts import api

REPO = "intent-hq/ios"
PREFIX = "repos/" + REPO
BRANCH = "release-notes/drafts"
OWNERSHIP = "<!-- intent-release-notes-pr:v1 -->"
COMMIT = "chore: draft release notes\n\nIntent-Release-Notes: v1"


def context():
    notes.require(os.environ.get("GITHUB_REPOSITORY") == REPO, "Wrong repository.")
    branch = notes.text(os.environ.get("DEFAULT_BRANCH"), 100)
    notes.require(re.fullmatch(r"[A-Za-z0-9_.-]+", branch) and branch != BRANCH,
                  "Unsupported default branch identity.")
    notes.require(os.environ.get("GITHUB_REF") == "refs/heads/" + branch, "Default branch required.")
    notes.require(not any(k.startswith("ASC_") for k in os.environ), "Apple credentials/configuration must not enter the publisher.")
    mode = os.environ.get("PUBLICATION_MODE", "preview")
    notes.require(mode in ("preview", "publish"), "Explicit publication mode required.")
    if mode == "publish":
        notes.require(os.environ.get("RELEASE_NOTES_PUBLICATION_ENABLED") == "true", "Repository publication is disabled.")
        notes.require(os.environ.get("GITHUB_RUN_ATTEMPT") == "1", "Reruns reconcile read-only; use a reviewed recovery dispatch to publish.")
    return branch, mode


def original(repo, branch, run_id, channel):
    notes.require(isinstance(run_id, str) and run_id.isdigit() and int(run_id) > 0, "Explicit producer run required.")
    notes.require(channel in ("beta", "app-store"), "Unknown release channel.")
    workflow = "testflight-beta.yml" if channel == "beta" else "release-notes.yml"
    run = api(PREFIX + f"/actions/runs/{run_id}")
    configured = api(PREFIX + "/actions/workflows/" + workflow)
    repository_id = os.environ.get("GITHUB_REPOSITORY_ID", "")
    notes.require(repository_id.isdigit() and run.get("repository", {}).get("id") == int(repository_id)
                  and run.get("head_repository", {}).get("id") == int(repository_id)
                  and run.get("repository", {}).get("full_name") == REPO
                  and run.get("head_repository", {}).get("full_name") == REPO
                  and run.get("id") == int(run_id) and run.get("head_branch") == branch
                  and run.get("path") == ".github/workflows/" + workflow
                  and configured.get("path") == run["path"] and configured.get("id") == run.get("workflow_id")
                  and type(run.get("workflow_id")) is int
                  and run.get("event") in (("schedule", "workflow_dispatch") if channel == "beta" else ("workflow_dispatch",))
                  and run.get("pull_requests") == [], "Untrusted producer identity; never accept PR/fork artifacts.")
    source = notes.revision(run.get("head_sha"))
    # Proves this workflow revision is retained in the reviewed default history.
    git = notes.Git(repo, testflight_notes.REPOSITORY)
    git.run("merge-base", "--is-ancestor", source, "HEAD")
    page = api(PREFIX + f"/actions/runs/{run_id}/artifacts?per_page=100")
    rows = page.get("artifacts")
    notes.require(isinstance(rows, list) and type(page.get("total_count")) is int and page["total_count"] == len(rows),
                  "Incomplete artifact listing; no publication allowed.")
    name = "testflight-beta-intent-" if channel == "beta" else "release-notes-app-store-intent"
    matches = [a for a in rows if isinstance(a.get("name"), str) and
               (a["name"].startswith(name) if channel == "beta" else a["name"] == name)]
    notes.require(len(matches) == 1, "No unique original intent; retain evidence and reconcile manually.")
    artifact = matches[0]
    notes.require(artifact.get("expired") is False and type(artifact.get("id")) is int and artifact["id"] > 0
                  and artifact.get("workflow_run", {}).get("id") == int(run_id)
                  and artifact["workflow_run"].get("head_sha") == source, "Artifact identity or retention mismatch.")
    raw = api(PREFIX + f"/actions/artifacts/{artifact['id']}/zip", binary=True)
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        files = archive.infolist()
        notes.require(len(files) == 1 and files[0].filename == "intent.json"
                      and not files[0].is_dir() and not stat.S_ISLNK(files[0].external_attr >> 16)
                      and not files[0].flag_bits & 1 and files[0].file_size <= notes.MAX_BYTES,
                      "Unexpected artifact paths or content bounds.")
        with tempfile.TemporaryDirectory(prefix="release-original-") as directory:
            path = Path(directory) / "intent.json"
            path.write_bytes(archive.read(files[0]))
            if channel == "beta":
                frozen = testflight_notes.load(path, repo)
                notes.require(artifact["name"] == name + frozen["payload"]["candidate"]["build_id"], "Artifact build mismatch.")
            else:
                frozen = notes.load_json(path)
                testflight_notes.keys(frozen, "schema_version payload")
                notes.require(frozen["schema_version"] == 1, "Unknown public intent schema.")
                testflight_notes.validate_payload(repo, frozen["payload"], "app-store")
    return frozen["payload"], artifact["id"]


def refs():
    # Matching-refs avoids treating an auth/network failure as an absent branch.
    rows = api(PREFIX + "/git/matching-refs/heads/" + BRANCH)
    notes.require(isinstance(rows, list) and len(rows) <= 10, "Ambiguous publication refs.")
    exact = [r for r in rows if r.get("ref") == "refs/heads/" + BRANCH]
    notes.require(len(exact) <= 1, "Ambiguous publication branch.")
    return notes.revision(exact[0]["object"]["sha"]) if exact else None


def main_head(branch):
    row = api(PREFIX + "/git/ref/heads/" + branch)
    notes.require(row.get("ref") == "refs/heads/" + branch, "Wrong base ref.")
    return notes.revision(row["object"]["sha"])


def document(sha):
    row = api(PREFIX + "/contents/CHANGELOG.md?" + urlencode({"ref": sha}))
    notes.require(row.get("type") == "file" and row.get("path") == "CHANGELOG.md" and row.get("encoding") == "base64"
                  and type(row.get("size")) is int and row["size"] <= changelog.MAX_DOCUMENT,
                  "Only a bounded root CHANGELOG.md regular file may be edited.")
    raw = base64.b64decode(row["content"].replace("\n", ""), validate=True)
    notes.require(len(raw) == row["size"], "Changelog content size mismatch.")
    return raw.decode("utf-8")


def pull_requests(branch):
    rows = api(PREFIX + "/pulls?" + urlencode({"state": "all", "head": "intent-hq:" + BRANCH, "per_page": 100}))
    notes.require(isinstance(rows, list) and len(rows) < 100, "Incomplete PR history; reconcile manually.")
    for row in rows:
        notes.require(row.get("head", {}).get("ref") == BRANCH and row["head"].get("repo", {}).get("full_name") == REPO
                      and row.get("base", {}).get("ref") == branch and row["base"].get("repo", {}).get("full_name") == REPO
                      and row.get("user", {}).get("login") == "github-actions[bot]"
                      and isinstance(row.get("body"), str) and row["body"].startswith(OWNERSHIP), "PR ownership is uncertain.")
    opened = [r for r in rows if r.get("state") == "open"]
    notes.require(len(opened) <= 1 and all(r.get("state") in ("open", "closed") for r in rows), "Ambiguous notes PR state.")
    notes.require(all(r.get("merged_at") for r in rows if r.get("state") == "closed"), "A notes PR was closed without merging; human recovery required.")
    return opened[0] if opened else None


def write(args, body, receipt, phase):
    receipt["status"], receipt["phase"] = "uncertain", phase
    save_receipt(receipt)
    env = {k: os.environ[k] for k in ("PATH", "GH_TOKEN") if k in os.environ}
    with tempfile.TemporaryFile() as out:
        result = subprocess.run(["gh", *args], input=body.encode(), env=env, stdout=out,
                                stderr=subprocess.DEVNULL, timeout=30)
        notes.require(result.returncode == 0 and out.tell() <= notes.MAX_BYTES,
                      "GitHub write is uncertain or forbidden; inspect the separate receipt and reconcile read-only. Do not retry blindly.")
        out.seek(0)
        raw = out.read()
    receipt["status"] = "observing"
    save_receipt(receipt)
    return raw


def save_receipt(receipt):
    root = Path(os.environ["RUNNER_TEMP"]) / "release-publication"
    root.mkdir(exist_ok=True)
    testflight_notes.save(root / "receipt.json", receipt)


def publish(payload, branch, mode, receipt):
    base, head, pr = main_head(branch), refs(), pull_requests(branch)
    target = head or base
    if head and head != base:
        comparison = api(PREFIX + f"/compare/{base}...{head}")
        # Stale base, diverged history or a previously merged branch requires a
        # human fast-forward/rebase. No publication can erase later main changes.
        notes.require(comparison.get("status") == "ahead" and comparison.get("merge_base_commit", {}).get("sha") == base,
                      "Notes branch has a stale base; preserve PM edits and reconcile it onto current main before publishing.")
        files = comparison.get("files")
        notes.require(isinstance(files, list) and 0 < len(files) <= 1 and files[0].get("filename") == "CHANGELOG.md"
                      and files[0].get("status") == "modified", "Notes branch changes more than the root changelog.")
        if pr is None:
            commit = api(PREFIX + f"/commits/{head}")
            notes.require(commit.get("author", {}).get("login") == "github-actions[bot]"
                          and commit.get("commit", {}).get("message") == COMMIT, "Unowned branch without a notes PR.")
    if pr:
        notes.require(head and pr["head"].get("sha") == head, "PR head changed; reconcile before publication.")
    before = document(target)
    after = changelog.insert(before, payload)
    receipt.update(base=base, previous_head=head, entry_key=payload["entry_key"], content_sha256=payload["content_sha256"],
                   changed=before != after, status="preview" if mode == "preview" else "planned")
    save_receipt(receipt)
    if mode == "preview":
        return receipt
    notes.require(main_head(branch) == base and refs() == head and pull_requests(branch) == pr,
                  "Destination changed after reading; no writes attempted.")
    if before == after and not pr:
        # Already merged into main is a complete no-op, not a new empty PR.
        if target == base:
            receipt["status"] = "already_present"
            return receipt
    if head is None:
        write(["api", "--hostname", "github.com", "--method", "POST", PREFIX + "/git/refs", "--input", "-"],
              json.dumps({"ref": "refs/heads/" + BRANCH, "sha": base}), receipt, "create_branch")
        notes.require(refs() == base, "Branch creation not confirmed; reconcile without retry.")
        head = base
    if before != after:
        query = "mutation($input:CreateCommitOnBranchInput!){createCommitOnBranch(input:$input){commit{oid}}}"
        data = {"query": query, "variables": {"input": {"branch": {"repositoryNameWithOwner": REPO, "branchName": BRANCH},
                "expectedHeadOid": head, "message": {"headline": COMMIT.split("\n")[0], "body": COMMIT.split("\n\n")[1]},
                "fileChanges": {"additions": [{"path": "CHANGELOG.md", "contents": base64.b64encode(after.encode()).decode()}]}}}}
        response = json.loads(write(["api", "--hostname", "github.com", "graphql", "--input", "-"], json.dumps(data), receipt, "commit"))
        notes.require(not response.get("errors"), "Commit response uncertain; reconcile using the original payload.")
        head = notes.revision(response["data"]["createCommitOnBranch"]["commit"]["oid"])
        notes.require(refs() == head and document(head) == after and main_head(branch) == base,
                      "Post-write content/ref verification failed; stop and reconcile.")
    if pr is None:
        body = OWNERSHIP + "\n\nReview drafts in CHANGELOG.md; edit copy/review status without removing identity markers. No Apple submission or release. Human merge only.\n"
        write(["pr", "create", "--repo", REPO, "--base", branch, "--head", BRANCH, "--draft",
               "--title", "docs: review release-note drafts", "--body-file", "-"], body, receipt, "create_pr")
        pr = pull_requests(branch)
        notes.require(pr is not None and pr["head"].get("sha") == head, "PR creation not confirmed; reconcile before another write.")
    receipt.update(status="published", head=head, pull_request=pr["number"])
    return receipt


def main():
    receipt = {"status": "not_started", "apple_operations": "not_attempted"}
    try:
        branch, mode = context()
        source, channel = os.environ.get("SOURCE_RUN_ID"), os.environ.get("RELEASE_CHANNEL")
        payload, artifact = original(".", branch, source, channel)
        receipt.update(producer_run=source, artifact_id=artifact)
        receipt = publish(payload, branch, mode, receipt)
        save_receipt(receipt)
        print(json.dumps(receipt, sort_keys=True))
        return 0
    except Exception:
        receipt["action"] = "Publication stopped. Preserve original intent and receipt; inspect producer, permissions, PR ownership and stale refs, then reconcile in preview. Apple operations were not replayed."
        if receipt["status"] not in ("uncertain", "observing"):
            receipt["status"] = "blocked"
        save_receipt(receipt)
        print(json.dumps(receipt, sort_keys=True))
        return 1


if __name__ == "__main__":
    sys.exit(main())