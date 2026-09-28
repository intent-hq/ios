@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
struct ComposerDraftBindingTests {
    @Test(arguments: [false, true], [DynamicTypeSize.large, .accessibility5])
    func editsReachTheDraftBeforeAnotherRender(workspaceDesign: Bool, category: DynamicTypeSize) async throws {
        let model = makeModel()
        let prefix = "An accessible draft"
        model.messageText = prefix
        let view = MessageInputView(viewModel: model, store: model.store, usesWorkspaceDesign: workspaceDesign)
            .environment(\.dynamicTypeSize, category)
        try await SyntheticBadgeHost.render(view, width: 390, height: 250) { root, _ in
            let editor = try #require(textView(in: root))
            #expect(editor.text == prefix)
            editor.selectedRange = NSRange(location: prefix.utf16.count, length: 0)

            // Deliver an input burst without allowing SwiftUI's deferred change
            // callbacks to run between edits. The model must own every edit now,
            // so a later render cannot echo an older draft into the editor.
            for part in [" with e", "nough text to wrap onto multiple lines"] {
                editor.insertText(part)
                #expect(model.messageText == editor.text)
            }
            #expect(model.messageText == "An accessible draft with enough text to wrap onto multiple lines")

            editor.selectedRange = NSRange(location: prefix.utf16.count, length: " with e".utf16.count)
            editor.insertText(" WITH E")
            #expect(model.messageText == "An accessible draft WITH Enough text to wrap onto multiple lines")
            #expect(editor.selectedRange == NSRange(location: "An accessible draft WITH E".utf16.count, length: 0))
        }
    }

    @Test
    func queuedRenderCannotOverwriteAnEditReceivedBeforeItRuns() async {
        let model = makeModel()
        model.messageText = "An accessible draf"
        let adapter = SubmittableTextView(
            text: Binding(get: { model.messageText }, set: { model.messageText = $0 }),
            isFocused: .constant(false),
            onSubmit: {}
        )
        let coordinator = adapter.makeCoordinator()
        let editor = KeyCommandTextView()
        editor.delegate = coordinator
        editor.text = model.messageText
        editor.selectedRange = NSRange(location: model.messageText.utf16.count, length: 0)

        coordinator.synchronizeText(in: editor)
        editor.insertText("t")
        let selection = editor.selectedRange
        await drainMainQueue()
        #expect(editor.text == "An accessible draft")
        #expect(model.messageText == "An accessible draft")
        #expect(editor.selectedRange == selection)
        editor.insertText(" with enough text to wrap onto multiple lines")
        #expect(editor.text == "An accessible draft with enough text to wrap onto multiple lines")
        #expect(model.messageText == editor.text)
    }

    @Test
    func externalDraftReplacementAndClearingReachTheEditor() async {
        let model = makeModel()
        model.messageText = "Restored draft"
        var heights: [CGFloat] = []
        let adapter = SubmittableTextView(
            text: Binding(get: { model.messageText }, set: { model.messageText = $0 }),
            isFocused: .constant(false),
            onSubmit: {},
            onHeightChange: { heights.append($0) }
        )
        let coordinator = adapter.makeCoordinator()
        let editor = KeyCommandTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        editor.delegate = coordinator
        editor.text = model.messageText
        coordinator.synchronizeText(in: editor)
        model.messageText = "Recovered after a failed send"
        await drainMainQueue()
        #expect(editor.text == "Recovered after a failed send")
        #expect(!heights.isEmpty)
        model.messageText = ""
        coordinator.synchronizeText(in: editor)
        await drainMainQueue()
        #expect(editor.text.isEmpty)
        editor.insertText("Next draft")
        #expect(model.messageText == "Next draft")
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func makeModel() -> ConversationViewModel {
        let connection = FakeConnectionManager()
        return ConversationViewModel(
            agentId: UUID().uuidString,
            workspaceId: UUID().uuidString,
            agentName: "Composer regression",
            connection: connection,
            uploadService: AttachmentUploadService(connection: connection),
            optionsStore: CreationOptionsStore(connectionManager: connection)
        )
    }

    private func textView(in view: UIView) -> KeyCommandTextView? {
        if let editor = view as? KeyCommandTextView { return editor }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

}
