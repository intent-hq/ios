import Foundation
@testable import Intent
import Testing
import UIKit

@MainActor
struct FileSyntaxHighlighterTests {
    @Test func bundledEngineHighlightsSwiftInBothThemes() async throws {
        _ = try #require(FileSyntaxHighlighter.pageURL)
        let source = "// café 👋\r\nlet greeting = \"Hello\"\r\nlet count = 42\n"
        let engine = FileSyntaxHighlighter()
        let light = await engine.highlight(source: source, path: "Greeting.swift", dark: false)
        let dark = await engine.highlight(source: source, path: "Greeting.swift", dark: true)
        try #require(!light.isEmpty)
        try #require(!dark.isEmpty)
        #expect(light.map(\.color) != dark.map(\.color))
        #expect(light.contains { run in
            guard let range = Range(run.range, in: source) else { return false }
            return source[range].contains("Hello")
        })
        #expect(Set(light.map(\.color)).count > 1)
    }

    @Test func unsupportedAndOverBudgetFilesStayPlain() async {
        let engine = FileSyntaxHighlighter()
        let unknown = await engine.highlight(source: "let count = 42", path: "data.unrecognized", dark: false)
        #expect(unknown.isEmpty)
        let large = String(repeating: "a", count: FileSyntaxHighlighter.maxBytes + 1)
        let overBudget = await engine.highlight(source: large, path: "large.swift", dark: false)
        #expect(overBudget.isEmpty)
    }

    @Test func cancelledRequestReturnsWithoutApplyingColors() async {
        let task = Task { @MainActor in
            await FileSyntaxHighlighter().highlight(source: "let count = 42", path: "test.swift", dark: false)
        }
        task.cancel()
        let runs = await task.value
        #expect(runs.isEmpty)
    }

    @Test func rejectsMalformedAndOutOfBoundsRanges() {
        let source = "let count = 42"
        for json in [
            "{}",
            ##"{"runs":[{"location":-1,"length":3,"color":"#ff0000"}]}"##,
            ##"{"runs":[{"location":0,"length":99,"color":"#ff0000"}]}"##,
            ##"{"runs":[{"location":0,"length":3,"color":"invalid"}]}"##,
            ##"{"runs":[{"location":0,"length":3,"color":"#ff0000"},{"location":2,"length":1,"color":"#00ff00"}]}"##
        ] {
            #expect(FileSyntaxRun.decode(json, source: source).isEmpty)
        }
    }

    @Test func colorsPreserveTextSelectionFontAndScroll() {
        let view = UITextView(usingTextLayoutManager: true)
        let source = "let greeting = \"👋 café\"\r\n" + String(repeating: "// another line\n", count: 100)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        view.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        view.text = source
        view.layoutIfNeeded()
        let selection = NSRange(location: 4, length: 8)
        view.selectedRange = selection
        view.setContentOffset(CGPoint(x: 0, y: 100), animated: false)
        let offset = view.contentOffset
        let font = view.font
        let runs = FileSyntaxRun.decode(
            ##"{"runs":[{"location":0,"length":3,"color":"#ff0000"}]}"##, source: source
        )
        WorkspaceTextFileView.Coordinator.apply(runs, to: view)
        #expect(view.text == source)
        #expect(view.selectedRange == selection)
        #expect(view.contentOffset == offset)
        #expect(view.font == font)
        #expect(view.textLayoutManager != nil)
        #expect(view.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == runs.first?.uiColor)
        WorkspaceTextFileView.Coordinator.apply([], to: view)
        #expect(view.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == .label)
    }
}
