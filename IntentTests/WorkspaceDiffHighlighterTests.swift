import Foundation
@testable import Intent
import Testing

struct WorkspaceDiffHighlighterTests {
    @Test func multilineTokensKeepTheirLineLocalUnicodeRanges() async throws {
        let lines = ["/* café 👩🏽‍💻\n", "日本語 */\n", "", "let name = \"e\u{301}\"\n", "let count = 42"]
        let result = try await WorkspaceDiffHighlighter.highlight(hunk(lines), path: "Code.swift")
        for index in [0, 1] {
            let text = WorkspaceDiffHighlighter.displayedText(lines[index])
            let comments = (result[index] ?? []).filter { $0.scope == "comment" }
            #expect(try comments.map { String(text[try #require(Range($0.range, in: text))]) }.joined() == text)
        }
        #expect(result[2] == nil)
        for (index, scope, snippet) in [(3, "keyword", "let"), (3, "string", "\"e\u{301}\""), (4, "number", "42")] {
            let text = WorkspaceDiffHighlighter.displayedText(lines[index])
            let expected = NSRange(try #require(text.range(of: snippet)), in: text)
            #expect(result[index]?.contains { $0.scope == scope && $0.range == expected } == true)
        }
    }

    @Test func multilineStringsAndTrailingNewlinesPreserveDisplayedContent() async throws {
        let lines = ["let text = \"\"\"", "hello 👋\r\n", "world\n", "\"\"\"", "let done = true"]
        let result = try await WorkspaceDiffHighlighter.highlight(hunk(lines), path: "Code.swift")
        #expect(WorkspaceDiffHighlighter.displayedText(lines[1]) == "hello 👋\r\n")
        #expect(WorkspaceDiffHighlighter.displayedText(lines[2]) == "world")
        for index in [1, 2] {
            let text = WorkspaceDiffHighlighter.displayedText(lines[index])
            let strings = (result[index] ?? []).filter { $0.scope == "string" }
            #expect(try strings.map { String(text[try #require(Range($0.range, in: text))]) }.joined() == text)
        }
        #expect(result[4]?.contains { $0.scope == "keyword" && $0.range.location == 0 } == true)
    }

    @Test(arguments: ["/*", "let text = \"\"\""], [WorkspaceDiffLine.Kind.deletion, .addition])
    func changedLinesDoNotShareMultilineState(opener: String, scopedKind: WorkspaceDiffLine.Kind) async throws {
        let scope = opener == "/*" ? "comment" : "string"
        let otherKind: WorkspaceDiffLine.Kind = scopedKind == .deletion ? .addition : .deletion
        let input = mixedHunk([
            (.context, "let before = 1\n"),
            (scopedKind, opener + "\n"),
            (otherKind, "let value = \"fresh\"\n"),
            (.context, "let shared = \"context\"\n"),
            (scopedKind, "still scoped\n")
        ])
        let result = try await WorkspaceDiffHighlighter.highlight(input, path: "Code.swift")
        let text = WorkspaceDiffHighlighter.displayedText(input.lines[2].content)
        for (scope, snippet) in [("keyword", "let"), ("string", "\"fresh\"")] {
            let range = NSRange(try #require(text.range(of: snippet)), in: text)
            #expect(result[2]?.contains { $0.scope == scope && $0.range == range } == true)
        }
        // Shared context is rendered from the new side, but still participates
        // in both token streams so each side's multiline state is preserved.
        let context = WorkspaceDiffHighlighter.displayedText(input.lines[3].content)
        if scopedKind == .deletion {
            #expect(result[3]?.contains { $0.scope == "keyword" && $0.range == NSRange(location: 0, length: 3) } == true)
        } else {
            #expect(result[3] == [.init(range: NSRange(location: 0, length: context.utf16.count), scope: scope)])
        }
        let tail = WorkspaceDiffHighlighter.displayedText(input.lines[4].content)
        #expect(result[4] == [.init(range: NSRange(location: 0, length: tail.utf16.count), scope: scope)])
    }

    @Test func capIncludesJoinedLineSeparatorsAndCountsUTF8Bytes() async throws {
        let cap = WorkspaceSyntaxHighlighter.maxBytes
        let prefix = "let count = 42"
        let padding = String(repeating: " ", count: cap - prefix.utf8.count - 1)
        #expect(try await !WorkspaceDiffHighlighter.highlight(hunk([prefix, padding]), path: "Code.swift").isEmpty)
        #expect(try await WorkspaceDiffHighlighter.highlight(hunk([prefix, padding + " "]), path: "Code.swift").isEmpty)
        let unicode = String(repeating: "é", count: cap / 2)
        #expect(try await WorkspaceDiffHighlighter.highlight(hunk([prefix, unicode]), path: "Code.swift").isEmpty)
        #expect(try await !WorkspaceDiffHighlighter.highlight(hunk([prefix]), path: "Code.swift").isEmpty)
    }

    @Test(arguments: [WorkspaceDiffLine.Kind.addition, .deletion])
    func extensionlessShellDiffRecognizesFirstLineShebang(_ kind: WorkspaceDiffLine.Kind) async throws {
        let input = mixedHunk([(kind, "#!/bin/bash"), (kind, "printf 'ready'")])
        let result = try await WorkspaceDiffHighlighter.highlight(input, path: "run")
        #expect(result[0]?.contains { $0.scope == "meta" } == true)
        #expect(result[1]?.contains { $0.scope == "built_in" && $0.range == NSRange(location: 0, length: 6) } == true)
        #expect(result[1]?.contains { $0.scope == "string" && $0.range == NSRange(location: 7, length: 7) } == true)
    }

    @Test func unsupportedAndCancelledHunksDoNotPublishTokens() async throws {
        let input = hunk(["let count = 42"])
        #expect(try await WorkspaceDiffHighlighter.highlight(input, path: "Code.unknown").isEmpty)
        #expect(try await WorkspaceDiffHighlighter.highlight(hunk([]), path: "Code.swift").isEmpty)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WorkspaceDiffHighlighter.highlight(input, path: "Code.swift")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func hunk(_ contents: [String]) -> WorkspaceDiffHunk {
        mixedHunk(contents.map { (.addition, $0) })
    }

    private func mixedHunk(_ entries: [(WorkspaceDiffLine.Kind, String)]) -> WorkspaceDiffHunk {
        var oldNumber = 0
        var newNumber = 0
        let lines = entries.map { kind, content in
            if kind != .addition { oldNumber += 1 }
            if kind != .deletion { newNumber += 1 }
            return WorkspaceDiffLine(
                type: kind,
                content: content,
                oldNumber: kind == .addition ? nil : oldNumber,
                newNumber: kind == .deletion ? nil : newNumber
            )
        }
        return WorkspaceDiffHunk(
            oldStart: 1,
            oldLines: oldNumber,
            newStart: 1,
            newLines: newNumber,
            lines: lines
        )
    }
}
