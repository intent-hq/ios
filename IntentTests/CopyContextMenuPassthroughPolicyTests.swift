import Foundation
import Testing

/// Every Button that renders inside a transcript row must apply
/// `copyContextMenuPassthrough()` to its label, or the row's long-press Copy
/// overlay claims the tap and the Button silently does nothing. Missing
/// markers shipped three times: tool rows (ios#344, ios#369), image taps
/// (ios#212), and the agent-message card (ios#982).
///
/// The overlay cannot pass SwiftUI Buttons through by itself. A SwiftUI
/// Button has no UIKit view, so the overlay's hit-test probe resolves to the
/// same shared hosting view for a Button as for plain text. Only a UIKit view
/// in the Button's label (the marker) makes the two distinguishable, so this
/// scan is the guard. See `CopyContextMenuButtonScanner` for the rules.
struct CopyContextMenuPassthroughPolicyTests {
    private static let conversationRoot = "Intent/Views/Conversation"
    private static let scannedDirectories = ["Transcript", "Notices", "Content"]

    /// Scanned files whose Buttons never render inside a
    /// `MessageCopyContextMenu` row. Every entry must still contain an
    /// unmarked Button; remove it when it no longer does.
    private static let rowlessFiles: [String: String] = [
        "Transcript/ConversationColumnView.swift": "DEBUG demo cover button in the column, outside the transcript rows.",
        "Transcript/ConversationTranscriptView+History.swift": "History retry row has no copy menu.",
        "Transcript/ConversationTranscriptView+Presentation.swift": "Go to End and suggested prompts render beside the rows.",
        "Transcript/WorkspaceConversationHeader.swift": "Header above the transcript.",
        "Content/ChatImageActions.swift": "Image Save/Copy items render only inside menus.",
        "Content/HTMLLinkPreviewView.swift": "Full-screen preview presented from a row.",
        "Content/ImageLightboxView.swift": "Full-screen lightbox presented from a row.",
        "Content/PDFLightboxView.swift": "Full-screen lightbox presented from a row.",
        "Content/PDFLinkPreviewView.swift": "Full-screen preview presented from a row.",
        "Content/TextLinkPreviewView.swift": "Full-screen preview presented from a row.",
        "Content/VideoLightboxView.swift": "Full-screen lightbox presented from a row."
    ]

    /// Unmarked Buttons per scanned file, keyed relative to `conversationRoot`.
    private func unmarkedButtonsByFile() throws -> [String: [CopyContextMenuButtonScanner.Finding]] {
        var result: [String: [CopyContextMenuButtonScanner.Finding]] = [:]
        for directory in Self.scannedDirectories {
            let url = try TestSourceInputs.url(for: "\(Self.conversationRoot)/\(directory)")
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".swift") }
            try #require(!names.isEmpty, "No Swift sources under \(directory); check the packaged inputs.")
            for name in names {
                let source = try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
                let findings = CopyContextMenuButtonScanner.unmarkedButtons(in: source)
                if !findings.isEmpty { result["\(directory)/\(name)"] = findings }
            }
        }
        return result
    }

    @Test func transcriptRowButtonsApplyPassthroughMarker() throws {
        let findings = try unmarkedButtonsByFile()
        let violations = findings
            .filter { Self.rowlessFiles[$0.key] == nil }
            .flatMap { file, buttons in buttons.sorted().map { "\(file):\($0.line): \($0.source)" } }
            .sorted()
        #expect(
            violations.isEmpty,
            """
            Buttons without copyContextMenuPassthrough() under \(Self.conversationRoot):
            \(violations.joined(separator: "\n"))
            The transcript row's copy overlay swallows their taps. Apply .copyContextMenuPassthrough() \
            inside the Button's label (not on the Button). If the Button never renders inside a \
            MessageCopyContextMenu row, add its file to rowlessFiles with a reason.
            """
        )
        let staleEntries = Self.rowlessFiles.keys.filter { findings[$0] == nil }.sorted()
        #expect(staleEntries.isEmpty, "rowlessFiles entries without unmarked Buttons; remove them: \(staleEntries)")
    }

    /// ios#982 regression: the agent-message card's buttons lose their marker.
    @Test func scanFlagsAgentMessageAttributionWithoutMarkers() throws {
        let url = try TestSourceInputs.url(for: "\(Self.conversationRoot)/Notices/AgentMessageAttributionView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(CopyContextMenuButtonScanner.unmarkedButtons(in: source).isEmpty)

        let stripped = source.replacingOccurrences(of: ".\(CopyContextMenuButtonScanner.marker)()", with: "")
        try #require(stripped != source, "AgentMessageAttributionView no longer applies the marker inline.")
        let lines = CopyContextMenuButtonScanner.unmarkedButtons(in: stripped).map(\.line)
        let buttonLines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { $0.element.contains("Button(") || $0.element.contains("Button {") }
            .map { $0.offset + 1 }
        #expect(!buttonLines.isEmpty)
        #expect(lines == buttonLines)
    }

    @Test(arguments: [
        ("Button(\"Go\") { go() }", 1),
        ("Button(action: go) { Text(\"Go\") }", 1),
        ("Button {\n  go()\n} label: {\n  Text(\"Go\")\n}", 1),
        ("Button(role: .destructive) { go() } label: { Text(\"Go\") }", 1),
        ("Button { go() } label: { Text(\"Go\").copyContextMenuPassthrough() }", 0),
        ("Button(action: go) {\n  Text(\"Go\")\n    .copyContextMenuPassthrough()\n}", 0)
    ])
    func scanChecksButtonCallForms(source: String, expectedFindings: Int) {
        #expect(CopyContextMenuButtonScanner.unmarkedButtons(in: source).count == expectedFindings)
    }

    @Test func markerOnButtonModifierChainDoesNotCount() {
        let source = "Button { go() } label: { Text(\"Go\") }\n    .copyContextMenuPassthrough()"
        #expect(CopyContextMenuButtonScanner.unmarkedButtons(in: source).map(\.line) == [1])
    }

    @Test func markerThroughSameFileHelpersCounts() {
        let source = """
        struct Row: View {
            var body: some View {
                Button(action: go) { label("Go") }
                Button(action: go) { header }
                Button(action: go) { ChipLabel() }
                Button(action: go) { plain }
            }
            private func label(_ title: String) -> some View { styled(Text(title)) }
            private func styled(_ text: Text) -> some View { text.copyContextMenuPassthrough() }
            private var header: some View {
                Text("Header")
                    .copyContextMenuPassthrough()
            }
            private var plain: some View { Text("Plain") }
            private var isExpanded = false
        }
        struct ChipLabel: View {
            var body: some View { Text("Chip").copyContextMenuPassthrough() }
        }
        """
        #expect(CopyContextMenuButtonScanner.unmarkedButtons(in: source).map(\.line) == [6])
    }

    @Test func helperNameAsArgumentLabelOrMemberDoesNotCount() {
        let source = """
        struct Row: View {
            var body: some View {
                Button { go() } label: { Text("Go").font(.title) }
            }
            private var label: some View { Text("A").copyContextMenuPassthrough() }
            private var title: some View { Text("B").copyContextMenuPassthrough() }
        }
        """
        #expect(CopyContextMenuButtonScanner.unmarkedButtons(in: source).map(\.line) == [3])
    }

    @Test func buttonsOutsideTheRowHierarchyAreSkipped() {
        let source = """
        struct Row: View {
            var body: some View {
                Text("Row")
                    .contextMenu { Button("Copy") { copy() } }
                    .contextMenu(menuItems: { Button("Share") { share() } })
                    .alert("Failed", isPresented: $failed) { Button("OK", role: .cancel) {} }
                    .alert("Failed", isPresented: $failed, actions: { Button("OK") {} })
                    .confirmationDialog("Delete?", isPresented: $confirming) { Button("Delete") { delete() } }
                    .toolbar { ToolbarItem(placement: .primaryAction) { Button("Done") { done() } } }
                    .sheet(isPresented: $presented) { Button("Close") { close() } }
                    .fullScreenCover(item: $item) { _ in Button("Close") { close() } }
                    .navigationDestination(isPresented: $pushed) { Button("Back") { back() } }
                Menu { Button("Rename") { rename() } } label: { Text("More") }
                if showsRetry { Button("Retry") { retry() } }
            }
        }
        #Preview { Button("Preview") {} }
        """
        #expect(CopyContextMenuButtonScanner.unmarkedButtons(in: source).map(\.line) == [14])
    }

    @Test func commentsStringsAndOtherIdentifiersAreIgnored() {
        let source = #"""
        // Button("Commented") { go() }
        /* Button { go() } /* nested */ Button { go() } */
        let text = "Button(\"Quoted\") { go() } \(value(of: "Button { }"))"
        let raw = #"Button("Raw") { go() }"#
        let block = """
            Button { go() }
            """
        IntentIconButton(icon: .close, label: "Done") { dismiss() }
        goToEndButton(proxy: proxy)
        Text("Go").buttonStyle(IntentContentButtonStyle())
        Button("Real") { go() }
        """#
        #expect(CopyContextMenuButtonScanner.unmarkedButtons(in: source) == [
            CopyContextMenuButtonScanner.Finding(line: 11, source: #"Button("Real") { go() }"#)
        ])
    }
}
