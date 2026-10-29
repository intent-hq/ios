@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
struct WorkspaceTextFileViewTests {
    @Test(arguments: ["swift", "py", "json"])
    func highlightsPreserveNativeTextBehavior(fileExtension: String) async throws {
        let sample: (text: String, markers: [String])
        switch fileExtension {
        case "py": sample = ("# A comment\nif True:\n    name = \"Intent\"\n    count = 42\n", ["#", "if", "\"Intent\"", "42"])
        case "json": sample = ("{\"name\": \"Intent\", \"count\": 42}\n", ["\"Intent\"", "42"])
        default: sample = ("// A comment\nlet name = \"Intent\"\nlet count = 42\n", ["//", "let", "\"Intent\"", "42"])
        }
        let file = try await makeFile(String(repeating: sample.text, count: 80), path: "source.\(fileExtension)")
        let host = Host(file: file)
        defer { host.close() }
        let view = try #require(host.textView)
        #expect(view.text == file.content)
        #expect(view.textLayoutManager != nil)
        #expect(view.isSelectable && view.isScrollEnabled && !view.isEditable)
        #expect(view.adjustsFontForContentSizeCategory)
        let originalFont = try #require(view.font)
        #expect(originalFont.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        #expect(color(in: view, at: sample.markers[0]) == .label)
        let selection = NSRange(location: 4, length: 6)
        view.selectedRange = selection
        view.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        let offset = view.contentOffset
        try await waitUntil("syntax colors applied") {
            sample.markers.allSatisfy { marker in
                guard let color = color(in: view, at: marker) else { return false }
                return color != .label
            }
        }
        #expect(view.text == file.content)
        #expect(view.selectedRange == selection)
        #expect(view.contentOffset == offset)
        #expect(view.textLayoutManager != nil)
        for marker in sample.markers {
            let tokenColor = try #require(color(in: view, at: marker))
            #expect(tokenColor.resolvedColor(with: .init(userInterfaceStyle: .light)) !=
                tokenColor.resolvedColor(with: .init(userInterfaceStyle: .dark)))
        }
        assertUniformFont(view, expected: originalFont)
        host.window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        host.window.updateTraitsIfNeeded()
        view.layoutIfNeeded()
        try await waitUntil("SwiftUI forwards the text-size trait") {
            view.traitCollection.preferredContentSizeCategory == .accessibilityExtraExtraExtraLarge
        }
        try await waitUntil("Dynamic Type scales highlighted text") {
            (view.font?.pointSize ?? 0) > originalFont.pointSize
        }
        assertUniformFont(view, expected: try #require(view.font))
        #expect(sample.markers.allSatisfy { color(in: view, at: $0) != .label })
    }

    @Test(arguments: [false, true])
    func replacementStaysPlainForUnsupportedAndOversizedFiles(oversized: Bool) async throws {
        let source = try await makeFile("let number = 42", path: "source.swift")
        let content = oversized ? "let number = 42\n" + String(repeating: " ", count: WorkspaceSyntaxHighlighter.maxBytes) : "Plain text"
        let replacement = try await makeFile(content, path: oversized ? "large.swift" : "notes.unknown")
        let view = UITextView(usingTextLayoutManager: true)
        let coordinator = WorkspaceTextFileView.Coordinator()
        coordinator.display(source, in: view)
        coordinator.display(replacement, in: view)
        #expect(view.text == content)
        try await expectNever("stale colors on replacement") {
            color(in: view, at: String(content.prefix(1))) != .label
        }
        #expect(view.text == content)
    }

    @Test func replacingHighlightedFileClearsPreviousColors() async throws {
        let file = try await makeFile("let number = 42", path: "source.swift")
        let replacement = try await makeFile("let this remain plain", path: "notes.txt")
        let view = UITextView(usingTextLayoutManager: true)
        let coordinator = WorkspaceTextFileView.Coordinator()
        coordinator.display(file, in: view)
        try await waitUntil("initial highlight") { color(in: view, at: "let") != .label }
        coordinator.display(replacement, in: view)
        #expect(view.text == replacement.content)
        #expect(color(in: view, at: "let") == .label)
    }

    @Test func dismantlingPreventsPendingColorApplication() async throws {
        let file = try await makeFile("let number = 42", path: "source.swift")
        let view = UITextView(usingTextLayoutManager: true)
        let coordinator = WorkspaceTextFileView.Coordinator()
        coordinator.display(file, in: view)
        WorkspaceTextFileView.dismantleUIView(view, coordinator: coordinator)
        try await expectNever("colors after dismissal") { color(in: view, at: "let") != .label }
    }

    private func makeFile(_ text: String, path: String) async throws -> WorkspaceTextFile {
        try await WorkspaceTextFile.load(path: path) { handle in
            let data = Data(text.utf8)
            try handle.write(contentsOf: data)
            return data.count
        }
    }

    private func color(in view: UITextView, at text: String) -> UIColor? {
        guard let found = view.text.range(of: text) else { return nil }
        let range = NSRange(found, in: view.text)
        return view.textStorage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
    }

    private func assertUniformFont(_ view: UITextView, expected: UIFont) {
        view.textStorage.enumerateAttribute(.font, in: NSRange(location: 0, length: view.textStorage.length)) { font, _, _ in
            #expect(font as? UIFont == expected)
        }
    }

    private final class Host {
        let controller: UIHostingController<WorkspaceTextFileView>
        let window: UIWindow

        init(file: WorkspaceTextFile) {
            controller = UIHostingController(rootView: WorkspaceTextFileView(file: file))
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
            window.rootViewController = controller
            window.isHidden = false
            controller.view.layoutIfNeeded()
        }

        var textView: UITextView? { findTextView(in: controller.view) }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }

        private func findTextView(in view: UIView) -> UITextView? {
            if let textView = view as? UITextView { return textView }
            for subview in view.subviews {
                if let match = findTextView(in: subview) { return match }
            }
            return nil
        }
    }
}
