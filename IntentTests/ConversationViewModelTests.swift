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

    private func questionResourceBlock(
        attachmentId: String = "tar-0123456789ab",
        question: String = "Which auth method?"
    ) -> ContentBlock {
        let json = """
        {"attachmentId": "\(attachmentId)", "header": "Auth", \
        "question": "\(question)", \
        "options": [{"label": "OAuth"}, {"label": "API key"}]}
        """
        return ContentBlock(
            type: .resource,
            resource: ResourceContents(
                uri: "intent-question://q",
                mimeType: Question.resourceMimeType,
                text: json
            )
        )
    }

    private func questionMessage(
        id: String = "a1",
        extraBlocks: [ContentBlock] = []
    ) -> ConversationMessage {
        ConversationMessage(
            id: id, role: .assistant,
            contentBlocks: [questionResourceBlock()] + extraBlocks
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

    // MARK: - Agent Q&A pending questions (wizard glue)

    @Test func pendingQuestionsDerivedFromLastAssistant() throws {
        let vm = makeVM()
        vm.store.messages = [
            textMessage(role: .user, text: "hi"),
            questionMessage(id: "a1"),
        ]
        let set = try #require(vm.pendingQuestions)
        #expect(set.messageId == "a1")
        #expect(set.questions.count == 1)
        #expect(set.questions[0].attachmentId == "tar-0123456789ab")
    }

    @Test func pendingQuestionsNilWhileStreaming() {
        let vm = makeVM()
        vm.store.messages = [questionMessage()]
        vm.store.isStreaming = true
        #expect(vm.pendingQuestions == nil)
    }

    @Test func pendingQuestionsNilWhenUserMessageTrails() {
        let vm = makeVM()
        vm.store.messages = [
            questionMessage(),
            textMessage(role: .user, text: "answered elsewhere"),
        ]
        #expect(vm.pendingQuestions == nil)
    }

    @Test func pendingQuestionsNilWhenNoQuestions() {
        let vm = makeVM()
        vm.store.messages = [textMessage(role: .assistant, text: "plain reply")]
        #expect(vm.pendingQuestions == nil)
    }

    @Test func suggestedPromptsHiddenWhileQuestionsPend() {
        let vm = makeVM()
        vm.store.messages = [
            questionMessage(extraBlocks: [
                ContentBlock(type: .text, text: "Done\n<!-- suggested-prompts\nRun tests\n-->"),
            ]),
        ]
        #expect(vm.pendingQuestions != nil)
        #expect(vm.suggestedPrompts.isEmpty)
    }

    @Test func suggestedPromptsReturnOnceQuestionsSuperseded() {
        let vm = makeVM()
        vm.store.messages = [
            questionMessage(),
            textMessage(role: .user, text: "answered"),
            textMessage(role: .assistant,
                        text: "Done\n<!-- suggested-prompts\nRun tests\n-->"),
        ]
        #expect(vm.pendingQuestions == nil)
        #expect(vm.suggestedPrompts == ["Run tests"])
    }

    /// Wire the view model's store to a FakeConnectionManager so the
    /// `agent.sendMessage` outcome is controlled per test.
    private func makeFakeBackedVM(sendError: Error? = nil)
        -> (vm: ConversationViewModel, fake: FakeConnectionManager) {
        let vm = makeVM()
        let fake = FakeConnectionManager()
        if let sendError {
            fake.errorMap["agent.sendMessage"] = sendError
        } else {
            fake.responseMap["agent.sendMessage"] = ["messageId": "srv-1"]
        }
        vm.store = ConversationStore(connectionManager: fake)
        return (vm, fake)
    }

    private func firstAnswer(_ vm: ConversationViewModel) throws -> [QuestionAnswer] {
        let set = try #require(vm.pendingQuestions)
        return [
            QuestionAnswer(
                question: set.questions[0],
                selectedLabels: ["OAuth"],
                freeText: "",
                skipped: false
            ),
        ]
    }

    @Test func submitQuestionAnswersSendsFlattenedMessageThroughSendPath() async throws {
        let (vm, fake) = makeFakeBackedVM()
        vm.store.messages = [questionMessage()]
        let answers = try firstAnswer(vm)

        await vm.submitQuestionAnswers(answers)

        let last = try #require(vm.messages.last)
        #expect(last.role == .user)
        let text = (last.contentBlocks ?? []).compactMap { $0.resolvedText }.joined()
        #expect(text == "Q: Which auth method?\nA: OAuth")
        // The trailing user message supersedes the questions derivationally,
        // so the wizard hides while the send is in flight and after it lands.
        #expect(vm.pendingQuestions == nil)
        // Wire contract: wizard sends never carry image attachments.
        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        #expect(sent.params["imageBlocks"] == nil)
    }

    @Test func submitQuestionAnswersClearsPendingImages() async throws {
        // Regression (PR #55 review): stale composer attachments must not
        // silently ride a later normal message after a wizard submit
        // (FE parity: ChatPanel.performLocalSendCleanup).
        let (vm, _) = makeFakeBackedVM()
        vm.store.messages = [questionMessage()]
        vm.addImage(UIImage(systemName: "star")!)
        let answers = try firstAnswer(vm)

        await vm.submitQuestionAnswers(answers)

        #expect(vm.pendingImages.isEmpty)
    }

    @Test func failedSubmitRollsBackOptimisticMessageAndRestoresQuestions() async throws {
        // Regression (PR #55 review): a failed send must not permanently
        // supersede the pending questions — the optimistic user message is
        // rolled back so the wizard re-derives and returns.
        let (vm, _) = makeFakeBackedVM(
            sendError: NSError(domain: "WebSocket", code: -32000))
        vm.store.messages = [questionMessage()]
        let answers = try firstAnswer(vm)
        #expect(vm.pendingQuestions != nil)

        await vm.submitQuestionAnswers(answers)

        #expect(vm.messages.count == 1, "optimistic user message rolled back")
        #expect(vm.messages.last?.role == .assistant)
        #expect(vm.isStreaming == false)
        #expect(vm.pendingQuestions != nil, "questions re-pend after failure")
    }

    // MARK: - Missing-agent detection at load

    /// Configure the fake with every response load() touches, then override
    /// selected methods with errors.
    private func makeLoadableVM(errors: [String: Error] = [:])
        -> (vm: ConversationViewModel, fake: FakeConnectionManager) {
        let vm = makeVM()
        let fake = FakeConnectionManager()
        fake.responseMap["events.subscribe"] = ["subscriptionId": "sub-streaming"]
        fake.responseMap["events.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.responseMap["agent.get"] = ["agent": ["id": "test-agent", "name": "Test"]] as [String: Any]
        fake.responseMap["agent.getQueue"] = ["queue": []]
        fake.responseMap["agent.getSubscriptions"] = ["subscriptions": [], "delegationGroups": []]
        for (method, error) in errors {
            fake.errorMap[method] = error
        }
        vm.store = ConversationStore(connectionManager: fake)
        return (vm, fake)
    }

    @Test func loadNotFoundRaisesAgentNotFound() async {
        let notFound = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "unknown agent id: test-agent"])
        let (vm, _) = makeLoadableVM(errors: [
            "agent.getConversation": notFound,
            "agent.get": notFound,
        ])

        await vm.load()

        #expect(vm.agentNotFound, "not-found at load must surface agentNotFound")
    }

    @Test func loadTransientErrorDoesNotRaiseAgentNotFound() async {
        let timeout = NSError(
            domain: "WebSocket", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"])
        let (vm, _) = makeLoadableVM(errors: [
            "agent.getConversation": timeout,
            "agent.get": timeout,
        ])

        await vm.load()

        #expect(!vm.agentNotFound, "a transient error at load must not read as deletion")
    }

    @Test func loadSuccessLeavesAgentNotFoundFalse() async {
        let (vm, _) = makeLoadableVM()

        await vm.load()

        #expect(!vm.agentNotFound)
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

