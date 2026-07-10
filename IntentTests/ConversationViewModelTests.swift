import Foundation
import UIKit
import Testing
@testable import Intent

@MainActor
struct ConversationViewModelTests {

    // MARK: - Helpers

    private func makeVM() -> ConversationViewModel {
        ConversationViewModel(agentId: "test-agent", workspaceId: "test-ws", agentName: "Test")
    }

    private func textMessage(id: String = UUID().uuidString, role: MessageRole, text: String,
                             metadata: [String: AnyCodable]? = nil) -> ConversationMessage {
        ConversationMessage(
            id: id, role: role,
            contentBlocks: [ContentBlock(type: .text, text: text)],
            metadata: metadata
        )
    }

    // MARK: - filteredMessages

    @Test func filteredMessagesKeepsAssistantMessages() async {
        let vm = makeVM()
        vm.store.messages = [
            textMessage(role: .assistant, text: "Hello!"),
        ]
        #expect(vm.filteredMessages.count == 1)
        #expect(vm.filteredMessages[0].role == .assistant)
    }

    @Test func filteredMessagesKeepsNormalUserMessages() async {
        let vm = makeVM()
        vm.store.messages = [
            textMessage(role: .user, text: "Hi there"),
        ]
        #expect(vm.filteredMessages.count == 1)
    }

    @Test func filteredMessagesFiltersWorkspaceEvents() async {
        let vm = makeVM()
        vm.store.messages = [
            textMessage(role: .user, text: "[WORKSPACE EVENTS] something happened"),
        ]
        #expect(vm.filteredMessages.isEmpty)
    }

    @Test func filteredMessagesFiltersTaskWake() async {
        let vm = makeVM()
        vm.store.messages = [
            textMessage(role: .user, text: "[TASK WAKE] waking up"),
        ]
        #expect(vm.filteredMessages.isEmpty)
    }

    @Test func filteredMessagesFiltersAgentMessage() async {
        let vm = makeVM()
        vm.store.messages = [
            textMessage(role: .user, text: "[AGENT MESSAGE] from another agent"),
        ]
        #expect(vm.filteredMessages.isEmpty)
    }

    @Test func filteredMessagesFiltersEventNotificationMetadata() async {
        let vm = makeVM()
        vm.store.messages = [
            textMessage(role: .user, text: "event data",
                        metadata: ["type": AnyCodable("event_notification")]),
        ]
        #expect(vm.filteredMessages.isEmpty)
    }

    @Test func filteredMessagesHandlesEmptyList() async {
        let vm = makeVM()
        vm.store.messages = []
        #expect(vm.filteredMessages.isEmpty)
    }

    @Test func filteredMessagesMixedKeepsCorrectOnes() async {
        let vm = makeVM()
        vm.store.messages = [
            textMessage(role: .user, text: "Hello"),
            textMessage(role: .assistant, text: "Hi"),
            textMessage(role: .user, text: "[WORKSPACE EVENTS] x"),
            textMessage(role: .user, text: "[TASK WAKE] y"),
            textMessage(role: .assistant, text: "Done"),
        ]
        #expect(vm.filteredMessages.count == 3)
    }

    // MARK: - suggestedPrompts

    @Test func suggestedPromptsParsesSinglePrompt() async {
        let vm = makeVM()
        vm.store.messages = [
            textMessage(role: .assistant,
                        text: "Here you go\n<!-- suggested-prompts\nRun the tests\n-->"),
        ]
        #expect(vm.suggestedPrompts == ["Run the tests"])
    }

    @Test func suggestedPromptsMultiplePrompts() async {
        let vm = makeVM()
        vm.store.messages = [
            textMessage(role: .assistant,
                        text: "Done!\n<!-- suggested-prompts\nPrompt 1\nPrompt 2\nPrompt 3\n-->"),
        ]
        #expect(vm.suggestedPrompts == ["Prompt 1", "Prompt 2", "Prompt 3"])
    }

    @Test func suggestedPromptsEmptyWhenLastIsUser() async {
        let vm = makeVM()
        vm.store.messages = [
            textMessage(role: .assistant, text: "<!-- suggested-prompts\nA\n-->"),
            textMessage(role: .user, text: "thanks"),
        ]
        #expect(vm.suggestedPrompts.isEmpty)
    }

    @Test func suggestedPromptsEmptyWhenNoComment() async {
        let vm = makeVM()
        vm.store.messages = [
            textMessage(role: .assistant, text: "Just a normal message"),
        ]
        #expect(vm.suggestedPrompts.isEmpty)
    }

    @Test func suggestedPromptsTrimsWhitespace() async {
        let vm = makeVM()
        vm.store.messages = [
            textMessage(role: .assistant,
                        text: "<!-- suggested-prompts\n  Spaced prompt  \n-->"),
        ]
        #expect(vm.suggestedPrompts == ["Spaced prompt"])
    }

    @Test func suggestedPromptsIgnoresEmptyLines() async {
        let vm = makeVM()
        vm.store.messages = [
            textMessage(role: .assistant,
                        text: "<!-- suggested-prompts\nA\n\n\nB\n-->"),
        ]
        #expect(vm.suggestedPrompts == ["A", "B"])
    }

    @Test func suggestedPromptsEmptyWhenNoMessages() async {
        let vm = makeVM()
        #expect(vm.suggestedPrompts.isEmpty)
    }

    // MARK: - Image handling

    @Test func addImageAppendsToPendingImages() async {
        let vm = makeVM()
        let img = UIImage(systemName: "star")!
        vm.addImage(img)
        #expect(vm.pendingImages.count == 1)
        vm.addImage(img)
        #expect(vm.pendingImages.count == 2)
    }

    @Test func removeImageRemovesAtIndex() async {
        let vm = makeVM()
        let img1 = UIImage(systemName: "star")!
        let img2 = UIImage(systemName: "circle")!
        vm.addImage(img1)
        vm.addImage(img2)
        vm.removeImage(at: 0)
        #expect(vm.pendingImages.count == 1)
    }

    @Test func removeImageOutOfBoundsIsSafe() async {
        let vm = makeVM()
        let img = UIImage(systemName: "star")!
        vm.addImage(img)
        vm.removeImage(at: 5)
        #expect(vm.pendingImages.count == 1)
        vm.removeImage(at: -1)
        #expect(vm.pendingImages.count == 1)
    }

    // MARK: - Image attachment state regression tests

    @Test func regressionPendingImagesPopulatedBeforeClearing() async {
        // Regression test: verify that pendingImages contains data while images
        // are pending (buildImageBlocks captures from this before clearing)
        let vm = makeVM()
        let img1 = UIImage(systemName: "star")!
        let img2 = UIImage(systemName: "circle")!
        vm.addImage(img1)
        vm.addImage(img2)

        // Images should be available before any clearing
        #expect(vm.pendingImages.count == 2)
        #expect(!vm.pendingImages.isEmpty)
    }

    @Test func regressionClearingPendingImagesRemovesAll() async {
        // Regression test: after calling removeAll(), pendingImages should be empty
        let vm = makeVM()
        let img1 = UIImage(systemName: "star")!
        let img2 = UIImage(systemName: "circle")!
        vm.addImage(img1)
        vm.addImage(img2)
        #expect(vm.pendingImages.count == 2)

        vm.pendingImages.removeAll()
        #expect(vm.pendingImages.isEmpty)
        #expect(vm.pendingImages.count == 0)
    }

    @Test func regressionCaptureImagesThenClearBeforeSend() async {
        // Regression test: the send flow captures images into a local variable
        // and clears pendingImages BEFORE the async network call. This ensures
        // the UI immediately reflects the cleared state while the captured images
        // are still available for the send operation.
        // This mirrors the fix in MessageInputView.sendCurrentMessage().
        let vm = makeVM()
        let img1 = UIImage(systemName: "star")!
        let img2 = UIImage(systemName: "circle")!
        vm.addImage(img1)
        vm.addImage(img2)
        #expect(vm.pendingImages.count == 2)

        // Simulate the fixed send flow: capture images, then clear pendingImages
        let capturedImages = vm.pendingImages
        vm.pendingImages.removeAll()

        // pendingImages should be empty immediately (UI updates)
        #expect(vm.pendingImages.isEmpty)

        // But the captured images should still be available for the send call
        #expect(capturedImages.count == 2)

        // sendMessage with explicit images works even though pendingImages is empty
        // (will fail the network call since no server, but that's expected)
        await vm.sendMessage("test with images", images: capturedImages)

        // pendingImages should still be empty after the send completes/fails
        #expect(vm.pendingImages.isEmpty)
    }
}

