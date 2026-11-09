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
    /// `MessageCopyContextMenu` row, with the exact number of unmarked
    /// Buttons each holds, so a new Button in one of them still fails.
    private static let rowlessFiles: [String: (buttons: Int, reason: String)] = [
        "Transcript/ConversationColumnView.swift": (1, "DEBUG demo cover button in the column, outside the transcript rows."),
        "Transcript/ConversationTranscriptView+History.swift": (1, "History retry row has no copy menu."),
        "Transcript/ConversationTranscriptView+Presentation.swift": (3, "Go to End and suggested prompts render beside the rows."),
        "Transcript/WorkspaceConversationHeader.swift": (1, "Header above the transcript."),
        "Content/ChatImageActions.swift": (2, "Image Save/Copy items render only inside menus."),
        "Content/HTMLLinkPreviewView.swift": (2, "Full-screen preview presented from a row."),
        "Content/ImageLightboxView.swift": (7, "Full-screen lightbox presented from a row."),
        "Content/PDFLightboxView.swift": (1, "Full-screen lightbox presented from a row."),
        "Content/PDFLinkPreviewView.swift": (2, "Full-screen preview presented from a row."),
        "Content/TextLinkPreviewView.swift": (1, "Full-screen preview presented from a row."),
        "Content/VideoLightboxView.swift": (1, "Full-screen lightbox presented from a row.")
    ]

    /// Scans of every Swift file under the scanned directories, keyed relative
    /// to `conversationRoot`.
    private func scansByFile() throws -> [String: CopyContextMenuButtonScanner.Scan] {
        let root = try TestSourceInputs.url(for: Self.conversationRoot)
        let rootPrefix = root.standardizedFileURL.path + "/"
        var result: [String: CopyContextMenuButtonScanner.Scan] = [:]
        for directory in Self.scannedDirectories {
            let url = root.appendingPathComponent(directory)
            let enumerator = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil))
            var scannedFiles = 0
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                result[String(file.standardizedFileURL.path.dropFirst(rootPrefix.count))] = CopyContextMenuButtonScanner.scan(source)
                scannedFiles += 1
            }
            try #require(scannedFiles > 0, "No Swift sources under \(directory); check the packaged inputs.")
        }
        return result
    }

    @Test func transcriptRowButtonsApplyPassthroughMarker() throws {
        let scans = try scansByFile()
        let misread = scans.filter { !$0.value.isReliable }.keys.sorted()
        #expect(misread.isEmpty, "The scanner misread these files; teach CopyContextMenuButtonScanner the construct: \(misread)")

        let violations = scans
            .filter { Self.rowlessFiles[$0.key] == nil }
            .flatMap { file, scan in scan.findings.sorted().map { "\(file):\($0.line): \($0.source)" } }
            .sorted()
        #expect(
            violations.isEmpty,
            """
            Buttons without copyContextMenuPassthrough() under \(Self.conversationRoot):
            \(violations.joined(separator: "\n"))
            The transcript row's copy overlay swallows their taps. Apply .copyContextMenuPassthrough() \
            inside the Button's label (not on the Button or its action); give title-only Buttons a label. \
            If the Button never renders inside a MessageCopyContextMenu row, list its file in rowlessFiles.
            """
        )
        let mismatched = Self.rowlessFiles.compactMap { file, entry -> String? in
            let actual = scans[file]?.findings.count ?? 0
            return actual == entry.buttons ? nil : "\(file): expected \(entry.buttons), found \(actual)"
        }
        .sorted()
        #expect(
            mismatched.isEmpty,
            """
            rowlessFiles counts are out of date: \(mismatched).
            Mark new row Buttons; update the count only for Buttons that never render in a row.
            """
        )
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
            .filter { $0.element.range(of: #"(?<![\w.])Button\s*[({]"#, options: .regularExpression) != nil }
            .map { $0.offset + 1 }
        #expect(!buttonLines.isEmpty)
        #expect(lines == buttonLines)
    }

    @Test(arguments: [
        ("Button(\"Go\") { go() }", 1),
        ("Button(action: go) { Text(\"Go\") }", 1),
        ("Button {\n  go()\n} label: {\n  Text(\"Go\")\n}", 1),
        ("Button(role: .destructive) { go() } label: { Text(\"Go\") }", 1),
        ("Button(\"Go\") { x.copyContextMenuPassthrough() }", 1),
        ("Button { x.copyContextMenuPassthrough() } label: { Text(\"Go\") }", 1),
        ("Button { go() } label: { Text(\"Go\").copyContextMenuPassthrough() }", 0),
        ("Button(action: go) {\n  Text(\"Go\")\n    .copyContextMenuPassthrough()\n}", 0),
        ("Button(action: go, label: { Text(\"Go\").copyContextMenuPassthrough() })", 0),
        ("Button(action: { _ = Text(\"Hidden\").copyContextMenuPassthrough() }, label: { Text(\"Go\") })", 1),
        ("Button(action: { go(label: x.copyContextMenuPassthrough()) }) { Text(\"Go\") }", 1),
        ("SwiftUI.Button(\"Go\") { go() }", 1),
        ("SwiftUI.Button { go() } label: { Text(\"Go\").copyContextMenuPassthrough() }", 0),
        ("Other.Button(\"Go\") { go() }", 0)
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

    @Test func nestedButtonMarkerDoesNotCountForOuterButton() {
        let source = """
        Button { go() } label: {
            HStack {
                Button { inner() } label: { Text("Inner").copyContextMenuPassthrough() }
                Text("Outer")
            }
        }
        """
        #expect(CopyContextMenuButtonScanner.unmarkedButtons(in: source).map(\.line) == [1])
    }

    @Test func helperCountsOnlyWhenEveryDeclarationOfItsNameIsMarked() {
        let source = """
        struct ToolRow: View {
            var body: some View { Button { toggle() } label: { header } }
            private var header: some View { Text("Tool") }
        }
        struct NoteRow: View {
            var body: some View { Button { open() } label: { header } }
            private var header: some View { Text("Note").copyContextMenuPassthrough() }
        }
        """
        #expect(CopyContextMenuButtonScanner.unmarkedButtons(in: source).map(\.line) == [2, 6])
    }

    @Test func regexLiteralsAreBlanked() {
        let source = #"""
        let pattern = /"(/
        let extended = #/ "{ /#
        let ratio = width / 2 / scale
        Button("Go") { go() }
        """#
        let scan = CopyContextMenuButtonScanner.scan(source)
        #expect(scan.isReliable)
        #expect(scan.findings.map(\.line) == [4])
    }

    @Test func misreadSourcesAreReported() {
        #expect(CopyContextMenuButtonScanner.scan("Button { go() } label: { Text(\"Go\") }").isReliable)
        #expect(!CopyContextMenuButtonScanner.scan("Text(\"Go)\nButton(\"Go\") { go() }").isReliable)
        #expect(!CopyContextMenuButtonScanner.scan("VStack { Text(\"Go\"] }").isReliable)
        #expect(!CopyContextMenuButtonScanner.scan("/* Button(\"Go\") { go() }").isReliable)
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
