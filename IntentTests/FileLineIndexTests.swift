import Foundation
@testable import Intent
import Testing
import UIKit

struct FileLineIndexTests {
    @Test func indexesSourceLinesAndUTF16Offsets() {
        let index = FileLineIndex("👋 café\r\n\r\nlast\rnext\n")
        #expect(index.starts == [0, 9, 11, 16, 21])
        #expect(index.line(at: 8) == 1)
        #expect(index.line(at: 9) == 2)
        #expect(index.line(at: 15) == 3)
        #expect(index.line(at: 21) == 5)
    }

    @Test func handlesEmptyAndUnterminatedFiles() {
        #expect(FileLineIndex("").starts == [0])
        #expect(FileLineIndex("first\nlast").starts == [0, 6])
        #expect(FileLineIndex("\n\n").starts == [0, 1, 2])
        #expect(FileLineIndex("a\u{2028}b\u{2029}c").starts == [0, 2, 4])
    }

    @MainActor
    @Test func wrappingAndScrollingKeepLogicalNumbersAndOriginalText() throws {
        let view = LineNumberTextView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        view.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        view.isEditable = false
        let source = String(repeating: "// a wrapped source line with 👋 and more words\r\n", count: 100)
        view.setSource(source)
        view.layoutIfNeeded()
        try #require(view.textLayoutManager != nil)
        let first = view.visibleLineLabels()
        #expect(first.first?.number == 1)
        #expect(first.count == Set(first.map(\.number)).count)
        try #require(first.count > 1)
        #expect(first[1].baseline - first[0].baseline > (view.font?.lineHeight ?? 0) * 1.5)
        let selection = NSRange(location: 3, length: 12)
        view.selectedRange = selection
        view.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        view.layoutIfNeeded()
        let scrolled = view.visibleLineLabels()
        #expect((scrolled.first?.number ?? 0) > 1)
        #expect(view.selectedRange == selection)
        #expect(view.text == source)
        #expect(view.textStorage.string == source)
    }

    @MainActor
    @Test func emptyAndTrailingLinesHaveNumbers() {
        let view = LineNumberTextView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        view.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        for (source, expected) in [("", [1]), ("let value = 1\n", [1, 2]), ("\n\n", [1, 2, 3])] {
            view.setSource(source)
            view.layoutIfNeeded()
            #expect(view.visibleLineLabels().map(\.number) == expected)
        }
    }
}
