import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceDiffSyntaxTests {
    private enum Fixture {
        static let hiddenLines = 12
        static let gapLine = 10
        static let newLines = 3
        static let repeatedNewSource = 4
    }

    @Test func completeSourcesKeepHiddenContextAndExcludeEndOfFileAnnotation() throws {
        let middle = String(repeating: "comment\n", count: Fixture.hiddenLines)
        let old = "/*\n\(middle)old 👋"
        let new = "/*\n\(middle)new 👋"
        let hunks = try WorkspaceDiffBuilder.hunks(old: old, new: new)
        let presentation = WorkspaceDiffPresentation(hunks: hunks, oldSource: old, newSource: new)
        let sources = presentation.sources()
        #expect(sources.map(\.text) == [old, new])
        #expect(!hunks.flatMap(\.lines).contains { $0.content == "/*" })
        let source = try #require(sources.last)
        let runs = WorkspaceDiffPresentation.map([
            FileSyntaxRun(location: 0, length: new.utf16.count, color: "#123456")
        ], from: source)
        let row = try #require(hunks.first?.lines.indices.last)
        let mapped = try #require(runs[.init(hunk: 0, line: row)]?.first)
        #expect(mapped.location == 0)
        #expect(mapped.length == "new 👋".utf16.count)
        let line = try #require(hunks.first?.lines.last)
        let attributed = WorkspaceDiffSyntax.text(line, runs: [mapped])
        #expect(String(attributed.characters) == line.content)
        #expect(line.content.hasSuffix("No newline at end of file"))
    }

    @Test func hunkSidesPreserveMultilineContextAndMapUnicodeToOriginalRows() throws {
        let hunks = try WorkspaceDiffBuilder.hunks(old: "/*\r\nold 👋\r\n*/\r\n", new: "/*\r\nnew café\r\n*/\r\n")
        let sources = WorkspaceDiffPresentation(hunks: hunks).sources()
        #expect(sources.map(\.text) == ["/*\r\nold 👋\r\n*/\r\n", "/*\r\nnew café\r\n*/\r\n"])
        let old = try #require(sources.first)
        let oldRuns = WorkspaceDiffPresentation.map([
            FileSyntaxRun(location: 0, length: old.text.utf16.count, color: "#123456")
        ], from: old)
        #expect(oldRuns.count == 1)
        let deletion = try #require(hunks[0].lines.firstIndex { $0.type == .deletion })
        #expect(oldRuns[.init(hunk: 0, line: deletion)]?.first?.length == "old 👋\r".utf16.count)
        let new = try #require(sources.last)
        let tokenRange = (new.text as NSString).range(of: "café")
        let mapped = WorkspaceDiffPresentation.map([
            FileSyntaxRun(location: tokenRange.location, length: tokenRange.length, color: "#654321")
        ], from: new)
        let addition = try #require(hunks[0].lines.firstIndex { $0.type == .addition })
        let run = try #require(mapped[.init(hunk: 0, line: addition)]?.first)
        #expect(run.location == "new ".utf16.count)
        #expect(run.length == "café".utf16.count)
        #expect(mapped[.init(hunk: 0, line: deletion)] == nil)
    }

    @Test func omittedLinesAndSeparateHunksNeverShareLexerState() {
        let lines = [
            WorkspaceDiffLine(type: .context, content: "/*\n", oldNumber: 1, newNumber: 1),
            WorkspaceDiffLine(type: .addition, content: "inside\n", oldNumber: nil, newNumber: 2),
            WorkspaceDiffLine(type: .addition, content: "after gap\n", oldNumber: nil, newNumber: Fixture.gapLine)
        ]
        let hunk = WorkspaceDiffHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: Fixture.newLines, lines: lines)
        let sources = WorkspaceDiffPresentation(hunks: [hunk, hunk]).sources()
        #expect(sources.map(\.text) == ["/*\n", "/*\ninside\n", "after gap\n", "/*\n", "/*\ninside\n", "after gap\n"])
        #expect(sources[1].mappings.first?.row == .init(hunk: 0, line: 0))
        #expect(sources[Fixture.repeatedNewSource].mappings.first?.row == .init(hunk: 1, line: 0))
    }

    @Test func cancellationDiscardsEarlierSideAndLateTokenizerResult() async throws {
        let hunks = try WorkspaceDiffBuilder.hunks(old: "old\n", new: "new\n")
        let presentation = WorkspaceDiffPresentation(hunks: hunks)
        var calls = 0
        let task = Task { @MainActor in
            await WorkspaceDiffSyntax.highlight(presentation, path: "file.swift", dark: false) { source, _, _ in
                calls += 1
                if calls == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                return [FileSyntaxRun(location: 0, length: source.utf16.count, color: "#123456")]
            }
        }
        let result = await task.value
        #expect(calls == 2)
        #expect(result.isEmpty)
    }

    @Test func emptyResultsAndOverBudgetDiffsStayPlain() async throws {
        let hunks = try WorkspaceDiffBuilder.hunks(old: "old\n", new: "new\n")
        let presentation = WorkspaceDiffPresentation(hunks: hunks)
        var paths: [String] = []
        let result = await WorkspaceDiffSyntax.highlight(presentation, path: "unknown.file", dark: true) { _, path, dark in
            paths.append(path)
            #expect(dark)
            return []
        }
        #expect(result.isEmpty)
        #expect(paths == ["unknown.file", "unknown.file"])
        let huge = WorkspaceDiffPresentation(
            hunks: hunks, oldSource: "old\n", newSource: String(repeating: "x", count: FileSyntaxHighlighter.maxBytes)
        )
        let overBudget = await WorkspaceDiffSyntax.highlight(huge, path: "file.swift", dark: false) { _, _, _ in
            Issue.record("Oversized diff must not call the tokenizer")
            return []
        }
        #expect(overBudget.isEmpty)
    }

    @Test func bundledEngineColorsBothSidesAsMultilineCommentsInBothThemes() async throws {
        let old = "/*\nlet old = 1\n*/\n"
        let new = "/*\nlet new = 2\n*/\n"
        let hunks = try WorkspaceDiffBuilder.hunks(old: old, new: new)
        let presentation = WorkspaceDiffPresentation(hunks: hunks)
        let deletion = try #require(hunks[0].lines.firstIndex { $0.type == .deletion })
        let addition = try #require(hunks[0].lines.firstIndex { $0.type == .addition })
        var colors: [String] = []
        for dark in [false, true] {
            let result = await WorkspaceDiffSyntax.highlight(presentation, path: "File.swift", dark: dark)
            let oldRun = try #require(result[.init(hunk: 0, line: deletion)]?.first)
            let newRun = try #require(result[.init(hunk: 0, line: addition)]?.first)
            let contextRun = try #require(result[.init(hunk: 0, line: 0)]?.first)
            #expect(oldRun.color == contextRun.color)
            #expect(newRun.color == contextRun.color)
            colors.append(newRun.color)
        }
        #expect(colors.first != colors.last)
    }
}
