"""GitHub delivery boundary: real temporary Git objects, stubbed gh transport only.

Primary owner for artifact authority, append-only PM edits, CAS, PR reuse and
uncertain-write recovery. Source generation remains owned by generator tests.
"""

import base64
import copy
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
from urllib.parse import parse_qs, urlsplit
import unittest
from unittest.mock import patch
import zipfile

import test_release_notes as fixtures

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_notes as notes
import release_publish as publisher
import testflight_notes

ROOT = Path(__file__).resolve().parents[2]
RUN = subprocess.run
BRANCH = "release-notes/drafts"


class GitHub:
    """Protocol fixture using actual Git refs/content; never invokes real gh."""

    def __init__(self, owner):
        self.owner = owner
        self.repo = owner.root / "github"
        RUN(["git", "clone", "--quiet", str(owner.repo), str(self.repo)], env=owner.env, check=True)
        self.commit("main", "CHANGELOG.md", (ROOT / "CHANGELOG.md").read_text())
        self.requests, self.writes, self.prs, self.errors = [], [], [], []
        self.failure = self.race = None
        self.read_overrides = {}
        self.producer = {"id": 42, "workflow_id": 10, "head_sha": owner.candidate,
                         "repository": {"id": 99, "full_name": "intent-hq/ios"},
                         "head_repository": {"id": 99, "full_name": "intent-hq/ios"},
                         "head_branch": "main", "path": ".github/workflows/release-notes.yml",
                         "event": "workflow_dispatch", "pull_requests": []}
        self.workflow = {"id": 10, "path": self.producer["path"]}
        self.artifact = {"id": 8, "name": "release-notes-app-store-intent", "expired": False,
                         "workflow_run": {"id": 42, "head_sha": owner.candidate}}
        self.artifacts = [self.artifact]
        self.archive = b""

    def git(self, *args, input=None):
        return RUN(["git", "-C", str(self.repo), *args], input=input, env=self.owner.env,
                   check=True, capture_output=True).stdout.decode().strip()

    def commit(self, branch, path, content):
        self.git("checkout", "--quiet", branch)
        (self.repo / path).write_text(content)
        self.git("add", "--", path)
        self.git("commit", "--quiet", "-m", "Fixture edit")
        return self.git("rev-parse", "HEAD")

    def head(self, branch):
        result = RUN(["git", "-C", str(self.repo), "rev-parse", "--verify", "refs/heads/" + branch],
                     env=self.owner.env, capture_output=True)
        return result.stdout.decode().strip() if result.returncode == 0 else None

    def document(self, branch=BRANCH):
        return self.git("show", branch + ":CHANGELOG.md") + "\n"

    def freeze(self, payload, channel="app-store", path="intent.json", symlink=False):
        frozen = {"schema_version": 1, "payload": payload}
        if channel == "beta":
            frozen.update(source_group_id="101", destination_group_id="102", beta_members=["199"],
                          metadata=testflight_notes.metadata_plan(payload, None), notes_status="planned",
                          assignment_status="not_attempted", publication_status="not_requested")
            frozen["plan_sha256"] = testflight_notes.digest(testflight_notes.immutable(frozen))
        name = "testflight-beta.yml" if channel == "beta" else "release-notes.yml"
        self.producer["path"] = self.workflow["path"] = ".github/workflows/" + name
        self.artifact["name"] = "testflight-beta-intent-" + payload["candidate"]["build_id"] if channel == "beta" else "release-notes-app-store-intent"
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w") as archive:
            info = zipfile.ZipInfo(path)
            if symlink: info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, json.dumps(frozen))
        self.archive = output.getvalue()

    def pr(self):
        return {"number": 12, "state": "open", "draft": True, "merged_at": None,
                "head": {"ref": BRANCH, "sha": self.head(BRANCH), "repo": {"full_name": "intent-hq/ios"}},
                "base": {"ref": "main", "repo": {"full_name": "intent-hq/ios"}},
                "user": {"login": "github-actions[bot]"}, "body": "<!-- intent-release-notes-pr:v1 -->\nReview"}

    def read(self, endpoint):
        if endpoint in self.read_overrides: return self.read_overrides[endpoint]
        path = endpoint.removeprefix("repos/intent-hq/ios/")
        if path == "actions/runs/42": return self.producer
        if path.startswith("actions/workflows/"): return self.workflow
        if path == "actions/runs/42/artifacts?per_page=100":
            return {"total_count": len(self.artifacts), "artifacts": self.artifacts}
        if path == "actions/artifacts/8/zip": return self.archive
        if path == "git/ref/heads/main": return {"ref": "refs/heads/main", "object": {"sha": self.head("main")}}
        if path == "git/matching-refs/heads/" + BRANCH:
            sha = self.head(BRANCH)
            return [{"ref": "refs/heads/" + BRANCH, "object": {"sha": sha}}] if sha else []
        if path.startswith("pulls?"):
            for pr in self.prs: pr["head"]["sha"] = self.head(BRANCH)
            return self.prs
        if path.startswith("contents/CHANGELOG.md?"):
            sha = parse_qs(urlsplit(path).query)["ref"][0]
            raw = RUN(["git", "-C", str(self.repo), "show", sha + ":CHANGELOG.md"], env=self.owner.env,
                      capture_output=True, check=True).stdout
            return {"type": "file", "path": "CHANGELOG.md", "encoding": "base64", "size": len(raw),
                    "content": base64.b64encode(raw).decode()}
        if path.startswith("compare/"):
            base, head = path.removeprefix("compare/").split("...")
            ancestor = self.git("merge-base", base, head)
            files = self.git("diff", "--name-status", base, head).splitlines()
            return {"status": "ahead" if ancestor == base else "diverged", "merge_base_commit": {"sha": ancestor},
                    "files": [{"filename": row.split("\t")[-1], "status": "modified" if row.startswith("M\t") else "added"} for row in files]}
        if path.startswith("commits/"):
            return {"author": {"login": "github-actions[bot]"}, "commit": {
                "message": self.git("show", "-s", "--format=%B", path.split("/")[-1])}}
        raise AssertionError("Unexpected read endpoint: " + path)

    def __call__(self, args, **kwargs):
        try:
            return self.respond(args, **kwargs)
        except AssertionError as error:
            self.errors.append(str(error))
            raise

    def respond(self, args, **kwargs):
        if args[0] == "git": return RUN(args, **kwargs)
        self.owner.assertEqual(args[0], "gh", "Only the gh boundary may be replaced")
        env = kwargs["env"]
        self.owner.assertLessEqual(set(env), {"PATH", "GH_TOKEN"})
        self.requests.append(args)
        if "GET" in args:
            response = self.read(args[-1])
        else:
            self.owner.assertEqual(env["GH_TOKEN"], "fixture-write", "Read-only job attempted a mutation")
            self.writes.append(args)
            if args[1:3] == ["pr", "create"]:
                self.owner.assertIn("--draft", args)
                self.owner.assertEqual(args[args.index("--base") + 1], "main")
                self.owner.assertEqual(args[args.index("--head") + 1], BRANCH)
                phase = "create_pr"
                self.prs.append(self.pr())
                response = b"https://github.com/intent-hq/ios/pull/12\n"
            elif "graphql" in args:
                phase = "commit"
                data = json.loads(kwargs["input"])["variables"]["input"]
                self.owner.assertEqual(data["branch"], {"repositoryNameWithOwner": "intent-hq/ios", "branchName": BRANCH})
                if self.race:
                    self.commit(BRANCH, "CHANGELOG.md", self.document() + "PM concurrent edit\n")
                    self.race = None
                if data["expectedHeadOid"] != self.head(BRANCH):
                    response = {"errors": [{"message": "Expected head mismatch"}]}
                else:
                    additions = data["fileChanges"]["additions"]
                    self.owner.assertEqual(len(additions), 1)
                    self.owner.assertEqual(additions[0]["path"], "CHANGELOG.md")
                    raw = base64.b64decode(additions[0]["contents"]).decode()
                    self.commit(BRANCH, "CHANGELOG.md", raw)
                    self.git("commit", "--amend", "--quiet", "-m", data["message"]["headline"] + "\n\n" + data["message"]["body"])
                    response = {"data": {"createCommitOnBranch": {"commit": {"oid": self.head(BRANCH)}}}}
            else:
                phase = "create_branch"
                self.owner.assertEqual(args[-3:], ["repos/intent-hq/ios/git/refs", "--input", "-"])
                data = json.loads(kwargs["input"])
                self.owner.assertEqual(data["ref"], "refs/heads/" + BRANCH)
                self.git("branch", BRANCH, data["sha"])
                response = {}
            if self.failure == phase:
                return subprocess.CompletedProcess(args, 1)
        raw = response if isinstance(response, bytes) else json.dumps(response).encode()
        kwargs["stdout"].write(raw)
        return subprocess.CompletedProcess(args, 0)


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.owner = fixtures.ReleaseNotesTests()
        self.owner.setUp()
        self.addCleanup(self.owner.doCleanups)
        self.addCleanup(lambda: self.assertEqual(self.owner.api.errors, []))
        self.github = GitHub(self.owner)
        self.addCleanup(lambda: self.assertEqual(self.github.errors, []))
        self.env = {"PATH": os.environ["PATH"], "GH_TOKEN": "fixture-write", "RUNNER_TEMP": str(self.owner.root),
                    "GITHUB_REPOSITORY": "intent-hq/ios", "GITHUB_REPOSITORY_ID": "99", "GITHUB_REF": "refs/heads/main",
                    "DEFAULT_BRANCH": "main", "GITHUB_RUN_ATTEMPT": "1", "SOURCE_RUN_ID": "42",
                    "RELEASE_CHANNEL": "app-store", "PUBLICATION_MODE": "publish", "RELEASE_NOTES_PUBLICATION_ENABLED": "true"}
        self.payload = self.payload_for("app-store")
        self.github.freeze(self.payload)

    def payload_for(self, channel):
        self.owner.request["channel"] = channel
        return self.owner.generate()

    def execute(self, **env):
        previous = os.getcwd()
        try:
            os.chdir(self.owner.repo)
            output = io.StringIO()
            with patch.dict(os.environ, dict(self.env, **env), clear=True), \
                    patch.object(subprocess, "run", side_effect=self.github), redirect_stdout(output):
                result = publisher.main()
        finally:
            os.chdir(previous)
        receipt = json.loads((self.owner.root / "release-publication/receipt.json").read_text())
        return result, receipt

    def test_preview_has_zero_mutations_then_publish_uses_notes_only_draft_pr(self):
        main = self.github.head("main")
        result, receipt = self.execute(PUBLICATION_MODE="preview", GH_TOKEN="fixture-read")
        self.assertEqual((result, receipt["status"], self.github.writes), (0, "preview", []))
        self.assertIsNone(self.github.head(BRANCH))
        self.assertEqual(self.execute()[0], 0)
        self.assertEqual(len(self.github.writes), 3)
        self.assertEqual(self.github.head("main"), main)
        self.assertEqual(self.github.git("diff", "--name-only", "main", BRANCH), "CHANGELOG.md")
        document = self.github.document()
        self.assertIn("## 1.2.1\n\n### Beta\n\n### App Store", document)
        self.assertIn(self.payload["comparison_url"], document)
        self.assertEqual(len(self.github.prs), 1)

    def test_interleaved_channels_builds_versions_and_pm_edits_survive_original_retries(self):
        beta = self.payload_for("beta")
        self.github.freeze(beta, "beta")
        self.assertEqual(self.execute(RELEASE_CHANNEL="beta")[0], 0)
        edited = self.github.document().replace("- Keep drafts", "- PM approved wording")
        edited += "PM release checklist stays here.\n"
        self.github.commit(BRANCH, "CHANGELOG.md", edited)
        writes = len(self.github.writes)
        self.assertEqual(self.execute(RELEASE_CHANNEL="beta")[0], 0)
        self.assertEqual(len(self.github.writes), writes)
        self.assertEqual(self.github.document(), edited)
        self.github.freeze(self.payload)
        self.assertEqual(self.execute()[0], 0)
        self.assertEqual(len(self.github.prs), 1)
        self.assertIn(edited.split("### App Store")[0], self.github.document())
        self.assertIn("PM release checklist stays here.", self.github.document())
        first = self.github.document()
        writes = len(self.github.writes)
        self.assertEqual(self.execute()[0], 0)
        self.assertEqual(self.github.document(), first)
        self.assertEqual(len(self.github.writes), writes)
        for version, build_id in (("1.2.1", "201"), ("1.10.0", "202"), ("1.2.5", "203")):
            self.owner.api.data["builds"][build_id] = copy.deepcopy(self.owner.api.data["builds"]["200"])
            page = self.owner.api.data["builds"][build_id]
            page["data"]["id"] = build_id
            for row in page["included"]:
                if row["type"] == "preReleaseVersions": row["attributes"]["version"] = version
            self.owner.api.data["runs"][build_id] = copy.deepcopy(self.owner.api.data["runs"]["200"])
            run_id = str(600 + int(build_id))
            self.owner.api.data["runs"][build_id]["data"][0]["id"] = run_id
            self.owner.api.data["members"][run_id] = {"data": [{"id": build_id, "type": "builds"}],
                                                      "links": {"self": f"/v1/ciBuildRuns/{run_id}/relationships/builds"}}
            self.owner.request["candidate"]["build_id"] = build_id
            payload = self.payload_for("beta")
            self.github.freeze(payload, "beta")
            self.assertEqual(self.execute(RELEASE_CHANNEL="beta")[0], 0)
        text = self.github.document()
        self.assertLess(text.index("## 1.10.0"), text.index("## 1.2.5"))
        self.assertLess(text.index("## 1.2.5"), text.index("## 1.2.1"))
        for key in (beta["entry_key"], self.payload["entry_key"], "100:IOS:1.2.1:beta:201:en-US"):
            self.assertIn(key, text)
        self.assertIn("PM release checklist stays here.", text)

    def test_uncertain_commit_and_pr_responses_stop_then_original_recovery_preserves_content(self):
        for phase in ("commit", "create_pr"):
            with self.subTest(phase=phase):
                self.github.failure = phase
                result, receipt = self.execute()
                self.assertEqual(result, 1)
                self.assertEqual((receipt["status"], receipt["phase"]), ("uncertain", phase))
                before, writes = self.github.document(), len(self.github.writes)
                self.github.failure = None
                self.assertEqual(self.execute(PUBLICATION_MODE="preview", GH_TOKEN="fixture-read")[0], 0)
                self.assertEqual(len(self.github.writes), writes)
                self.assertEqual(self.execute()[0], 0)
                self.assertEqual(self.github.document(), before)
                if phase == "commit":
                    self.github.prs.clear()
                else:
                    self.assertEqual(len(self.github.prs), 1)

    def test_stale_main_other_paths_unowned_pr_and_cas_race_are_preserved_not_overwritten(self):
        self.assertEqual(self.execute()[0], 0)
        self.github.commit(BRANCH, "CHANGELOG.md", self.github.document() + "PM edit\n")
        original = self.github.document()
        writes = len(self.github.writes)
        self.github.prs[0]["user"]["login"] = "someone-else"
        self.assertEqual(self.execute()[0], 1)
        self.github.prs[0]["user"]["login"] = "github-actions[bot]"
        self.github.commit(BRANCH, "App.swift", "Unrelated change")
        self.assertEqual(self.execute()[0], 1)
        self.github.commit("main", "App.swift", "Main advanced")
        self.assertEqual(self.execute()[0], 1)
        self.assertEqual(len(self.github.writes), writes)
        self.assertEqual(self.github.document(), original)

    def test_expected_head_cas_rejects_concurrent_pm_edit(self):
        self.github.race = True
        result, receipt = self.execute()
        self.assertEqual(result, 1)
        self.assertIn(receipt["status"], ("observing", "uncertain"))
        self.assertIn("PM concurrent edit", self.github.document())
        self.assertNotIn(self.payload["entry_key"], self.github.document())
        self.assertEqual(len(self.github.writes), 2)
        self.assertFalse(self.github.prs)

    def test_artifact_hash_does_not_replace_producer_identity_path_or_retention(self):
        mutations = [("event", "pull_request"), ("head_branch", "feature"), ("workflow_id", 11),
                     ("repository", {"id": 98, "full_name": "intent-hq/ios"}),
                     ("head_repository", {"id": 99, "full_name": "someone/fork"}),
                     ("path", ".github/workflows/untrusted.yml"), ("head_sha", "f" * 40)]
        for field, value in mutations:
            with self.subTest(field=field):
                original = self.github.producer[field]
                self.github.producer[field] = value
                self.assertEqual(self.execute()[0], 1)
                self.github.producer[field] = original
        for path, symlink in (("../intent.json", False), ("intent.json", True)):
            self.github.freeze(self.payload, path=path, symlink=symlink)
            self.assertEqual(self.execute()[0], 1)
        self.github.freeze(self.payload)
        self.github.artifact["expired"] = True
        self.assertEqual(self.execute()[0], 1)
        self.github.artifact["expired"] = False
        self.github.artifacts.append(copy.deepcopy(self.github.artifact))
        self.assertEqual(self.execute()[0], 1)
        self.assertEqual(self.github.writes, [])

    def test_validly_hashed_wrong_target_and_payload_conflict_fail_closed(self):
        bad = copy.deepcopy(self.payload)
        bad["target_path"] = "App.swift"
        bad["content_sha256"] = testflight_notes.digest({k: v for k, v in bad.items() if k != "content_sha256"})
        self.github.freeze(bad)
        self.assertEqual(self.execute()[0], 1)
        self.assertEqual(self.github.writes, [])
        self.github.freeze(self.payload)
        self.assertEqual(self.execute()[0], 0)
        first = self.github.document()
        self.owner.request["baseline_reference"] = "Another independently chosen baseline explanation"
        self.github.freeze(self.payload_for("app-store"))
        writes = len(self.github.writes)
        self.assertEqual(self.execute()[0], 1)
        self.assertEqual(len(self.github.writes), writes)
        self.assertEqual(self.github.document(), first)

    def test_publisher_rejects_apple_credentials_unapproved_modes_and_rerun_writes(self):
        for env in ({"ASC_KEY_ID": "fixture"}, {"RELEASE_NOTES_PUBLICATION_ENABLED": ""},
                    {"RELEASE_NOTES_PUBLICATION_ENABLED": "TRUE"}, {"GITHUB_RUN_ATTEMPT": "2"},
                    {"GITHUB_REF": "refs/heads/feature"}, {"PUBLICATION_MODE": "invalid"}):
            with self.subTest(env=env): self.assertEqual(self.execute(**env)[0], 1)
        self.assertEqual(self.github.requests, [])

    def test_merged_original_is_a_noop_and_missing_branch_never_makes_an_empty_pr(self):
        self.assertEqual(self.execute()[0], 0)
        original = self.github.document()
        self.github.git("checkout", "main")
        self.github.git("merge", "--ff-only", BRANCH)
        self.github.git("branch", "-d", BRANCH)
        self.github.prs[0].update(state="closed", merged_at="2026-09-27T00:00:00Z")
        writes = len(self.github.writes)
        result, receipt = self.execute()
        self.assertEqual((result, receipt["status"]), (0, "already_present"))
        self.assertEqual(len(self.github.writes), writes)
        self.assertEqual(self.github.document("main"), original)

    def test_malformed_document_and_closed_unmerged_pr_need_human_reconciliation(self):
        self.assertEqual(self.execute()[0], 0)
        original = self.github.document()
        writes = len(self.github.writes)
        for malformed in (original + "### Unexpected\n", original.replace("### Beta", "### App Store"),
                          original.replace("<!-- /intent-release-entry -->", ""),
                          original + "## 1.2.1\n\n### Beta\n\n### App Store\n"):
            self.github.commit(BRANCH, "CHANGELOG.md", malformed)
            self.assertEqual(self.execute()[0], 1)
            self.assertEqual(self.github.document(), malformed.rstrip() + "\n")
        self.github.commit(BRANCH, "CHANGELOG.md", original)
        self.github.prs[0]["state"] = "closed"
        self.assertEqual(self.execute()[0], 1)
        self.assertEqual(len(self.github.writes), writes)


if __name__ == "__main__":
    unittest.main()