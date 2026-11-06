@testable import Intent
import SwiftUI
import Testing

@MainActor
struct WorkspaceDiffRowsTests {
    private func line(_ content: String, _ number: Int) -> WorkspaceDiffLine {
        WorkspaceDiffLine(type: .addition, content: content, oldNumber: nil, newNumber: number)
    }

    private func hunk(_ lines: [WorkspaceDiffLine]) -> WorkspaceDiffHunk {
        WorkspaceDiffHunk(oldStart: 1, oldLines: 0, newStart: 1, newLines: lines.count, lines: lines)
    }

    @Test func rowsKeepHunkAndLineIDsInOrder() {
        let rows = WorkspaceDiffRows(hunks: [hunk([line("a", 1), line("b", 2)]), hunk([line("c", 9)])])
        #expect(rows.lineCount == 3)
        #expect(rows.rows.map(\.id) == [
            .heading(0), .line(.init(hunk: 0, line: 0)), .line(.init(hunk: 0, line: 1)),
            .heading(1), .line(.init(hunk: 1, line: 0))
        ])
        #expect(Set(rows.rows.map(\.id)).count == rows.rows.count)
    }

    @Test func limitCountsLinesNotHeadings() {
        let rows = WorkspaceDiffRows(hunks: [hunk([line("a", 1), line("b", 2)]), hunk([line("c", 9), line("d", 10)])])
        #expect(rows.rows(limit: 3).map(\.id).last == .line(.init(hunk: 1, line: 0)))
        #expect(rows.rows(limit: 3).count == 5)
        #expect(rows.rows(limit: 2).map(\.id).last == .line(.init(hunk: 0, line: 1)))
        #expect(rows.rows(limit: 4).count == rows.rows.count)
        #expect(rows.rows(limit: 40).count == rows.rows.count)
        #expect(rows.rows(limit: nil).count == rows.rows.count)
    }

    @Test func columnsExpandTabsAndCountNonASCIITwice() {
        #expect(WorkspaceDiffRows.columns("abc") == 3)
        #expect(WorkspaceDiffRows.columns("\tx") == 5)
        #expect(WorkspaceDiffRows.columns("ab\tx") == 5)
        #expect(WorkspaceDiffRows.columns("漢字") == 4)
        #expect(WorkspaceDiffRows.columns("👋") == 2)
        #expect(WorkspaceDiffRows.columns("e\u{301}") == 1)
        #expect(WorkspaceDiffRows.columns("é") == 2)
    }

    @Test func widestLinesShortlistByColumnsAndContentWidthCoversTheWidest() {
        let contents = ["a", "bb", "漢字漢字漢字", "tenletters", "ccc", "dddd", "elevenchars"]
        let rows = WorkspaceDiffRows(hunks: [hunk(contents.enumerated().map { line($1, $0 + 1) })])
        #expect(rows.widestLines == ["漢字漢字漢字", "elevenchars", "tenletters", "dddd"])
        let font = WorkspaceDiffRows.font(for: .large)
        let widest = contents.map { WorkspaceDiffRows.textWidth($0, font: font) }.max() ?? 0
        let width = rows.contentWidth(font: font)
        #expect(width >= widest + WorkspaceChangesLayout.lineNumberWidth * 2 + WorkspaceDiffRows.horizontalPadding * 2)
        #expect(WorkspaceDiffRows.font(for: .accessibility3).pointSize > font.pointSize)
    }

    #if DEBUG
    @Test func largeDiffFixtureFlagParsesPositiveCounts() {
        #expect(DemoChangesFixtures.largeDiffLineCount(from: ["--demo-large-diff=2000"]) == 2000)
        #expect(DemoChangesFixtures.largeDiffLineCount(from: ["--demo-large-diff=0"]) == nil)
        #expect(DemoChangesFixtures.largeDiffLineCount(from: ["--demo-data"]) == nil)
    }
    #endif
}
