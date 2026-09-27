"""Behavioral generator/GET-contract tests, with real disposable Git histories.

Owner boundaries: generate() for provenance/ranges/rendering; main() for offline
CLI input/output. Existing promotion tests do not exercise either boundary.
Expected notes are hand-authored, not obtained from the renderer under test.
"""

import copy
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import urlencode

SCRIPT = Path(__file__).resolve().parents[1] / "release_notes.py"
SPEC = importlib.util.spec_from_file_location("release_notes", SCRIPT)
notes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(notes)
FIXTURE = json.loads((Path(__file__).parent / "fixtures/release_notes_api.json").read_text())


class FixtureReads:
    """A narrow synthetic GET transport; no production selection logic here."""

    def __init__(self, case):
        self.case = case
        self.data = copy.deepcopy(FIXTURE)
        self.calls, self.errors, self.snapshots = [], [], {}
        self.pages = {}

    def __call__(self, path, query=None):
        try:
            result = self.respond(path, query)
            key = path + ("?" + urlencode(sorted(query.items())) if query else "")
            self.snapshots[key] = copy.deepcopy(result)
            return copy.deepcopy(result)
        except AssertionError as error:
            self.errors.append(str(error))
            raise

    def respond(self, path, query):
        self.calls.append((path, query))
        if path.startswith("https://"):
            self.case.assertIsNone(query)
            self.case.assertIn(path, self.pages)
            return self.pages[path]
        template = re.sub(r"/[0-9]+", "/{id}", path)
        self.case.assertIn(template, self.data["query_contracts"])
        contract = self.data["query_contracts"][template]
        self.case.assertEqual(set(query), set(contract))
        for name, allowed in contract.items():
            if isinstance(allowed, list):
                self.case.assertTrue(set(query[name].split(",")) <= set(allowed))
            elif isinstance(allowed, int):
                self.case.assertLessEqual(query[name], allowed)
        if template == "/v1/builds/{id}":
            return self.data["builds"][path.split("/")[3]]
        if path == "/v1/apps/100/ciProduct":
            return self.data["product"]
        if path == "/v1/ciProducts/400/buildRuns":
            return self.data["runs"][query["filter[builds]"]]
        if template == "/v1/ciBuildRuns/{id}/relationships/builds":
            return self.data["members"][path.split("/")[3]]
        self.case.assertEqual(path, "/v1/scmGitReferences/600")
        return self.data["reference"]


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="release notes ; ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "repo $(not-a-command)"
        self.repo.mkdir()
        self.env = {"PATH": os.defpath, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                    "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                    "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
        self.git("init", "-b", "main")
        self.git("remote", "add", "origin", "git@github.com:intent-hq/ios.git")
        self.base = self.commit("Initial fixture", "App.swift", "initial")
        self.candidate = self.commit("feat(chat): Keep drafts (#17)", "App.swift", "drafts")
        self.api = FixtureReads(self)
        self.request = copy.deepcopy(FIXTURE["request"])
        self.set_sha("199", self.base)
        self.set_sha("200", self.candidate)
        network = patch.object(socket, "create_connection", side_effect=AssertionError("Network forbidden"))
        network.start()
        self.addCleanup(network.stop)
        self.addCleanup(lambda: self.assertEqual(self.api.errors, [], "Test failed for unrelated API-contract mismatch"))

    def git(self, *args, input=None):
        return subprocess.run(["git", "-C", str(self.repo), *args], input=input, env=self.env,
                              check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode().strip()

    def commit(self, subject, path, content):
        (self.repo / path).write_text(content)
        self.git("add", "--", path)
        self.git("commit", "-m", subject)
        return self.git("rev-parse", "HEAD")

    def set_sha(self, build_id, sha):
        self.api.data["runs"][build_id]["data"][0]["attributes"]["sourceCommit"]["commitSha"] = sha

    def generate(self):
        return notes.generate(self.repo, self.request, self.api)

    def manual_candidate(self):
        mapping = copy.deepcopy(FIXTURE["human_mapping"])
        mapping["sha"] = self.candidate
        self.request["candidate"]["source"] = mapping
        return mapping

    def test_exact_range_expired_baseline_dedup_categories_and_refs(self):
        duplicate = self.commit("fix(chat): Keep drafts (#19)", "Other.swift", "same subject, different change")
        maintenance = self.commit("test: Exercise reconnect", "Test.swift", "test")
        bookkeeping = self.commit("docs: Release notes", "CHANGELOG.md", "PM edited notes")
        self.set_sha("200", bookkeeping)
        self.commit("feat: Not in uploaded build (#99)", "Future.swift", "later main")
        result = self.generate()
        self.assertEqual(result["changes"], [
            {"category": "product", "subject": "Keep drafts", "commits": [self.candidate, duplicate], "references": [17, 19]},
            {"category": "maintenance", "subject": "Exercise reconnect", "commits": [maintenance], "references": []},
        ])
        self.assertEqual(result["plain_text"], "1.2.1 (41) — changes for review\n\nProduct changes\n- Keep drafts (#17) (#19)\n\nMaintenance\n- Exercise reconnect")
        self.assertEqual(result["excluded_commits"], [{"sha": bookkeeping, "reason": "changelog-only"}])
        self.assertEqual(result["baseline"]["source"]["sha"], self.base)
        self.assertEqual(result["candidate"]["source"]["sha"], bookkeeping)
        for value in (self.base, self.candidate, duplicate, maintenance, bookkeeping, "/pull/17", "run `500`"):
            self.assertIn(value, result["markdown_entry"])
        self.assertNotIn("Not in uploaded", result["markdown_entry"])
        self.assertEqual(result, self.generate())
        self.assertEqual((self.repo / "CHANGELOG.md").read_text(), "PM edited notes")
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_distinct_version_channel_build_entry_keys(self):
        beta = self.generate()
        self.request["channel"] = "app-store"
        self.request["baseline_reference"] = "Latest released App Store build 199 (synthetic selection)"
        store = self.generate()
        self.assertEqual(beta["entry_key"], "100:IOS:1.2.1:beta:200:en-US")
        self.assertEqual(store["entry_key"], "100:IOS:1.2.1:app-store:200:en-US")
        self.assertEqual((beta["version_heading"], beta["channel_heading"], store["channel_heading"]),
                         ("## 1.2.1", "### Beta", "### App Store"))
        self.assertEqual(beta["target_path"], "CHANGELOG.md")
        self.assertTrue(store["review_required"])
        self.request["channel"] = "beta"
        self.request["candidate"]["build_id"] = "201"
        self.api.data["builds"]["201"] = copy.deepcopy(self.api.data["builds"]["200"])
        self.api.data["builds"]["201"]["data"]["id"] = "201"
        self.api.data["builds"]["201"]["data"]["attributes"]["version"] = "42"
        self.api.data["runs"]["201"] = self.api.data["runs"]["200"]
        self.api.data["members"]["500"]["data"].append({"type": "builds", "id": "201"})
        later_beta = self.generate()
        self.assertEqual(later_beta["entry_key"], "100:IOS:1.2.1:beta:201:en-US")
        self.assertEqual(beta["baseline"], later_beta["baseline"])

    def test_manual_mapping_is_explicit_exact_and_auditable(self):
        mapping = self.manual_candidate()
        self.api.data["runs"]["200"]["data"] = []
        result = self.generate()
        self.assertEqual(result["candidate"]["source"]["kind"], "human-verified")
        self.assertEqual(result["candidate"]["source"]["sha"], self.candidate)
        self.assertIn("Fixture reviewer", result["markdown_entry"])
        self.assertIn(mapping["evidence"], result["markdown_entry"])
        self.assertFalse(any(q and q.get("filter[builds]") == "200" for _, q in self.api.calls))

    def test_manual_mapping_rejects_mismatched_or_missing_attestation(self):
        original = copy.deepcopy(self.manual_candidate())
        for field, value, message in [
            ("app_id", "101", "exact Apple build"), ("bundle_id", "other.app", "exact Apple build"),
            ("platform", "VISION_OS", "exact Apple build"), ("build_id", "201", "exact Apple build"),
            ("version", "1.2.2", "exact Apple build"), ("build_number", "42", "exact Apple build"),
            ("repository", "https://github.com/elsewhere/ios", "repository mismatch"),
            ("verified_by", "", "text"), ("evidence", None, "text"),
            ("verified_at", "2026-09-27", "timezone"), ("verified_at", "yesterday", "date"),
            ("sha", "HEAD", "full lowercase"), ("sha", self.candidate[:12], "full lowercase"),
        ]:
            with self.subTest(field=field, value=value):
                self.request["candidate"]["source"] = dict(original, **{field: value})
                with self.assertRaisesRegex(notes.NotesError, message):
                    self.generate()

    def test_missing_baseline_never_uses_all_history(self):
        for value in (None, {}):
            with self.subTest(value=value):
                self.request["baseline"] = value
                with self.assertRaises(notes.NotesError):
                    self.generate()

    def test_no_changes_same_revision_and_bookkeeping_only(self):
        for end in (self.base, self.commit("chore: Update release notes", "CHANGELOG.md", "notes")):
            with self.subTest(end=end):
                self.set_sha("199", self.candidate if end != self.base else self.base)
                self.set_sha("200", end)
                result = self.generate()
                self.assertEqual(result["changes"], [])
                self.assertIn("No product or maintenance changes in this verified range.", result["plain_text"])

    def test_mixed_changelog_and_product_commit_is_not_dropped(self):
        (self.repo / "CHANGELOG.md").write_text("notes")
        self.git("add", "--", "CHANGELOG.md")
        end = self.commit("fix: Notes and code", "App.swift", "code")
        self.set_sha("200", end)
        self.assertIn("Notes and code", self.generate()["plain_text"])

    def test_notes_only_merge_does_not_report_baseline_product_work(self):
        self.git("checkout", "-b", "notes-branch", self.base)
        note_commit = self.commit("docs: PM notes", "CHANGELOG.md", "PM notes")
        self.git("checkout", "main")
        self.git("merge", "--no-ff", "notes-branch", "-m", "Merge notes branch")
        merge = self.git("rev-parse", "HEAD")
        self.set_sha("199", self.candidate)
        self.set_sha("200", merge)
        result = self.generate()
        self.assertEqual(result["changes"], [])
        self.assertEqual(result["excluded_commits"], [
            {"sha": note_commit, "reason": "changelog-only"}, {"sha": merge, "reason": "changelog-only"}])

    def test_product_branch_and_merge_resolution_are_included(self):
        self.git("checkout", "-b", "product-branch", self.base)
        branch = self.commit("fix: Recover drafts (#20)", "Other.swift", "recovery")
        self.git("checkout", "main")
        self.git("merge", "--no-ff", "--no-commit", "product-branch")
        merge = self.commit("fix: Resolve merge behavior (#21)", "Resolution.swift", "resolution")
        self.set_sha("199", self.candidate)
        self.set_sha("200", merge)
        result = self.generate()
        self.assertEqual([c["subject"] for c in result["changes"]], ["Recover drafts", "Resolve merge behavior"])
        self.assertEqual([c["commits"] for c in result["changes"]], [[branch], [merge]])

    def test_xcode_cloud_rejects_ambiguous_missing_or_wrong_sources(self):
        original = copy.deepcopy(self.api.data)
        mutations = [
            (lambda d: d["runs"]["200"].update(data=[]), "Missing or ambiguous"),
            (lambda d: d["runs"]["200"]["data"].append(dict(d["runs"]["200"]["data"][0], id="501")), "Missing or ambiguous"),
            (lambda d: d["members"]["500"].update(data=[]), "does not contain"),
            (lambda d: d["runs"]["200"]["data"][0]["attributes"].update(isPullRequestBuild=True), "PR or merged"),
            (lambda d: d["runs"]["200"]["data"][0]["attributes"].pop("isPullRequestBuild"), "PR or merged"),
            (lambda d: d["runs"]["200"]["data"][0]["attributes"].update(destinationCommit={"commitSha": self.base}), "PR or merged"),
            (lambda d: d["runs"]["200"]["data"][0]["attributes"].update(sourceCommit=None), "source commit"),
            (lambda d: d["runs"]["200"]["data"][0]["attributes"].update(completionStatus="FAILED"), "successful"),
            (lambda d: d["runs"]["200"]["data"][0]["relationships"]["product"]["data"].update(id="401"), "product mismatch"),
            (lambda d: d["product"]["data"]["relationships"]["app"]["data"].update(id="101"), "wrong app"),
            (lambda d: d["reference"]["included"][0]["attributes"].update(httpCloneUrl="https://github.com/other/ios"), "repository mismatch"),
        ]
        for mutate, message in mutations:
            with self.subTest(message=message):
                self.api.data = copy.deepcopy(original)
                mutate(self.api.data)
                with self.assertRaisesRegex(notes.NotesError, message):
                    self.generate()

    def test_exact_build_app_platform_and_included_metadata_are_required(self):
        original = copy.deepcopy(self.api.data)
        mutations = [
            (lambda b: b["data"].update(id="201"), "wrong resource"),
            (lambda b: b["included"][0]["attributes"].update(bundleId="other.app"), "wrong app"),
            (lambda b: b["included"][1]["attributes"].update(platform="VISION_OS"), "platform"),
            (lambda b: b["included"].append(copy.deepcopy(b["included"][0])), "ambiguous included"),
            (lambda b: b["data"]["relationships"].pop("app"), "relationship"),
            (lambda b: b["included"][1]["attributes"].pop("version"), "numeric Apple"),
        ]
        for mutate, message in mutations:
            with self.subTest(message=message):
                self.api.data = copy.deepcopy(original)
                mutate(self.api.data["builds"]["200"])
                with self.assertRaisesRegex(notes.NotesError, message):
                    self.generate()

    def test_pagination_is_complete_and_ambiguity_on_later_page_blocks(self):
        page = self.api.data["runs"]["200"]
        run = page["data"].pop()
        url = "https://api.appstoreconnect.apple.com/v1/ciProducts/400/buildRuns?cursor=2"
        page["links"]["next"] = url
        self.api.pages[url] = {"data": [run], "links": {"self": url}}
        self.assertIn("Keep drafts", self.generate()["plain_text"])
        page["data"] = [dict(run, id="501")]
        with self.assertRaisesRegex(notes.NotesError, "ambiguous"):
            self.generate()

    def test_pagination_rejects_unsafe_missing_repeated_and_changed_pages(self):
        page = self.api.data["runs"]["200"]
        for url in ("https://attacker.invalid/v1/ciProducts/400/buildRuns?cursor=2",
                    "https://api.appstoreconnect.apple.com/v1/builds/200", "file:///tmp/data"):
            with self.subTest(url=url):
                page["links"]["next"] = url
                with self.assertRaisesRegex(notes.NotesError, "pagination link"):
                    self.generate()
        page["links"] = {}
        with self.assertRaisesRegex(notes.NotesError, "pagination metadata"):
            self.generate()
        url = "https://api.appstoreconnect.apple.com/v1/ciProducts/400/buildRuns?cursor=2"
        page["links"] = {"self": url, "next": url}
        self.api.pages[url] = copy.deepcopy(page)
        with self.assertRaisesRegex(notes.NotesError, "repeated"):
            self.generate()
        self.api.pages[url]["links"]["next"] = None
        self.api.pages[url]["data"][0]["attributes"]["sourceCommit"]["commitSha"] = self.base
        with self.assertRaisesRegex(notes.NotesError, "changed across pages"):
            self.generate()

    def test_missing_wrong_type_unavailable_and_nonancestor_git_revisions(self):
        self.git("checkout", "--orphan", "unrelated")
        unrelated = self.commit("Other root", "Else.swift", "other")
        blob = self.git("rev-parse", f"{self.base}:App.swift")
        for sha, message in (("f" * 40, "Git verification failed"), (blob, "available commit"),
                             (unrelated, "Git verification failed"), (self.base, "Git verification failed")):
            with self.subTest(sha=sha):
                self.set_sha("200", sha)
                if sha == self.base:
                    self.set_sha("199", self.candidate)
                with self.assertRaisesRegex(notes.NotesError, message):
                    self.generate()

    def test_checkout_origin_shallow_partial_and_replaced_history_are_rejected(self):
        self.git("remote", "set-url", "origin", "https://github.com/other/ios")
        with self.assertRaisesRegex(notes.NotesError, "origin"):
            self.generate()
        self.git("remote", "set-url", "origin", "https://github.com/intent-hq/ios")
        self.git("config", "remote.origin.promisor", "true")
        with self.assertRaisesRegex(notes.NotesError, "Partial"):
            self.generate()
        self.git("config", "--unset", "remote.origin.promisor")
        self.git("replace", self.candidate, self.base)
        with self.assertRaisesRegex(notes.NotesError, "replacement"):
            self.generate()
        self.git("replace", "-d", self.candidate)
        (self.repo / ".git/shallow").write_text(self.base + "\n")
        with self.assertRaisesRegex(notes.NotesError, "non-shallow"):
            self.generate()

    def test_unavailable_tree_object_is_not_silently_skipped(self):
        tree = self.git("rev-parse", f"{self.candidate}^{{tree}}")
        obj = self.repo / ".git/objects" / tree[:2] / tree[2:]
        obj.rename(self.root / "saved-tree")
        with self.assertRaisesRegex(notes.NotesError, "unavailable objects|Git verification failed"):
            self.generate()

    def test_commit_text_and_paths_stay_data_not_commands_or_markdown(self):
        subject = 'fix: <script> @team [click](javascript:alert(1)) `x` $(touch OWNED) ::warning:: (#22)'
        end = self.commit(subject, "--odd\nname.swift", "data")
        self.set_sha("200", end)
        result = self.generate()
        self.assertIn("$(touch OWNED)", result["plain_text"])
        self.assertNotIn("<script>", result["markdown_entry"])
        self.assertNotIn("[click](javascript:", result["markdown_entry"])
        self.assertNotIn("@team", result["markdown_entry"])
        self.assertFalse((self.repo / "OWNED").exists())
        self.assertFalse((self.root / "OWNED").exists())

    def test_control_characters_and_subject_overflow_fail_closed(self):
        for index, subject in enumerate(("fix: hidden\x1b[31m command", "fix: " + "z" * 281)):
            with self.subTest(index=index):
                end = self.commit(subject, "Unsafe.swift", str(index))
                self.set_sha("199", self.git("rev-parse", f"{end}^"))
                self.set_sha("200", end)
                with self.assertRaisesRegex(notes.NotesError, "Control characters|oversized text"):
                    self.generate()

    def test_plain_text_overflow_is_not_silently_truncated(self):
        for index in range(15):
            end = self.commit(f"fix: {index} " + "z" * 250, "Many.swift", str(index))
        self.set_sha("200", end)
        with self.assertRaisesRegex(notes.NotesError, "3500 characters"):
            self.generate()

    def test_unsafe_identifiers_and_repository_urls_never_reach_reader(self):
        for field, value in (("repository", "https://token@github.com/intent-hq/ios"),
                             ("repository", "https://github.com/intent-hq/ios?secret=x"),
                             ("repository", "ext::anything"), ("app_id", "../100"), ("locale", "fr-FR")):
            with self.subTest(field=field):
                original = self.request[field]
                self.request[field] = value
                self.api.calls.clear()
                with self.assertRaises(notes.NotesError):
                    self.generate()
                self.assertEqual(self.api.calls, [])
                self.request[field] = original

    def test_cli_emits_json_only_without_changing_repo_and_sanitizes_read_failures(self):
        self.generate()
        input_file, responses = self.root / "request.json", self.root / "responses.json"
        input_file.write_text(json.dumps(self.request))
        responses.write_text(json.dumps(self.api.snapshots))
        before = self.git("status", "--porcelain")
        for snapshots, expected in ((self.api.snapshots, 0), ({}, 1), ({"not": "a response"}, 1)):
            responses.write_text(json.dumps(snapshots))
            output = io.StringIO()
            with redirect_stdout(output):
                status = notes.main(["--repo", str(self.repo), "--input", str(input_file), "--responses", str(responses)])
            result = json.loads(output.getvalue())
            self.assertEqual(status, expected)
            self.assertEqual(len(output.getvalue().splitlines()), 1)
            self.assertEqual(result["status"], "draft" if expected == 0 else "error")
            if expected == 0:
                self.assertEqual(result["plain_text"], "1.2.1 (41) — changes for review\n\nProduct changes\n- Keep drafts (#17)")
        self.assertEqual(self.git("status", "--porcelain"), before)
        self.assertFalse((self.repo / "CHANGELOG.md").exists())
        self.assertFalse((self.repo / "release-notes").exists())
        with self.assertRaisesRegex(notes.NotesError, "Apple read unavailable") as error:
            notes.generate(self.repo, self.request, lambda *_: (_ for _ in ()).throw(RuntimeError("private-marker")))
        self.assertNotIn("private-marker", str(error.exception))

    def test_cli_refuses_ambiguous_malformed_and_oversized_local_json(self):
        input_file, responses = self.root / "request.json", self.root / "responses.json"
        responses.write_text("{}")
        for raw, message in (("{", "Invalid local input"), ('{"channel":"beta","channel":"app-store"}', "Duplicate JSON"),
                             (" " * (8 * 1024 * 1024 + 1), "safety bound")):
            with self.subTest(message=message):
                input_file.write_text(raw)
                output = io.StringIO()
                with redirect_stdout(output):
                    status = notes.main(["--repo", str(self.repo), "--input", str(input_file), "--responses", str(responses)])
                self.assertEqual(status, 1)
                self.assertIn(message, json.loads(output.getvalue())["action"])


if __name__ == "__main__":
    unittest.main()
