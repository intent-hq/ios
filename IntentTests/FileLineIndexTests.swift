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
    @Test func disablingWrapEnablesHorizontalScrollingWithoutChangingSourceOrSelection() throws {
        let view = LineNumberTextView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        view.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        view.isEditable = false
        let source = "let message = \"" + String(repeating: "café 👋 ", count: 20) + "\"\r\nlet next = 1\n"
        view.setSource(source)
        view.layoutIfNeeded()
        let selection = NSRange(location: 4, length: 7)
        view.selectedRange = selection
        view.textStorage.addAttribute(.foregroundColor, value: UIColor.systemGreen, range: selection)
        view.setWrapLines(false)
        view.layoutIfNeeded()
        try #require(view.textLayoutManager != nil)
        #expect(view.contentSize.width > view.bounds.width)
        #expect(view.contentSize.width < 10_000)
        let labels = view.visibleLineLabels()
        try #require(labels.count >= 2)
        #expect(abs(labels[1].baseline - labels[0].baseline - view.linePitch) < 2)
        view.setContentOffset(CGPoint(x: 200, y: 0), animated: false)
        view.layoutIfNeeded()
        #expect(view.visibleLineLabels().first?.number == 1)
        view.setWrapLines(true)
        view.layoutIfNeeded()
        #expect(view.contentOffset.x == 0)
        #expect(view.contentSize.width <= view.bounds.width + 1)
        #expect(view.selectedRange == selection)
        #expect(view.text == source)
        #expect(view.textStorage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? UIColor == .systemGreen)
    }

    @MainActor
    @Test func savedUnwrappedPreferenceAppliesBeforeTheFirstFrame() throws {
        let container = LineNumberTextContainer()
        let view = container.textView
        view.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        view.isEditable = false
        view.setSource(String(repeating: "long source line ", count: 20) + "\nnext line")
        view.setWrapLines(false)
        container.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        container.layoutIfNeeded()
        #expect(view.contentSize.width > view.bounds.width)
        let labels = view.visibleLineLabels()
        try #require(labels.count >= 2)
        #expect(abs(labels[1].baseline - labels[0].baseline - view.linePitch) < 2)
    }

    @MainActor
    @Test func togglingWrapKeepsTheVisibleSourceLine() throws {
        let view = LineNumberTextView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        view.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        view.isEditable = false
        view.setSource(String(repeating: "// a long source line with extra words that wraps on the phone\n", count: 100))
        view.layoutIfNeeded()
        view.setContentOffset(CGPoint(x: 0, y: 800), animated: false)
        view.layoutIfNeeded()
        var anchor = try #require(view.visibleLineLabels().first)
        for wraps in [false, true] {
            view.setWrapLines(wraps)
            view.layoutIfNeeded()
            let current = try #require(view.visibleLineLabels().first { $0.number == anchor.number })
            #expect(abs(current.baseline - anchor.baseline) < 1)
            anchor = try #require(view.visibleLineLabels().first)
        }
    }

    @MainActor
    @Test func hidingLineNumbersReclaimsWidthAndPreservesReadingPosition() throws {
        let container = LineNumberTextContainer()
        let view = container.textView
        view.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        view.isEditable = false
        let source = String(repeating: "// a long source line with 👋 and extra words for wrapping\r\n", count: 100)
        view.setSource(source)
        view.setShowLineNumbers(false)
        container.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        container.layoutIfNeeded()
        #expect(view.gutter.isHidden)
        #expect(view.textContainerInset.left == view.textContainerInset.right)
        let selection = NSRange(location: 3, length: 12)
        view.selectedRange = selection
        for wraps in [true, false] {
            view.setWrapLines(wraps)
            view.setContentOffset(CGPoint(x: wraps ? 0 : 100, y: 800), animated: false)
            view.layoutIfNeeded()
            let original = try #require(view.visibleLineLabels().first?.number)
            let textWidth = view.textContainer.size.width
            for show in [true, false] {
                view.setShowLineNumbers(show)
                #expect(view.gutter.isHidden == !show)
                #expect(abs(try #require(view.visibleLineLabels().first?.number) - original) <= 1)
                #expect(view.contentOffset.x == (wraps ? 0 : 100))
                #expect(view.selectedRange == selection)
                #expect(view.text == source)
                if wraps {
                    #expect(show ? view.textContainer.size.width < textWidth : view.textContainer.size.width == textWidth)
                }
            }
        }
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
