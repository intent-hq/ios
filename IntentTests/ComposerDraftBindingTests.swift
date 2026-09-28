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
    func externalDraftReplacementAndClearingReachTheEditor() async throws {
        let model = makeModel()
        model.messageText = "Restored draft"
        let controller = UIHostingController(rootView: MessageInputView(
            viewModel: model, store: model.store, usesWorkspaceDesign: true
        ))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitUntil { textView(in: controller.view)?.text == "Restored draft" }
        let editor = try #require(textView(in: controller.view))
        model.messageText = "Recovered after a failed send"
        try await waitUntil { editor.text == model.messageText }
        #expect(editor.text == "Recovered after a failed send")
        model.messageText = ""
        try await waitUntil { editor.text.isEmpty }
        #expect(editor.text.isEmpty)
        editor.insertText("Next draft")
        #expect(model.messageText == "Next draft")
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

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "The composer did not display the latest draft")
    }
}
