#!/usr/bin/env python3
"""Exercise screenshot-contract selection offline, with a stubbed GitHub CLI."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SELECTOR = (
    Path(__file__).resolve().parents[1]
    / ".github/scripts/select-fixture-capture-repetitions.sh"
)
TOKEN = "fixture-token-must-not-appear-in-output"
ORDINARY = "Intent/Views/WorkspaceView.swift"
RELEVANT = [
    ".github/workflows/ci.yml",
    ".github/actions/export-ui-evidence/action.yml",
    ".github/actions/export-ui-evidence/scripts/export.sh",
    ".github/scripts/select-fixture-capture-repetitions.sh",
    "IntentUITests/FixtureCapture.swift",
    "IntentUITests/FixtureCaptureLifecycleUITests.swift",
    "scripts/verify_fixture_capture_lifecycle.py",
    "scripts/test_fixture_capture_lifecycle.py",
    "scripts/test_select_fixture_capture_repetitions.py",
    "scripts/check_ui_attachment_lifecycle.py",
    "scripts/test_check_ui_attachment_lifecycle.py",
    "scripts/export_ui_evidence.py",
    "scripts/test_export_ui_evidence.py",
]


def changed_file(filename, status="modified", **extra):
    return {"filename": filename, "status": status, **extra}


class FixtureCaptureSelectionTests(unittest.TestCase):
    def select(self, pages=None, *, event="pull_request", pr_number="851",
               repository="intent-hq/ios", token=TOKEN, gh_status=0, raw=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / "response.json"
            if pages is None:
                pages = [[changed_file(ORDINARY)]]
            fixture.write_text(json.dumps(pages) if raw is None else raw)
            stub = root / "gh"
            stub.write_text(
                '#!/bin/bash\nset -eu\n'
                'printf "%s\\n" "$@" > "$TEST_ARGUMENTS"\n'
                'cat "$TEST_RESPONSE"\n'
                'if [ "$TEST_GH_STATUS" != 0 ]; then\n'
                '  printf "%s\\n" "$GH_TOKEN" >&2\n'
                '  exit "$TEST_GH_STATUS"\n'
                'fi\n'
            )
            stub.chmod(0o755)
            output = root / "output"
            output.write_text("existing-output=preserved\n")
            arguments = root / "arguments"
            env = os.environ.copy()
            env.update(
                PATH=f"{root}:{env['PATH']}",
                GITHUB_EVENT_NAME=event,
                PR_NUMBER=pr_number,
                GITHUB_REPOSITORY=repository,
                GH_TOKEN=token,
                GITHUB_OUTPUT=str(output),
                TEST_RESPONSE=str(fixture),
                TEST_ARGUMENTS=str(arguments),
                TEST_GH_STATUS=str(gh_status),
            )
            process = subprocess.run(
                ["bash", str(SELECTOR)], env=env, check=True,
                capture_output=True, text=True,
            )
            self.assertNotIn(TOKEN, process.stdout + process.stderr)
            lines = output.read_text().splitlines()
            self.assertEqual(lines[0], "existing-output=preserved")
            self.assertEqual(len(lines), 2)
            return lines[1], arguments.read_text().splitlines() if arguments.exists() else []

    def test_ordinary_pr_uses_one_and_requests_all_pages(self):
        output, arguments = self.select()
        self.assertEqual(output, "repetitions=1")
        self.assertEqual(arguments, [
            "api", "--paginate", "--slurp",
            "repos/intent-hq/ios/pulls/851/files?per_page=100",
        ])

    def test_other_events_keep_two_without_api_access(self):
        for event in ["schedule", "workflow_dispatch", "merge_group", "push",
                      "pull_request_target", "", "unknown"]:
            with self.subTest(event=event):
                output, arguments = self.select(event=event)
                self.assertEqual(output, "repetitions=2")
                self.assertEqual(arguments, [])

    def test_each_capture_tooling_path_keeps_two(self):
        for path in RELEVANT:
            with self.subTest(path=path):
                output, _ = self.select([[changed_file(ORDINARY), changed_file(path)]])
                self.assertEqual(output, "repetitions=2")

    def test_relevant_removed_and_added_files_keep_two(self):
        for status in ["removed", "added"]:
            with self.subTest(status=status):
                output, _ = self.select([[changed_file(RELEVANT[0], status)]])
                self.assertEqual(output, "repetitions=2")

    def test_renames_inspect_old_and_new_paths(self):
        for path in RELEVANT:
            for old, new in [(path, ORDINARY), (ORDINARY, path)]:
                with self.subTest(old=old, new=new):
                    output, _ = self.select([[
                        changed_file(new, "renamed", previous_filename=old),
                    ]])
                    self.assertEqual(output, "repetitions=2")
        output, _ = self.select([[
            changed_file(ORDINARY, "renamed", previous_filename="Intent/OldView.swift"),
        ]])
        self.assertEqual(output, "repetitions=1")

    def test_later_page_is_inspected(self):
        first_page = [changed_file(f"Intent/File{index}.swift") for index in range(100)]
        output, _ = self.select([first_page, [changed_file(RELEVANT[0])]])
        self.assertEqual(output, "repetitions=2")
        output, _ = self.select([first_page, [changed_file(ORDINARY)]])
        self.assertEqual(output, "repetitions=1")

    def test_unrelated_tooling_is_an_ordinary_pr(self):
        output, _ = self.select([[
            changed_file(".github/scripts/select-macos-runner.sh"),
            changed_file("scripts/test_ci_simulator.py"),
            changed_file("IntentUITests/WorkspaceChangesUITests.swift"),
            changed_file("README.md"),
        ]])
        self.assertEqual(output, "repetitions=1")

    def test_missing_or_invalid_inputs_keep_two_without_api_access(self):
        cases = [
            {"pr_number": ""}, {"pr_number": "0"}, {"pr_number": "-1"},
            {"pr_number": "1/files"}, {"pr_number": "851\n"},
            {"repository": ""}, {"repository": "ios"},
            {"repository": "intent-hq/ios/extra"}, {"token": ""},
        ]
        for case in cases:
            with self.subTest(case=case):
                output, arguments = self.select(**case)
                self.assertEqual(output, "repetitions=2")
                self.assertEqual(arguments, [])

    def test_api_failure_keeps_two_even_after_partial_response(self):
        output, arguments = self.select(gh_status=1)
        self.assertEqual(output, "repetitions=2")
        self.assertTrue(arguments)

    def test_untrustworthy_responses_keep_two(self):
        responses = [
            "", "not-json", "null", "{}", "[]", "[[]]",
            json.dumps([changed_file(ORDINARY)]),
            json.dumps([[changed_file(ORDINARY)], {"message": "API error"}]),
            json.dumps([[changed_file(ORDINARY), None]]),
            json.dumps([[{"status": "modified"}]]),
            json.dumps([[{"filename": ORDINARY}]]),
            json.dumps([[changed_file(ORDINARY)]]) * 2,
        ]
        for filename in [None, 12, "", "../escape.swift", "/absolute.swift", "bad\npath"]:
            responses.append(json.dumps([[changed_file(filename)]]))
        for status in [None, 12, "", "unknown"]:
            responses.append(json.dumps([[changed_file(ORDINARY, status)]]))
        for previous in [None, 12, "", "../escape.swift"]:
            responses.append(json.dumps([[
                changed_file(ORDINARY, "renamed", previous_filename=previous),
            ]]))
        responses.append(json.dumps([[changed_file(ORDINARY, "renamed")]]))
        for raw in responses:
            with self.subTest(raw=raw):
                output, _ = self.select(raw=raw)
                self.assertEqual(output, "repetitions=2")

    def test_api_file_limit_cannot_reduce_coverage(self):
        page = [changed_file(f"Intent/File{index}.swift") for index in range(100)]
        output, _ = self.select([page] * 30)
        self.assertEqual(output, "repetitions=2")


if __name__ == "__main__":
    unittest.main()
