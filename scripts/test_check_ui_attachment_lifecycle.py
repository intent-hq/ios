#!/usr/bin/env python3
"""Source-contract mutations; runs on Linux without XCTest or Swift tooling."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import check_ui_attachment_lifecycle as lifecycle


ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts/check_ui_attachment_lifecycle.py"


class AttachmentLifecycleTests(unittest.TestCase):
    def test_direct_and_nested_attachments_are_rejected_at_defer_line(self):
        for body in (
            'add(XCTAttachment(screenshot: app.screenshot()))',
            'if shouldCapture { let image = XCTest.XCTAttachment.init(string: "diagnostic") }',
            'XCTContext.runActivity(named: "diagnostic") { activity in activity.add(savedAttachment) }',
            'self.add(savedAttachment)',
        ):
            with self.subTest(body=body):
                found = lifecycle.violations({"Direct.swift": f"func testFixture() {{\n    defer {{ {body} }}\n}}"})
                self.assertEqual([(path, line) for path, line, _ in found], [("Direct.swift", 2)])

    def test_transitive_helpers_in_other_files_and_extensions_are_rejected(self):
        sources = {
            "Fixture.swift": "func testFixture() { defer { self.finalState(app) } }",
            "Helpers.swift": """
                extension Fixture {
                    func finalState(_ app: XCUIApplication) { diagnostics(app) }
                    func diagnostics(_ app: XCUIApplication) {
                        if app.exists { record(app) }
                    }
                }
            """,
            "Attachments.swift": "func record(_ app: XCUIApplication) { add(XCTAttachment(string: app.debugDescription)) }",
        }
        self.assertEqual(lifecycle.violations(sources), [("Fixture.swift", 1, "finalState")])
        sources["Attachments.swift"] = "func record(_ app: XCUIApplication) { app.terminate() }"
        self.assertEqual(lifecycle.violations(sources), [])

    def test_recursive_helpers_reach_a_fixed_point(self):
        sources = {"Helpers.swift": """
            func first() { second() }
            func second() { first(); third() }
            func third() { add(existingAttachment) }
            func testFixture() { defer { first() } }
        """}
        self.assertEqual(lifecycle.violations(sources), [("Helpers.swift", 5, "first")])

    def test_attachment_calls_in_helper_defaults_are_rejected(self):
        for parameters in ("_ emitted: Void = emitAttachment()",
                           "_ title: String = format(1, 2), emitted: Void = emitAttachment()",
                           "_ emitted: Void = Diagnostics<Int, String>.emitAttachment()",
                           "_ emitted: Void = Diagnostics<Box<Int, String>, Double>.emitAttachment(), ignored: XCTAttachment? = nil",
                           "_ prepare: () -> Void = { emitAttachment() }"):
            with self.subTest(parameters=parameters):
                source = f"""
                    func emitAttachment() {{ add(XCTAttachment(string: "final")) }}
                    func finalDiagnostic({parameters}) {{}}
                    func testFixture() {{ defer {{ finalDiagnostic() }} }}
                """
                self.assertEqual(lifecycle.violations({"Defaults.swift": source}),
                                 [("Defaults.swift", 4, "finalDiagnostic")])

    def test_cleanup_defaults_and_attachment_parameter_types_are_allowed(self):
        source = """
            func cleanup(_ ignored: XCTAttachment? = nil, action: () -> Void = { app.terminate() }) { action() }
            func cleanupGeneric(_ value: Void = Diagnostics<Int, String>.cleanup(), ignored: XCTAttachment? = nil) {}
            func cleanupComparison(_ flag: Bool = threshold < 3, ignored: XCTAttachment? = nil) {}
            func testFixture() { defer { cleanup() } }
            func testGeneric() { defer { cleanupGeneric() } }
            func testComparison() { defer { cleanupComparison() } }
        """
        self.assertEqual(lifecycle.violations({"Defaults.swift": source}), [])

    def test_generic_static_default_capture_reproduction(self):
        source = """
            enum Diagnostics<A, B> {
                static func emitAttachment() {
                    XCTContext.runActivity(named: "final") { activity in
                        activity.add(XCTAttachment(string: "state"))
                    }
                }
            }
            func finalDiagnostic(_ emitted: Void = Diagnostics<Int, String>.emitAttachment()) {}
            func testFixture() { defer { finalDiagnostic() } }
        """
        self.assertEqual(lifecycle.violations({"Defaults.swift": source}), [("Defaults.swift", 10, "finalDiagnostic")])

    def test_multiline_signatures_default_closures_and_escaped_names(self):
        sources = {"Fixture.swift": """
            func `record`(
                app: XCUIApplication,
                prepare: () -> Void = { cleanup() }
            ) async throws -> Void {
                add(XCTAttachment(string: app.debugDescription))
            }
            func testFixture() { defer { self.`record`(app: app) } }
        """}
        self.assertEqual(lifecycle.violations(sources), [("Fixture.swift", 8, "record")])

    def test_cleanup_and_teardown_are_allowed(self):
        sources = {"Fixture.swift": """
            func testFixture() {
                defer { cleanup(app) }
                defer { XCUIDevice.shared.orientation = .portrait }
                defer { try? FileManager.default.removeItem(at: file) }
                addTeardownBlock { @MainActor [self] () async in
                    add(XCTAttachment(screenshot: app.screenshot()))
                    app.terminate()
                }
            }
            func cleanup(_ app: XCUIApplication) { app.terminate() }
        """}
        self.assertEqual(lifecycle.violations(sources), [])

    def test_comments_and_literal_text_do_not_create_helpers_or_defer_blocks(self):
        source = r'''
            // defer { add(XCTAttachment(string: "comment")) }
            /* outer /* nested comment */ defer { add(saved) } */
            let sample = "defer { add(saved) }"
            let raw = ##"defer { add(saved) } // \(record())"##
            let multiline = """
                defer { add(saved) }
                } { "quoted text"
                """
            func cleanup() {
                let prose = "XCTAttachment(screenshot: app.screenshot())"
                /* add(saved) */
            }
            func testFixture() { defer { cleanup() } }
        '''
        self.assertEqual(lifecycle.violations({"Fixture.swift": source}), [])

    def test_calls_inside_string_interpolation_are_code(self):
        for literal in (r'"state: \(record())"', r'#"state: \#(record())"#',
                        r'##"state: \##(record())"##', '"""state: \\(record())"""',
                        r'"state: \(format("nested: \(record())"))"'):
            with self.subTest(literal=literal):
                source = 'func record() { add(savedAttachment) }\nfunc testFixture() { defer { print(' + literal + ') } }'
                self.assertEqual(lifecycle.violations({"Fixture.swift": source}), [("Fixture.swift", 2, "record")])

    def test_nested_braces_and_string_braces_do_not_hide_capture(self):
        source = '''func testFixture() {
            defer {
                if app.exists { print("}") }
                add(XCTAttachment(string: "{"))
            }
        }'''
        self.assertEqual([(path, line) for path, line, _ in lifecycle.violations({"Fixture.swift": source})],
                         [("Fixture.swift", 2)])

    def test_malformed_source_and_empty_scan_fail_closed(self):
        for source in ('defer { add(saved)', 'let label = "unfinished', '/* unclosed'):
            with self.subTest(source=source), self.assertRaises(ValueError):
                lifecycle.violations({"Fixture.swift": source})
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(CHECK), "--root", directory], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("No Swift UI test sources", result.stderr)

    def test_cli_rejects_restored_watcher_and_transcript_defer_in_real_tree(self):
        sources = {str(path.relative_to(ROOT)): path.read_text(encoding="utf-8")
                   for path in (ROOT / "IntentUITests").rglob("*.swift")}
        self.assertEqual(lifecycle.violations(sources), [])
        cases = (
            ("IntentUITests/WatcherMessageUITests.swift", 'attachScreenshot(app, name: "Watcher final state")'),
            ("IntentUITests/ConversationTranscriptScrollUITests.swift",
             'attachStartupViewport(app, opened: opened, report: startupReport(app), row: divider, context: "ready entry divider")'),
            ("IntentUITests/ConversationTranscriptScrollUITests.swift",
             'attachStartupViewport(app, opened: opened, report: startupReport(app), row: row, context: "after retained return")'),
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for path, source in sources.items():
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(source, encoding="utf-8")
            for path, capture in cases:
                with self.subTest(capture=capture):
                    original = sources[path]
                    teardown = 'addTeardownBlock { @MainActor [self] () async in\n            ' + capture + '\n        }'
                    self.assertEqual(original.count(teardown), 1, "mutation must replace an actual capture teardown")
                    (root / path).write_text(original.replace(teardown, 'defer { ' + capture + ' }'), encoding="utf-8")
                    result = subprocess.run([sys.executable, str(CHECK), "--root", str(root)], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn(path + ":", result.stderr)
                    self.assertIn("attachment-producing defer", result.stderr)
                    (root / path).write_text(original, encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
