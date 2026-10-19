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
HEAD_SHA = "a" * 40
BASE_SHA = "b" * 40
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


def ordinary_files(count, start=0):
    return [changed_file(f"Intent/File{index}.swift")
            for index in range(start, start + count)]


def paginated(files):
    return [files[index:index + 100] for index in range(0, len(files), 100)]


def pr_metadata(count=1, head=HEAD_SHA, base=BASE_SHA):
    return {"head": {"sha": head}, "base": {"sha": base}, "changed_files": count}


class FixtureCaptureSelectionTests(unittest.TestCase):
    def select(self, pages=None, *, event="pull_request", pr_number="851",
               repository="intent-hq/ios", token=TOKEN, gh_status=0, raw=None,
               missing=(), head_sha=HEAD_SHA, base_sha=BASE_SHA,
               metadata_raw=None, after_metadata_raw=None,
               metadata_status=0, after_metadata_status=0, stderr=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / "response.json"
            if pages is None:
                pages = [[changed_file(ORDINARY)]]
            fixture.write_text(json.dumps(pages) if raw is None else raw)
            metadata = json.dumps(pr_metadata(
                sum(len(page) for page in pages if isinstance(page, list)),
            ))
            before = root / "metadata-before.json"
            after = root / "metadata-after.json"
            before.write_text(metadata if metadata_raw is None else metadata_raw)
            after.write_text(before.read_text() if after_metadata_raw is None else after_metadata_raw)
            stub = root / "gh"
            stub.write_text(
                '#!/bin/bash\nset -eu\n'
                'printf "%s\\n" "$@" >> "$TEST_ARGUMENTS"\n'
                'printf "%s" "$TEST_STDERR" >&2\n'
                'if [[ "$*" != *"/files?per_page=100" ]]; then\n'
                '  if [[ -f "$TEST_METADATA_SEEN" ]]; then\n'
                '    cat "$TEST_METADATA_AFTER"\n'
                '    exit "$TEST_METADATA_AFTER_STATUS"\n'
                '  fi\n'
                '  cat "$TEST_METADATA_BEFORE"\n'
                '  touch "$TEST_METADATA_SEEN"\n'
                '  exit "$TEST_METADATA_STATUS"\n'
                'fi\n'
                'cat "$TEST_RESPONSE"\n'
                'if [ "$TEST_GH_STATUS" != 0 ]; then\n'
                '  printf "%s\\n" "${GH_TOKEN:-}" >&2\n'
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
                TEST_METADATA_AFTER_STATUS=str(after_metadata_status),
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
            self.assertNotIn(TOKEN, process.stdout + process.stderr + output.read_text())
            lines = output.read_text().splitlines()
            self.assertEqual(lines[0], "existing-output=preserved")
            self.assertEqual(len(lines), 2)
            args = arguments.read_text().splitlines() if arguments.exists() else []
            self.assertNotIn(TOKEN, "\n".join(args))
            return lines[1], args

    def test_ordinary_pr_uses_one_and_requests_all_pages(self):
        output, arguments = self.select()
        self.assertEqual(output, "repetitions=1")
        self.assertEqual(arguments, [
            "api", "repos/intent-hq/ios/pulls/851",
            "api", "--paginate", "--slurp",
            "repos/intent-hq/ios/pulls/851/files?per_page=100",
            "api", "repos/intent-hq/ios/pulls/851",
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

    def test_ordinary_statuses_still_use_one(self):
        for status in ["added", "removed", "modified", "copied", "changed", "unchanged"]:
            with self.subTest(status=status):
                output, _ = self.select([[changed_file(ORDINARY, status)]])
                self.assertEqual(output, "repetitions=1")

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
            {"pr_number": "1/files"}, {"pr_number": "851\n"}, {"pr_number": "01"},
            {"repository": ""}, {"repository": "ios"},
            {"repository": "intent-hq/ios/extra"}, {"repository": "../ios"},
            {"repository": "intent-hq/.."}, {"repository": "intent-hq/."},
            {"repository": "intent-hq/ios\n"}, {"repository": "intent-hq/ios?extra"},
            {"token": ""}, {"token": " "}, {"token": f"{TOKEN}\n"},
        ] + [
            {name: value} for name in ["head_sha", "base_sha"]
            for value in ["", "a" * 39, "a" * 41, "g" * 40, HEAD_SHA + "\n"]
        ] + [
            {"missing": [name]} for name in
            ["GITHUB_EVENT_NAME", "PR_NUMBER", "PR_HEAD_SHA", "PR_BASE_SHA",
             "GITHUB_REPOSITORY", "GH_TOKEN"]
        ]
        for case in cases:
            with self.subTest(case=case):
                output, arguments = self.select(**case)
                self.assertEqual(output, "repetitions=2")
                self.assertEqual(arguments, [])

    def test_api_failure_keeps_two_even_after_partial_response(self):
        for stage, calls in [("metadata_status", 1), ("gh_status", 2),
                             ("after_metadata_status", 3)]:
            for status in [1, 2, 127]:
                with self.subTest(stage=stage, status=status):
                    output, arguments = self.select(**{stage: status}, stderr=TOKEN)
                    self.assertEqual(output, "repetitions=2")
                    self.assertEqual(arguments.count("api"), calls)

    def test_stale_head_or_base_before_lookup_does_not_fetch_files(self):
        for field in ["head", "base"]:
            with self.subTest(field=field):
                output, arguments = self.select(
                    metadata_raw=json.dumps(pr_metadata(**{field: "c" * 40})),
                )
                self.assertEqual(output, "repetitions=2")
                self.assertEqual(arguments, ["api", "repos/intent-hq/ios/pulls/851"])

    def test_head_base_or_count_changes_during_lookup_keep_two(self):
        for metadata in [pr_metadata(head="c" * 40), pr_metadata(base="c" * 40),
                         pr_metadata(count=2)]:
            with self.subTest(metadata=metadata):
                output, arguments = self.select(after_metadata_raw=json.dumps(metadata))
                self.assertEqual(output, "repetitions=2")
                self.assertEqual(arguments.count("api"), 3)

    def test_malformed_metadata_at_either_stage_keeps_two(self):
        valid = pr_metadata()
        invalid = ["", "not-json", "null", "true", "42", "[]", "{}",
                   json.dumps(valid) * 2, json.dumps(valid) + "\nnull"]
        for field in ["head", "base", "changed_files"]:
            invalid.append(json.dumps({key: value for key, value in valid.items() if key != field}))
        for field in ["head", "base"]:
            for value in [None, [], {}, "bad", {"sha": None}]:
                invalid.append(json.dumps(dict(valid, **{field: value})))
        for count in [0, -1, 3000, 3001, "1", 1.5, None, True, [], {}]:
            invalid.append(json.dumps(pr_metadata(count=count)))
        for raw in invalid:
            for stage in ["metadata_raw", "after_metadata_raw"]:
                with self.subTest(raw=raw, stage=stage):
                    output, _ = self.select(**{stage: raw})
                    self.assertEqual(output, "repetitions=2")

    def test_stable_metadata_must_match_returned_file_count(self):
        for count in [1, 100, 101, 200]:
            for expected in [count - 1, count + 1]:
                with self.subTest(count=count, expected=expected):
                    output, _ = self.select(
                        paginated(ordinary_files(count)),
                        metadata_raw=json.dumps(pr_metadata(count=expected)),
                    )
                    self.assertEqual(output, "repetitions=2")

    def test_tokens_in_response_and_diagnostics_are_not_printed(self):
        for raw in [TOKEN, json.dumps({"message": TOKEN}),
                    json.dumps([[changed_file(ORDINARY, patch=TOKEN)]])]:
            with self.subTest(raw=raw):
                self.select(raw=raw, stderr=TOKEN)
        for stage in ["metadata_raw", "after_metadata_raw"]:
            self.select(**{stage: TOKEN}, stderr=TOKEN)

    def test_untrustworthy_responses_keep_two(self):
        valid = json.dumps([[changed_file(ORDINARY)]])
        responses = [
            "", "not-json", "null", "true", "42", "{}", "[]", "[[]]",
            valid[:-1], valid * 2, valid + "\nnull", "null\n" + valid, valid + "\n[]",
            json.dumps([changed_file(ORDINARY)]),
            json.dumps([[changed_file(ORDINARY)], {"message": "API error"}]),
            json.dumps([[changed_file(ORDINARY), None]]),
            json.dumps([[{"status": "modified"}]]),
            json.dumps([[{"filename": ORDINARY}]]),
            json.dumps([[changed_file(ORDINARY)]]) * 2,
        ]
        for entry in [None, True, 12, ORDINARY, [], {}]:
            responses.append(json.dumps([[entry]]))
        invalid_paths = [None, 12, [], {}, "", "../escape.swift", "/absolute.swift",
                         "./file.swift", "Intent/../file.swift", "Intent/./file.swift",
                         "Intent//file.swift", "Intent/file.swift/", "Intent\\file.swift",
                         "bad\npath", "bad\tpath", "bad\x00path"]
        for filename in invalid_paths:
            responses.append(json.dumps([[changed_file(filename)]]))
        for status in [None, 12, [], {}, "", "unknown"]:
            responses.append(json.dumps([[changed_file(ORDINARY, status)]]))
        for previous in invalid_paths:
            responses.append(json.dumps([[
                changed_file(ORDINARY, "renamed", previous_filename=previous),
            ]]))
        responses.append(json.dumps([[changed_file(ORDINARY, "renamed")]]))
        for raw in responses:
            with self.subTest(raw=raw):
                output, _ = self.select(raw=raw)
                self.assertEqual(output, "repetitions=2")

    def test_complete_pagination_with_matching_metadata_uses_one(self):
        for count in [1, 99, 100, 101, 199, 200, 201, 2900, 2999]:
            with self.subTest(count=count):
                output, _ = self.select(paginated(ordinary_files(count)))
                self.assertEqual(output, "repetitions=1")

    def test_relevant_current_or_previous_path_on_full_final_page_keeps_two(self):
        for old, new in [(ORDINARY, RELEVANT[0]), (RELEVANT[0], ORDINARY)]:
            with self.subTest(old=old, new=new):
                files = ordinary_files(199)
                files.append(changed_file(new, "renamed", previous_filename=old))
                output, _ = self.select(paginated(files))
                self.assertEqual(output, "repetitions=2")

    def test_malformed_page_shapes_keep_two_even_when_total_matches_metadata(self):
        cases = [
            [ordinary_files(101)],
            [ordinary_files(1), ordinary_files(1, 1)],
            [ordinary_files(99), ordinary_files(1, 99)],
            [ordinary_files(100), ordinary_files(1, 100), ordinary_files(1, 101)],
            [[], ordinary_files(1)],
            [ordinary_files(1), []],
            [ordinary_files(100), []],
            [ordinary_files(100), [], ordinary_files(1, 100)],
            [ordinary_files(100), None],
            [ordinary_files(100), "truncated"],
            [ordinary_files(100), {"message": "API error"}],
        ]
        for pages in cases:
            with self.subTest(pages=pages):
                output, _ = self.select(pages)
                self.assertEqual(output, "repetitions=2")

    def test_duplicate_files_within_or_across_pages_keep_two(self):
        for pages in [[ordinary_files(1) * 2],
                      [ordinary_files(100), ordinary_files(1)],
                      [ordinary_files(100), ordinary_files(100)]]:
            with self.subTest(pages=pages):
                output, _ = self.select(pages)
                self.assertEqual(output, "repetitions=2")

    def test_api_file_limit_cannot_reduce_coverage(self):
        for count in [3000, 3001, 3101]:
            for expected in [count, 2999]:
                with self.subTest(count=count, expected=expected):
                    output, _ = self.select(
                        paginated(ordinary_files(count)),
                        metadata_raw=json.dumps(pr_metadata(count=expected)),
                    )
                    self.assertEqual(output, "repetitions=2")


if __name__ == "__main__":
    unittest.main()
