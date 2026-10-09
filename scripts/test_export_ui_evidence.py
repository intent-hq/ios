#!/usr/bin/env python3
"""Exercise evidence export with xcresulttool manifests and tiny PNGs on Linux."""

import io
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib

import export_ui_evidence as evidence


TREE_TEST = "WorkspaceChangesUITests/testNestedFoldersPreserveCollapseUntilRepositoryChanges()"
GROUP_TEST = "WorkspaceAgentGroupsUITests/testLoadingFailureCanRetryOnlyTheExpandedSection()"
RECOVERY_TEST = "ConversationTranscriptScrollUITests/testControlledRecovery()"
UUID = "01234567-89AB-CDEF-0123-456789ABCDEF"
REVISION = "a" * 40
MERMAID_SUITE = "ConversationMermaidUITests"
MERMAID_TEST = "testFullscreenButtonEdgeAndInlinePinchAndPan"
MERMAID_IDENTIFIER = f"{MERMAID_SUITE}/{MERMAID_TEST}()"
ROOT = Path(__file__).resolve().parent.parent


def png(red):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes([0, red, 0, 0]))) + chunk(b"IEND", b""))


def attachment(name="nested-file-tree", filename="image.png", extension="png"):
    return {"exportedFileName": filename,
            "suggestedHumanReadableName": f"{name}_0_{UUID}.{extension}"}


def record(test=TREE_TEST, attachments=None):
    return {"testIdentifier": test, "attachments": attachments if attachments is not None else [attachment()]}


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / "output"
        self.env = {"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2",
                    "GITHUB_OUTPUT": str(self.root / "github-output")}
        self.fixtures = {}
        self.calls = []
        self.exports = []
        self.addCleanup(patch.stopall)
        self.stdout = patch("sys.stdout", new_callable=io.StringIO).start()

    def bundle(self, name="UITestResults", records=None, files=None, status=0):
        path = self.root / name
        path.mkdir(parents=True)
        self.fixtures[path] = (records if records is not None else [record()],
                               files if files is not None else {"image.png": png(255)}, status)
        return path

    def run_xcrun(self, args, check):
        self.assertFalse(check)
        self.assertEqual(args[:5], ["xcrun", "xcresulttool", "export", "attachments", "--path"])
        link = Path(args[5])
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.suffix, ".xcresult")
        source = link.resolve()
        self.calls.append(source)
        document, files, status = self.fixtures[source]
        exported = Path(args[7])
        exported.mkdir()
        self.exports.append(exported)
        if document != "absent":
            (exported / "manifest.json").write_text(json.dumps(document))
        for name, data in files.items():
            destination = exported / name
            if isinstance(data, Path):
                destination.symlink_to(data)
            else:
                destination.write_bytes(data)
        return subprocess.CompletedProcess(args, status)

    def export(self, *bundles):
        return evidence.export_evidence(bundles, self.output, REVISION, self.env, self.run_xcrun)

    def manifest(self, kind="review"):
        return json.loads((self.output / kind / "manifest.json").read_text())

    def mermaid_producer(self):
        source = (ROOT / "IntentUITests" / f"{MERMAID_SUITE}.swift").read_text()
        self.assertEqual(re.findall(r"\bclass (\w+): XCTestCase", source), [MERMAID_SUITE])
        methods = dict(re.findall(
            r"^    (?:private )?func (\w+)(\([^\n]*\n.*?^    })", source, re.MULTILINE | re.DOTALL
        ))
        self.assertIn(MERMAID_TEST, methods, "Locate the owning test for the Mermaid gesture captures")
        launch = methods[MERMAID_TEST].split("app.launch()")
        self.assertEqual(len(launch), 2, "Recheck fixture provenance if its launch flow changes")
        self.assertIn('"--demo-data"', launch[0])
        self.assertIn('"--demo-design-scenario=mermaid"', launch[0])
        reachable = set()
        pending = [MERMAID_TEST]
        while pending:
            method = pending.pop()
            if method in reachable:
                continue
            reachable.add(method)
            pending.extend(name for name in methods
                           if re.search(rf"\b{re.escape(name)}\(", methods[method]))
        self.assertEqual({name for name in reachable if name.startswith("test")}, {MERMAID_TEST})
        source = "\n".join(methods[name] for name in sorted(reachable))
        captures = re.findall(r'capture\(app, name: "([^"\\]+)"\)', source)
        self.assertTrue(captures)
        self.assertEqual(len(captures), len(re.findall(r"\bcapture\(app,", source)),
                         "Extend the producer reader for nonliteral capture names")
        return captures

    def test_mermaid_history_captures_are_scoped_to_their_owning_tests(self):
        registrations = {
            "testDiagramHistoryReopensAndGoToEndShowsLastAnswer": (
                "mermaid-history-visit-1", "mermaid-history-visit-2", "mermaid-history-visit-3",
            ),
            "testDiagramHistoryRemainsUsableWhenItGrowsPastEagerLimit": ("mermaid-history-grown",),
        }
        for test, captures in registrations.items():
            for capture in captures:
                self.assertEqual(evidence.permitted_attachment(MERMAID_SUITE, test, attachment(capture)),
                                 ("review", capture, "png"))
                self.assertIsNone(evidence.permitted_attachment(MERMAID_SUITE, MERMAID_TEST, attachment(capture)))

    def test_mermaid_producer_captures_survive_export_and_retry(self):
        captures = self.mermaid_producer()
        records = [record(test=MERMAID_IDENTIFIER, attachments=[attachment(name) for name in captures])]
        source = self.bundle(records=records)
        retry = self.bundle("UITestResults-retry", records=records, files={"image.png": png(0)})
        self.export(source)
        for bundle, is_retry in [(source, False), (retry, True)]:
            entries = [entry for entry in self.manifest()["files"] if entry["sourceBundle"] == str(bundle)]
            self.assertEqual({entry["capture"] for entry in entries}, set(captures),
                             "A fixture producer capture was omitted by the exporter")
            self.assertTrue(all(entry["testIdentifier"] == MERMAID_IDENTIFIER for entry in entries))
            self.assertTrue(all(entry["retry"] == is_retry for entry in entries))
        self.assertEqual(self.manifest()["missingCaptures"], [])

    def test_producer_contract_detects_removed_registration(self):
        captures = evidence.CAPTURES[MERMAID_SUITE][MERMAID_TEST]
        with patch.dict(evidence.CAPTURES, {MERMAID_SUITE: {
            MERMAID_TEST: tuple(name for name in captures if name != "mermaid-fullscreen-from-button-edge"),
        }}):
            with self.assertRaisesRegex(AssertionError, "mermaid-fullscreen-from-button-edge"):
                self.test_mermaid_producer_captures_survive_export_and_retry()

    def test_failed_mermaid_job_replay_retains_only_named_fixture_screenshots(self):
        fixture = json.loads((ROOT / "scripts/fixtures/ui-evidence/mermaid-fullscreen-failure.json").read_text())
        records = fixture["records"]
        self.assertEqual(len(records[0]["attachments"]), 31)
        files = {item["exportedFileName"]: png(255) if item["exportedFileName"].endswith(".png") else b"diagnostic text"
                 for item in records[0]["attachments"]}
        source = self.bundle(records=records, files=files)
        result = source / "test-result.json"
        result.write_text(json.dumps(fixture["source"]))
        before = result.read_bytes()
        self.assertEqual(self.export(source)["review"], 2)
        entries = self.manifest()["files"]
        self.assertEqual({entry["capture"] for entry in entries}, {
            "mermaid-fullscreen-from-button-edge", "mermaid-inline-before-gestures",
        })
        self.assertTrue(all(entry["testIdentifier"] == MERMAID_IDENTIFIER for entry in entries))
        self.assertTrue(all(not entry["retry"] for entry in entries))
        for entry in entries:
            self.assertEqual((self.output / "review" / entry["file"]).read_bytes(), files[entry["exportedFileName"]])
        self.assertEqual(self.manifest()["missingCaptures"][0]["captures"], sorted({
            "mermaid-final-state", "mermaid-inline-after-pinch",
            "mermaid-inline-after-horizontal-pan", "mermaid-inline-after-vertical-pan",
        }))
        self.assertIn("Captures may not have been reached before a test failure", self.stdout.getvalue())
        self.assertEqual(result.read_bytes(), before)

    def test_missing_captures_remain_visible_when_a_retry_has_the_screenshots(self):
        source = self.bundle(records=[record(test=MERMAID_IDENTIFIER, attachments=[])], files={})
        self.bundle("UITestResults-retry", records=[record(test=MERMAID_IDENTIFIER,
                    attachments=[attachment(name) for name in self.mermaid_producer()])])
        self.export(source)
        missing = self.manifest()["missingCaptures"]
        self.assertEqual(len(missing), 1)
        self.assertEqual(missing[0]["sourceBundle"], str(source))
        self.assertEqual(missing[0]["testIdentifier"], MERMAID_IDENTIFIER)
        self.assertFalse(missing[0]["retry"])
        self.assertTrue(all(entry["retry"] for entry in self.manifest()["files"]))

    def test_missing_only_artifact_is_uploadable_and_cli_does_not_fail(self):
        source = self.bundle(records=[record(test=MERMAID_IDENTIFIER, attachments=[])], files={})
        args = ["export_ui_evidence.py", "--output-root", str(self.output), "--bundles", str(source)]
        export = evidence.export_evidence
        with patch.object(sys, "argv", args), \
                patch.object(evidence.subprocess, "check_output", return_value=REVISION), \
                patch.object(evidence, "export_evidence", side_effect=lambda bundles, output, revision:
                             export(bundles, output, revision, self.env, self.run_xcrun)):
            self.assertIsNone(evidence.main())
        self.assertEqual(self.manifest()["files"], [])
        self.assertEqual(len(self.manifest()["missingCaptures"]), 1)
        self.assertIn("review_count=0\nreview_available=true", (self.root / "github-output").read_text())
        self.assertIn("::warning::Missing fixture captures", self.stdout.getvalue())

    def test_repeated_records_are_combined_only_within_their_bundle(self):
        records = [record(test=MERMAID_IDENTIFIER, attachments=[attachment(name)]) for name in self.mermaid_producer()]
        source = self.bundle(records=records)
        retry = self.bundle("UITestResults-retry", records=[record(test=MERMAID_IDENTIFIER, attachments=[])])
        self.export(source)
        missing = self.manifest()["missingCaptures"]
        self.assertEqual(len(missing), 1)
        self.assertEqual(missing[0]["sourceBundle"], str(retry))
        self.assertTrue(missing[0]["retry"])

    def test_mermaid_names_cannot_bypass_fixture_path_or_content_boundaries(self):
        capture = "mermaid-fullscreen-from-button-edge"
        secret = self.root / "secret.png"
        secret.write_bytes(png(0))
        source = self.bundle(records=[
            record(test=MERMAID_IDENTIFIER, attachments=[
                attachment(capture, "../secret.png"), attachment(capture, str(secret)),
                attachment(capture, "linked.png"), attachment(capture, "absent.png"),
                attachment(capture, "invalid.png"), attachment(capture + "-hierarchy", "hierarchy.txt", "txt"),
                attachment("Automatic screenshot"), attachment(capture + "-unregistered"),
            ]),
            record(test="RealAccountTests/testOpen()", attachments=[attachment(capture)]),
            record(test=f"{MERMAID_SUITE}/testUnregistered()", attachments=[attachment(capture)]),
            record(test="IntentTests/" + MERMAID_IDENTIFIER, attachments=[attachment(capture)]),
        ], files={"image.png": png(255), "linked.png": secret, "invalid.png": b"not PNG", "hierarchy.txt": b"private text"})
        self.assertEqual(self.export(source)["review"], 0)
        self.assertEqual(self.manifest()["files"], [])
        self.assertIn(capture, self.manifest()["missingCaptures"][0]["captures"])
        self.assertEqual(list((self.output / "review").rglob("*.png")), [])

    def test_malformed_attachment_lists_do_not_hide_later_evidence(self):
        source = self.bundle(records=[{"testIdentifier": MERMAID_IDENTIFIER, "attachments": None}, record()])
        self.assertEqual(self.export(source)["review"], 1)
        self.assertEqual(self.manifest()["missingCaptures"][0]["testIdentifier"], MERMAID_IDENTIFIER)

    def test_only_named_captures_from_their_fixture_tests_are_retained(self):
        captures = [attachment(), attachment("Automatic screenshot"),
                    attachment("nested-file-tree-private-account"),
                    attachment("nested-file-tree/../../secret"),
                    attachment("commit-diff")]
        source = self.bundle(records=[record(attachments=captures),
                                      record(test="RealAccountTests/testOpen()"),
                                      record(test="IntentTests/" + TREE_TEST),
                                      record(test="WorkspaceChangesUITests/testUnreviewedCapture()")])
        self.assertEqual(self.export(source), {"review": 1, "agent-groups": 0, "recovery": 0})
        self.assertEqual(self.manifest()["files"][0]["capture"], "nested-file-tree")

    def test_video_smoke_retains_only_its_named_poster_and_player_captures(self):
        video_test = "TranscriptVideoUITests/testSentVideoPosterOpensFullScreenPlayback()"
        source = self.bundle(records=[
            record(test=video_test, attachments=[
                attachment("Sent video poster"), attachment("Sent video full-screen playback"),
                attachment("Automatic screenshot"), attachment("Sent video poster-private-account"),
            ]),
            record(test="RealAccountTests/testOpen()", attachments=[attachment("Sent video poster")]),
        ])
        self.assertEqual(self.export(source), {"review": 2, "agent-groups": 0, "recovery": 0})
        self.assertEqual({entry["capture"] for entry in self.manifest()["files"]},
                         {"Sent video poster", "Sent video full-screen playback"})

    def test_existing_group_images_and_recovery_json_remain_separate(self):
        recovery = {"test": "testControlledRecovery", "cycle": 1, "goToEndPresent": False,
                    "endRowPosition": "INSIDE", "endRecovery": {"reason": "recovered", "corrections": 1}}
        recover_attachment = attachment("transcript-recovery-evidence-testControlledRecovery-1",
                                        "recovery.json", "json")
        source = self.bundle(records=[
            record(test=GROUP_TEST, attachments=[attachment("agent-group-evidence-Background group loading.png")]),
            record(test=RECOVERY_TEST, attachments=[recover_attachment]),
            record(test=RECOVERY_TEST.replace("ScrollUITests", "FullGateUITests"), attachments=[recover_attachment]),
            record(test=RECOVERY_TEST, attachments=[attachment("transcript-recovery-evidence-unrelated-1", "private.json", "json")]),
            record(test="AccountTests/testControlledRecovery()", attachments=[recover_attachment]),
        ], files={"image.png": png(0), "recovery.json": json.dumps(recovery).encode(), "private.json": b'{"message":"private"}'})
        self.assertEqual(self.export(source), {"review": 0, "agent-groups": 1, "recovery": 2})
        self.assertFalse((self.output / "review").exists())
        for entry in self.manifest("recovery")["files"]:
            self.assertEqual(json.loads((self.output / "recovery" / entry["file"]).read_text()), recovery)
        self.assertIn("Background_group_loading", self.manifest("agent-groups")["files"][0]["file"])

    def test_native_suffix_and_exported_filename_fallback(self):
        source = self.bundle(records=[record(attachments=[
            attachment(), {"exportedFileName": "nested-file-tree.png"},
            attachment("nested-file-tree.png"),
        ])], files={"image.png": png(255), "nested-file-tree.png": png(0)})
        self.assertEqual(self.export(source)["review"], 3)

    def test_readable_names_are_safe_and_repeated_captures_do_not_collide(self):
        source = self.bundle("odd parent/..unsafe bundle ; $()", records=[record(), record()])
        self.assertEqual(self.export(source)["review"], 2)
        paths = [entry["file"] for entry in self.manifest()["files"]]
        self.assertEqual(len(set(paths)), 2)
        for path in paths:
            self.assertIn("nested-file-tree", path)
            self.assertRegex(path, r"^[A-Za-z0-9_./-]+$")
            self.assertNotIn("..", Path(path).parts)
            self.assertTrue((self.output / "review" / path).is_file())

    def test_retries_and_same_basename_bundles_preserve_bytes_and_origin(self):
        source = self.bundle("one/UITestResults.xcresult")
        retry = self.bundle("one/UITestResults-retry.xcresult", files={"image.png": png(0)})
        other = self.bundle("two/UITestResults.xcresult")
        self.assertEqual(self.export(source, other, source)["review"], 3)
        entries = self.manifest()["files"]
        self.assertEqual([entry["sourceBundle"] for entry in entries], [str(source), str(retry), str(other)])
        self.assertEqual([entry["retry"] for entry in entries], [False, True, False])
        self.assertEqual(len({entry["file"] for entry in entries}), 3)
        for entry, expected in zip(entries, [png(255), png(0), png(255)]):
            self.assertEqual((self.output / "review" / entry["file"]).read_bytes(), expected)
        self.assertEqual(len(self.calls), 3)

    def test_extensionless_retry_bundle_is_included(self):
        source = self.bundle()
        self.bundle("UITestResults-retry")
        self.assertEqual(self.export(source)["review"], 2)
        self.assertTrue(self.manifest()["files"][1]["retry"])

    def test_absent_bundles_do_not_invoke_xcode_or_create_empty_artifacts(self):
        self.assertEqual(self.export(self.root / "missing"), {"review": 0, "agent-groups": 0, "recovery": 0})
        self.assertEqual(self.calls, [])
        self.assertEqual(list(self.output.iterdir()), [])
        self.assertEqual((self.root / "github-output").read_text(),
                         "review_count=0\nreview_available=false\nagent-groups_count=0\nagent-groups_available=false\n"
                         "recovery_count=0\nrecovery_available=false\n")

    def test_export_failure_does_not_block_later_retry_evidence(self):
        source = self.bundle(status=1)
        self.bundle("UITestResults-retry")
        self.assertEqual(self.export(source)["review"], 1)
        self.assertTrue(self.manifest()["files"][0]["retry"])
        self.assertTrue(all(not directory.exists() for directory in self.exports))

    def test_missing_and_malformed_manifests_are_best_effort(self):
        missing = self.bundle("missing-manifest", records="absent")
        malformed = self.bundle("malformed-manifest", records={"unexpected": []})
        valid = self.bundle("valid")
        self.assertEqual(self.export(missing, malformed, valid)["review"], 1)

    def test_paths_cannot_escape_export_and_symlinks_are_rejected(self):
        secret = self.root / "secret.png"
        secret.write_bytes(png(0))
        source = self.bundle(records=[record(attachments=[attachment(filename=path) for path in
                             ["../secret.png", str(secret), "linked.png", "absent.png", "image.png"]])],
                             files={"image.png": png(255), "linked.png": secret})
        self.assertEqual(self.export(source)["review"], 1)
        entry = self.manifest()["files"][0]
        self.assertEqual(entry["exportedFileName"], "image.png")
        self.assertEqual((self.output / "review" / entry["file"]).read_bytes(), png(255))

    def test_wrong_content_types_are_not_uploaded(self):
        source = self.bundle(records=[record(), record(test=RECOVERY_TEST, attachments=[
            attachment("transcript-recovery-evidence-testControlledRecovery-1", "invalid.json", "json"),
            attachment("transcript-recovery-evidence-testControlledRecovery-2", "list.json", "json"),
        ])], files={"image.png": b"private text", "invalid.json": b"not JSON", "list.json": b"[]"})
        self.assertEqual(self.export(source), {"review": 0, "agent-groups": 0, "recovery": 0})

    def test_manifest_covers_exactly_the_retained_files_and_revision(self):
        source = self.bundle(records=[record(test="IntentUITests/" + TREE_TEST), record(test=GROUP_TEST, attachments=[
            attachment("agent-group-evidence-Background group loading.png"),
        ])], files={"image.png": png(255), "unrelated.png": png(0), "private.txt": b"do not retain"})
        counts = self.export(source)
        for kind in ["review", "agent-groups"]:
            manifest = self.manifest(kind)
            self.assertEqual(manifest["revision"], REVISION)
            self.assertEqual(manifest["runId"], "123")
            self.assertEqual(manifest["runAttempt"], "2")
            self.assertEqual(counts[kind], len(manifest["files"]))
            actual = {path.relative_to(self.output / kind).as_posix()
                      for path in (self.output / kind).rglob("*") if path.is_file()}
            self.assertEqual(actual, {"manifest.json"} | {entry["file"] for entry in manifest["files"]})
            for entry in manifest["files"]:
                self.assertEqual(entry["sourceBundle"], str(source))
                self.assertIn(entry["suite"] + "/", entry["testIdentifier"])
        self.assertTrue(all(not directory.exists() for directory in self.exports))

    def test_reusing_output_is_refused_to_prevent_stale_uploads(self):
        source = self.bundle()
        self.export(source)
        before = self.manifest()
        with self.assertRaises(FileExistsError):
            self.export(source)
        self.assertEqual(self.manifest(), before)

    def test_cli_records_checkout_revision_instead_of_event_sha(self):
        args = ["export_ui_evidence.py", "--output-root", str(self.output), "--bundles", "UITestResults\nIPadMenuTestResults\n"]
        with patch.object(sys, "argv", args), patch.dict(os.environ, {"GITHUB_SHA": "b" * 40}), \
                patch.object(evidence.subprocess, "check_output", return_value=REVISION + "\n") as revision, \
                patch.object(evidence, "export_evidence") as export:
            evidence.main()
        revision.assert_called_once_with(["git", "rev-parse", "HEAD"], text=True)
        export.assert_called_once_with([Path("UITestResults"), Path("IPadMenuTestResults")], self.output, REVISION)


if __name__ == "__main__":
    unittest.main()
