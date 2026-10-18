#!/usr/bin/env python3
"""Exercise workspace-entry appearance selection offline with a stubbed gh."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SELECTOR = (
    Path(__file__).resolve().parents[1]
    / ".github/scripts/select-workspace-entry-appearances.sh"
)
TOKEN = "fixture-token-must-not-appear-in-output"
HEAD_SHA = "a" * 40
BASE_SHA = "b" * 40
ALLOWED = [
    "README.md",
    "AGENTS.md",
    "LICENSE",
    "IntentTests/WorkspaceListViewModelTests.swift",
    "IntentTests/TestBundleInputs.swift",
    "Intent/Views/Conversation/Content/PDFLightboxView.swift",
    "Intent/Views/Conversation/Content/PDFLinkPreviewView.swift",
    "Intent/Views/Conversation/Content/IntentFilePDFAttachment.swift",
    "Intent/Views/Conversation/Notices/WatcherMessageBodyView.swift",
    "Intent/Presentation/WatcherMessagePresentation.swift",
    "Intent/Services/MobileTerminalStore.swift",
    "Intent/Services/MobileTerminalConnection.swift",
]
DENIED = [
    "unknown.txt",
    "docs/README.md",
    "README.md.bak",
    "readme.md",
    "IntentTests/Fixtures/snapshot.json",
    "IntentTests/Helpers/Fixture.swift",
    "IntentTests/NewTests.swift.bak",
    "IntentUITests/WorkspaceListMenuUITests.swift",
    "IntentUITests/FixtureCapture.swift",
    "IntentUITests/Helpers/WorkspaceList.swift",
    "Intent/Views/Conversation/Content/UnknownPDFView.swift",
    "Intent/Views/Conversation/Content/PDFLightboxView+Layout.swift",
    "Intent/Views/Conversation/Content/PDFLightboxView.swift.bak",
    "Intent/Views/Conversation/Content/Nested/PDFLightboxView.swift",
    "Intent/Views/Conversation/Notices/WatcherView.swift",
    "Intent/Presentation/WatcherMessagePresentation+Theme.swift",
    "Intent/Services/MobileTerminalConnection+Session.swift",
    "Intent/Services/WebSocketConnection.swift",
    "Intent/Services/WebSocketConnectionSecurity.swift",
    "Intent/Services/WorkspaceChangesStore.swift",
    "Intent/Views/WorkspaceListView.swift",
    "Intent/Views/WorkspaceView.swift",
    "Intent/ViewModels/WorkspaceListViewModel.swift",
    "Intent/App/IntentApp.swift",
    "Intent/DesignSystem/Colors.swift",
    "Intent/Assets.xcassets/AccentColor.colorset/Contents.json",
    "Intent/Resources/Mermaid/mermaid.bundle.js",
    "Intent/Models.swift",
    "Intent/Models/Workspace.swift",
    "Intent/Utils/Navigation.swift",
    "Intent/PersistenceManager.swift",
    "Intent.xcodeproj/project.pbxproj",
    "Intent.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "Info.plist",
    "Info-visionOS.plist",
    "TailcatKit/go.mod",
    "ci_scripts/ci_post_clone.sh",
    "scripts/xcodebuild.sh",
    "scripts/ui-smoke-tests.txt",
    "scripts/test_select_workspace_entry_appearances.py",
    ".github/workflows/ci.yml",
    ".github/actions/export-ui-evidence/action.yml",
    ".github/scripts/select-workspace-entry-appearances.sh",
    ".github/scripts/select-fixture-capture-repetitions.sh",
    ".swiftlint.yml",
]


def changed_file(filename, status="modified", **extra):
    return {"filename": filename, "status": status, **extra}


def unit_files(count, start=0):
    return [changed_file(f"IntentTests/File{index}.swift")
            for index in range(start, start + count)]


def paginated(files):
    return [files[index:index + 100] for index in range(0, len(files), 100)]


class WorkspaceEntryAppearanceSelectionTests(unittest.TestCase):
    def select(self, pages=None, *, event="pull_request", pr_number="852",
               repository="intent-hq/ios", token=TOKEN, gh_status=0, raw=None,
               stderr="", missing=(), head_sha=HEAD_SHA, base_sha=BASE_SHA,
               metadata_raw=None, after_metadata_raw=None, metadata_status=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / "response.json"
            if pages is None:
                pages = [[changed_file("README.md")]]
            fixture.write_text(json.dumps(pages) if raw is None else raw)
            metadata = json.dumps({"head": {"sha": HEAD_SHA}, "base": {"sha": BASE_SHA},
                                   "changed_files": sum(len(page) for page in pages if isinstance(page, list))})
            before = root / "metadata-before.json"
            after = root / "metadata-after.json"
            before.write_text(metadata if metadata_raw is None else metadata_raw)
            after.write_text(before.read_text() if after_metadata_raw is None else after_metadata_raw)
            stub = root / "gh"
            stub.write_text(
                '#!/bin/bash\nset -eu\n'
                'printf "%s\\n" "$@" >> "$TEST_ARGUMENTS"\n'
                'if [[ "$*" != *"/files?per_page=100" ]]; then\n'
                '  if [[ -f "$TEST_METADATA_SEEN" ]]; then cat "$TEST_METADATA_AFTER";\n'
                '  else cat "$TEST_METADATA_BEFORE"; touch "$TEST_METADATA_SEEN"; fi\n'
                '  exit "$TEST_METADATA_STATUS"\n'
                'fi\n'
                'cat "$TEST_RESPONSE"\n'
                'printf "%s" "$TEST_STDERR" >&2\n'
                'if [ "$TEST_GH_STATUS" != 0 ]; then\n'
                '  printf "%s\\n" "${GH_TOKEN:-}" >&2\n'
                'fi\n'
                'exit "$TEST_GH_STATUS"\n'
            )
            stub.chmod(0o755)
            output = root / "output"
            existing = "existing-output=preserved\nrepetitions=2\n"
            output.write_text(existing)
            arguments = root / "arguments"
            env = os.environ.copy()
            env.update(
                PATH=f"{root}:{env['PATH']}",
                GITHUB_EVENT_NAME=event,
                PR_NUMBER=pr_number,
                PR_HEAD_SHA=head_sha,
                PR_BASE_SHA=base_sha,
                GITHUB_REPOSITORY=repository,
                GH_TOKEN=token,
                GITHUB_OUTPUT=str(output),
                TEST_RESPONSE=str(fixture),
                TEST_METADATA_BEFORE=str(before),
                TEST_METADATA_AFTER=str(after),
                TEST_METADATA_SEEN=str(root / "metadata-seen"),
                TEST_METADATA_STATUS=str(metadata_status),
                TEST_ARGUMENTS=str(arguments),
                TEST_GH_STATUS=str(gh_status),
                TEST_STDERR=stderr,
            )
            for name in missing:
                env.pop(name, None)
            process = subprocess.run(
                ["bash", str(SELECTOR)], env=env, check=True,
                capture_output=True, text=True,
            )
            contents = output.read_text()
            self.assertNotIn(TOKEN, process.stdout + process.stderr + contents)
            self.assertTrue(contents.startswith(existing))
            appended = contents[len(existing):]
            self.assertIn(appended, ("appearances=light\n", "appearances=both\n"))
            args = arguments.read_text().splitlines() if arguments.exists() else []
            self.assertNotIn(TOKEN, "\n".join(args))
            return appended.strip(), args

    def test_ordinary_pr_requests_all_pages_and_appends_light(self):
        output, arguments = self.select()
        self.assertEqual(output, "appearances=light")
        self.assertEqual(arguments, [
            "api", "repos/intent-hq/ios/pulls/852",
            "api", "--paginate", "--slurp",
            "repos/intent-hq/ios/pulls/852/files?per_page=100",
            "api", "repos/intent-hq/ios/pulls/852",
        ])

    def test_every_allowlisted_path_and_their_mixture_select_light(self):
        for paths in [[path] for path in ALLOWED] + [ALLOWED]:
            with self.subTest(paths=paths):
                output, _ = self.select([[changed_file(path) for path in paths]])
                self.assertEqual(output, "appearances=light")

    def test_unknown_and_shared_paths_keep_both_alone_and_in_mixtures(self):
        for path in DENIED:
            for files in [[changed_file(path)],
                          [changed_file("README.md"), changed_file(path)],
                          [changed_file(path), changed_file("README.md")]]:
                with self.subTest(files=files):
                    output, _ = self.select([files])
                    self.assertEqual(output, "appearances=both")

    def test_non_pr_events_keep_both_without_api_access(self):
        events = [
            "branch_protection_rule", "check_run", "check_suite", "create",
            "delete", "deployment", "deployment_status", "discussion",
            "discussion_comment", "fork", "gollum", "issue_comment", "issues",
            "label", "merge_group", "milestone", "page_build", "public",
            "pull_request_review", "pull_request_review_comment",
            "pull_request_target", "push", "registry_package", "release",
            "repository_dispatch", "schedule", "status", "watch",
            "workflow_call", "workflow_dispatch", "workflow_run",
            "pull_request\n", "PULL_REQUEST", "", "unknown",
        ]
        for event in events:
            with self.subTest(event=event):
                output, arguments = self.select(event=event)
                self.assertEqual(output, "appearances=both")
                self.assertEqual(arguments, [])

    def test_every_nonmodified_status_keeps_both_even_on_allowed_paths(self):
        for path in ALLOWED:
            for status in ["added", "removed", "renamed", "copied", "changed",
                           "unchanged", "unknown", "Modified", "", None, 12, [], {}]:
                with self.subTest(path=path, status=status):
                    output, _ = self.select([[changed_file(path, status)]])
                    self.assertEqual(output, "appearances=both")

    def test_renames_and_copies_from_to_or_between_allowed_paths_keep_both(self):
        for path in ALLOWED:
            for old, new in [(path, "Intent/DesignSystem/Colors.swift"),
                             ("Intent/DesignSystem/Colors.swift", path),
                             (path, "IntentTests/RenamedTests.swift")]:
                for status in ["renamed", "copied", "modified"]:
                    with self.subTest(old=old, new=new, status=status):
                        output, _ = self.select([[
                            changed_file(new, status, previous_filename=old),
                        ]])
                        self.assertEqual(output, "appearances=both")

    def test_unexpected_previous_filename_keeps_both(self):
        for previous in [None, 12, "", [], {}, "README.md", "../escape.swift"]:
            with self.subTest(previous=previous):
                output, _ = self.select([[
                    changed_file("README.md", previous_filename=previous),
                ]])
                self.assertEqual(output, "appearances=both")

    def test_missing_inputs_keep_both_without_api_access(self):
        for name in ["GITHUB_EVENT_NAME", "PR_NUMBER", "PR_HEAD_SHA", "PR_BASE_SHA", "GITHUB_REPOSITORY", "GH_TOKEN"]:
            with self.subTest(name=name):
                output, arguments = self.select(missing=[name])
                self.assertEqual(output, "appearances=both")
                self.assertEqual(arguments, [])

    def test_invalid_inputs_keep_both_without_api_access(self):
        cases = [
            {"pr_number": value} for value in
            ["", "0", "-1", "01", "852.0", "1/files", "852\n", " 852", TOKEN]
        ] + [
            {"repository": value} for value in
            ["", "ios", "intent-hq/ios/extra", "/ios", "intent-hq/", "../ios",
             "intent-hq/..", "intent-hq/.", "intent-hq/ios\n", "intent hq/ios",
             "intent-hq/ios?per_page=1", TOKEN]
        ] + [{"token": value} for value in ["", " ", "\n", f"{TOKEN}\n"]] + [
            {name: value} for name in ["head_sha", "base_sha"]
            for value in ["", "a" * 39, "a" * 41, "g" * 40, "a" * 40 + "\n"]
        ]
        for case in cases:
            with self.subTest(case=case):
                output, arguments = self.select(**case)
                self.assertEqual(output, "appearances=both")
                self.assertEqual(arguments, [])

    def test_api_failures_keep_both_even_with_allowed_partial_responses(self):
        for status in [1, 2, 127]:
            with self.subTest(status=status):
                output, arguments = self.select(gh_status=status)
                self.assertEqual(output, "appearances=both")
                self.assertTrue(arguments)

    def test_stale_changing_missing_or_malformed_revision_metadata_keeps_both(self):
        valid = {"head": {"sha": HEAD_SHA}, "base": {"sha": BASE_SHA}, "changed_files": 1}
        invalid = ["", "null", "[]", "{}", "not-json", json.dumps(valid) + json.dumps(valid)]
        for field in ["head", "base"]:
            invalid.append(json.dumps(dict(valid, **{field: {"sha": "c" * 40}})))
        for count in [0, 2, 3000, "1", 1.5, None]:
            invalid.append(json.dumps(dict(valid, changed_files=count)))
        for raw in invalid:
            for stage in ["metadata_raw", "after_metadata_raw"]:
                with self.subTest(raw=raw, stage=stage):
                    output, _ = self.select(**{stage: raw})
                    self.assertEqual(output, "appearances=both")
        output, _ = self.select(metadata_status=1)
        self.assertEqual(output, "appearances=both")

    def test_tokens_in_responses_and_diagnostics_are_never_printed(self):
        for status in [0, 1]:
            for raw in [TOKEN, json.dumps({"message": TOKEN}),
                        json.dumps([[changed_file(TOKEN)]]),
                        json.dumps([[changed_file("README.md", patch=TOKEN)]])]:
                with self.subTest(status=status, raw=raw):
                    self.select(raw=raw, stderr=TOKEN, gh_status=status)
        output, _ = self.select(stderr=TOKEN)
        self.assertEqual(output, "appearances=light")

    def test_malformed_or_empty_responses_keep_both(self):
        valid = json.dumps([[changed_file("README.md")]])
        responses = [
            "", "not-json", "null", "true", "42", "{}", "[]", "[[]]",
            valid[:-1], valid + valid, valid + "\nnull", "null\n" + valid,
            valid + "\n[]", json.dumps([changed_file("README.md")]),
            json.dumps([[changed_file("README.md")], {"message": "API error"}]),
            json.dumps([[changed_file("README.md"), None]]),
            json.dumps([[{"status": "modified"}]]),
            json.dumps([[{"filename": "README.md"}]]),
            json.dumps([[[changed_file("README.md")]]]),
        ]
        for entry in [None, True, 12, "README.md", [], {}]:
            responses.append(json.dumps([[entry]]))
        for filename in [None, 12, [], {}, "", "../README.md", "/README.md",
                         "./README.md", "IntentTests/../README.md",
                         "IntentTests/./File.swift", "IntentTests//File.swift",
                         "IntentTests/Bad\\File.swift", "IntentTests/Bad\nFile.swift",
                         "IntentTests/Bad\tFile.swift", "IntentTests/Bad\x00File.swift",
                         "IntentTests/File.swift/", "README.md\n"]:
            responses.append(json.dumps([[changed_file(filename)]]))
        for raw in responses:
            with self.subTest(raw=raw):
                output, _ = self.select(raw=raw)
                self.assertEqual(output, "appearances=both")

    def test_complete_pagination_selects_light_through_last_safe_size(self):
        for count in [1, 99, 101, 199, 201, 2999]:
            with self.subTest(count=count):
                output, _ = self.select(paginated(unit_files(count)))
                self.assertEqual(output, "appearances=light")

    def test_relevant_file_on_any_page_keeps_both(self):
        for index in [0, 99, 100, 199, 200]:
            with self.subTest(index=index):
                files = unit_files(201)
                files[index] = changed_file("Intent/DesignSystem/Colors.swift")
                output, _ = self.select(paginated(files))
                self.assertEqual(output, "appearances=both")

    def test_nonmodified_file_on_later_page_keeps_both(self):
        for status in ["added", "removed", "renamed", "copied"]:
            with self.subTest(status=status):
                output, _ = self.select([
                    unit_files(100), [changed_file("README.md", status)],
                ])
                self.assertEqual(output, "appearances=both")

    def test_ambiguous_or_malformed_pagination_keeps_both(self):
        cases = [
            [unit_files(100)],
            [unit_files(100), unit_files(100, 100)],
            [unit_files(101)],
            [unit_files(1), unit_files(1, 1)],
            [unit_files(99), unit_files(1, 99)],
            [unit_files(100), unit_files(1, 100), unit_files(1, 101)],
            [[], unit_files(1)],
            [unit_files(1), []],
            [unit_files(100), []],
            [unit_files(100), [], unit_files(1, 100)],
            [unit_files(100), None],
            [unit_files(100), "truncated"],
        ]
        for pages in cases:
            with self.subTest(page_sizes=[len(p) if isinstance(p, list) else p
                                         for p in pages]):
                output, _ = self.select(pages)
                self.assertEqual(output, "appearances=both")

    def test_duplicates_within_or_across_pages_keep_both(self):
        for pages in [[unit_files(1) * 2],
                      [unit_files(100), unit_files(1)],
                      [unit_files(100), unit_files(100), unit_files(1, 100)]]:
            with self.subTest(pages=len(pages)):
                output, _ = self.select(pages)
                self.assertEqual(output, "appearances=both")

    def test_file_limit_or_more_never_reduces_coverage(self):
        for count in [3000, 3001, 3101]:
            with self.subTest(count=count):
                output, _ = self.select(paginated(unit_files(count)))
                self.assertEqual(output, "appearances=both")


if __name__ == "__main__":
    unittest.main()
