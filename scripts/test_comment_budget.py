#!/usr/bin/env python3
"""Comment ratchet tests: lexer edge cases, check/update contract, strip layout."""

from pathlib import Path
import json
import subprocess
import sys
import tempfile
import textwrap
import unittest

from comment_budget import LexError, classify, strip_source

SCRIPT = Path(__file__).with_name("comment_budget.py")


def counted(source):
    return [line.number for line in classify(textwrap.dedent(source)) if line.counted]


class LexerTests(unittest.TestCase):
    def test_comment_markers_inside_literals_are_code(self):
        source = '''\
        let url = "https://example.com" // real
        let raw = #"a "// b" /* c */"#
        let block = """
            // not a comment
            """
        let nested = "\\(value.map { "// \\("x")" })"
        let lookalike = #""""[a]"|//[^\\n]*"#
        let regex = #/\\/\\/ path/#
        let bare = text.contains(/a\\/b/)
        let ratio = width / 2 // half
        '''
        self.assertEqual(counted(source), [1, 10])

    def test_a_quote_inside_a_comment_does_not_open_a_string(self):
        self.assertEqual(counted('// don\'t "quote\nlet a = 1 // b\n'), [1, 2])

    def test_nested_block_comments_span_every_line(self):
        self.assertEqual(counted("/* a\n/* b */\nc */\nlet x = 1\n"), [1, 2, 3])

    def test_tool_directives_are_exempt(self):
        source = """\
        // swiftlint:disable:next force_try
        let a = try! f() // swiftlint:disable:this force_unwrapping
        // fixture-protocol-version: brackets the cutoff
        // periphery:ignore
        // MARK: - Section
        """
        self.assertEqual(counted(source), [5])

    def test_comments_inside_interpolations_are_counted(self):
        self.assertEqual(counted('let s = "\\(1 /* note */)"\nlet t = 2\n'), [1])
        source = 'let s = """\n    \\(value // why\n    )\n    """\n'
        self.assertEqual(counted(source), [2])

    def test_quotes_and_parens_in_interpolated_comments_are_skipped(self):
        self.assertEqual(counted('let s = "\\(f(x) /* ") ( */)"\n'), [1])

    def test_unclosed_literal_is_an_error(self):
        with self.assertRaises(LexError):
            classify('let a = "open\n')


class StripTests(unittest.TestCase):
    def strip(self, source, lines=None):
        return strip_source(textwrap.dedent(source), lines)

    def test_strip_keeps_layout_lint_clean(self):
        source = """\
        // File header

        import Foundation

        /// Doc.
        struct A {
            // MARK: - First

            let a = 1 // trailing

            // Before close
        }
        """
        expected = """\
        import Foundation

        struct A {
            let a = 1
        }
        """
        self.assertEqual(self.strip(source), textwrap.dedent(expected))

    def test_strip_keeps_directives_strings_and_unselected_lines(self):
        source = """\
        // keep
        // swiftlint:disable:next force_try
        let a = try! f("// text") // drop
        """
        expected = """\
        // keep
        // swiftlint:disable:next force_try
        let a = try! f("// text")
        """
        self.assertEqual(self.strip(source, {3}), textwrap.dedent(expected))

    def test_strip_removes_a_block_comment_that_ends_beside_code(self):
        self.assertEqual(self.strip("/* note\n*/ let x = 1\n"), "let x = 1\n")
        self.assertEqual(self.strip("func f() {\n    /* a\n    b */ let x = 1\n}\n"), "func f() {\n    let x = 1\n}\n")

    def test_strip_keeps_tokens_apart(self):
        self.assertEqual(self.strip("let/*note*/value = 1\n"), "let value = 1\n")
        self.assertEqual(self.strip("let x = 1 /* a */ + 2\n"), "let x = 1 + 2\n")

    def test_strip_removes_comments_inside_interpolations(self):
        self.assertEqual(self.strip('let s = "\\(1 /* note */)"\n'), 'let s = "\\(1)"\n')

    def test_strip_collapses_blanks_around_a_removed_block(self):
        self.assertEqual(self.strip("a\n\n// x\n\nb\n"), "a\n\nb\n")


class RatchetTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / "scripts").mkdir()
        (self.root / "Intent").mkdir()

    def write(self, name, source):
        (self.root / "Intent" / name).write_text(source, encoding="utf-8")

    def run_script(self, command):
        return subprocess.run(
            [sys.executable, str(SCRIPT), command, "--root", str(self.root)],
            capture_output=True, text=True, check=False,
        )

    def baseline(self):
        return json.loads((self.root / "scripts/comment-budget.json").read_text())["files"]

    def test_first_update_records_counts_then_check_passes(self):
        self.write("A.swift", "// a\n// b\nlet a = 1\n")
        self.write("B.swift", "let b = 1\n")
        self.assertEqual(self.run_script("update").returncode, 0)
        self.assertEqual(self.baseline(), {"Intent/A.swift": 2})
        self.assertEqual(self.run_script("check").returncode, 0)

    def test_new_comments_fail_and_update_refuses_to_raise(self):
        self.write("A.swift", "// a\nlet a = 1\n")
        self.run_script("update")
        self.write("A.swift", "// a\n// b\nlet a = 1\n")
        self.write("New.swift", "let n = 1 // new\n")
        result = self.run_script("check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Intent/A.swift: 2 comment lines (budget 1)", result.stderr)
        self.assertIn("Intent/New.swift: 1 comment lines (budget 0)", result.stderr)
        self.assertEqual(self.run_script("update").returncode, 1)
        self.assertEqual(self.baseline(), {"Intent/A.swift": 1})

    def test_removed_comments_require_lowering_the_baseline(self):
        self.write("A.swift", "// a\n// b\nlet a = 1\n")
        self.write("B.swift", "// b\nlet b = 1\n")
        self.run_script("update")
        self.write("A.swift", "// a\nlet a = 1\n")
        self.write("B.swift", "let b = 1\n")
        result = self.run_script("check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Intent/A.swift: dropped to 1", result.stderr)
        self.assertIn("Intent/B.swift: has no comments left", result.stderr)
        self.assertEqual(self.run_script("update").returncode, 0)
        self.assertEqual(self.baseline(), {"Intent/A.swift": 1})
        self.assertEqual(self.run_script("check").returncode, 0)


if __name__ == "__main__":
    unittest.main()
