#!/usr/bin/env python3
"""protocol_fixture_version.py contract tests; Linux-only, no network or Swift tooling."""

import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

import protocol_fixture_version as pfv


ROOT = Path(__file__).resolve().parents[1]
RUST = 'pub const PROTOCOL_VERSION: &str = "{}";\npub const OTHER: &str = "1.0";\n'


def fake_get(releases, versions):
    """Serve a releases listing and protocol.rs per tag; records requested URLs."""
    calls = []

    def get(url, _accept):
        calls.append(url)
        if "/releases" in url:
            return json.dumps(releases)
        tag = url.rsplit("ref=", 1)[1]
        return RUST.format(versions[tag])

    get.calls = calls
    return get


def run(argv, root, get=None):
    err, out = io.StringIO(), io.StringIO()
    with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
        code = pfv.main(argv, root=root, get=get or fake_get([], {}))
    return code, out.getvalue() + err.getvalue()


class GeneratorTests(unittest.TestCase):
    def test_rust_constant_must_be_unique(self):
        self.assertEqual(pfv.parse_rust_protocol_version(RUST.format("16.2")), "16.2")
        with self.assertRaises(ValueError):
            pfv.parse_rust_protocol_version('pub const OTHER: &str = "1.0";')
        with self.assertRaises(ValueError):
            pfv.parse_rust_protocol_version(RUST.format("15.0") + RUST.format("16.0"))

    def test_newest_release_includes_prereleases_and_skips_drafts(self):
        releases = [
            {"tag_name": "v0.10.33"},
            {"tag_name": "v0.11.7"},
            {"tag_name": "v0.11.10-beta.2"},
            {"tag_name": "v0.11.9"},
            {"tag_name": "v0.12.0", "draft": True},
            {"tag_name": "nightly"},
        ]
        self.assertEqual(pfv.newest_release_tag(releases), "v0.11.10-beta.2")
        self.assertEqual(pfv.newest_release_tag(releases + [{"tag_name": "v0.11.10"}]), "v0.11.10")

    def test_rendered_file_round_trips(self):
        self.assertEqual(pfv.parse_rendered(pfv.render("v0.11.7", "15.0")), ("v0.11.7", "15.0"))
        self.assertIsNone(pfv.parse_rendered('let currentProtocolVersion = "15.0"\n'))

    def test_committed_file_is_generated(self):
        self.assertIsNotNone(pfv.parse_rendered((ROOT / pfv.OUTPUT).read_text(encoding="utf-8")))

    def test_sync_writes_newest_release_protocol(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "IntentTests").mkdir()
            get = fake_get([{"tag_name": "v0.11.7"}], {"v0.11.7": "15.0"})
            self.assertEqual(run(["sync"], root, get)[0], 0)
            self.assertIn("ref=v0.11.7", get.calls[-1])
            self.assertEqual(pfv.parse_rendered((root / pfv.OUTPUT).read_text()), ("v0.11.7", "15.0"))

    def test_check_fails_only_on_a_protocol_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "IntentTests").mkdir()
            (root / pfv.OUTPUT).write_text(pfv.render("v0.11.7", "15.0"))
            same = fake_get([{"tag_name": "v0.11.8"}], {"v0.11.8": "15.0"})
            self.assertEqual(run(["check"], root, same)[0], 0)
            bumped = fake_get([{"tag_name": "v0.12.0"}], {"v0.12.0": "16.0"})
            code, output = run(["check"], root, bumped)
            self.assertEqual(code, 1)
            self.assertIn("protocol_fixture_version.py sync", output)

    def test_check_fails_when_the_release_cannot_be_read(self):
        def broken(_url, _accept):
            raise OSError("offline")

        with tempfile.TemporaryDirectory() as tmp:
            code, output = run(["check"], Path(tmp), broken)
        self.assertEqual(code, 1)
        self.assertIn("offline", output)


class LintTests(unittest.TestCase):
    def test_reintroduced_literal_hello_is_rejected(self):
        found = pfv.lint_violations(
            {"IntentTests/X.swift": 'hello["server"] = ["protocolVersion": "15.0", "capabilities": [:]]'}
        )
        self.assertEqual([(p, line, v) for p, line, v, _ in found], [("IntentTests/X.swift", 1, "15.0")])

    def test_labelled_argument_literal_is_rejected(self):
        found = pfv.lint_violations({"IntentTests/X.swift": 'supportsCredit(protocolVersion: "10.4")'})
        self.assertEqual([v for _, _, v, _ in found], ["10.4"])

    def test_constant_and_reasoned_escapes_pass(self):
        files = {
            "IntentTests/X.swift": "\n".join(
                [
                    '["protocolVersion": ProtocolFixtures.currentProtocolVersion]',
                    '["protocolVersion": "10.3"] // fixture-protocol-version: before credit support',
                    "// fixture-protocol-version: old daemon",
                    '["protocolVersion": "13.0"]',
                ]
            )
        }
        self.assertEqual(pfv.lint_violations(files), [])

    def test_escape_needs_a_reason_and_must_be_adjacent(self):
        files = {
            "IntentTests/X.swift": "\n".join(
                [
                    '["protocolVersion": "10.3"] // fixture-protocol-version:',
                    "let a = 1 // fixture-protocol-version: about a",
                    '["protocolVersion": "13.0"]',
                ]
            )
        }
        self.assertEqual([line for _, line, _, _ in pfv.lint_violations(files)], [1, 3])

    def test_lint_scans_test_targets_and_passes_on_the_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "IntentUITests").mkdir()
            (root / "Intent").mkdir()
            (root / "IntentUITests/Y.swift").write_text('["protocolVersion": "14.0"]\n')
            (root / "Intent/App.swift").write_text('["protocolVersion": "15.0"]\n')
            code, output = run(["lint"], root)
            self.assertEqual(code, 1)
            self.assertIn("IntentUITests/Y.swift:1", output)
            self.assertNotIn("Intent/App.swift", output)
        self.assertEqual(run(["lint"], ROOT)[0], 0)


if __name__ == "__main__":
    unittest.main()
