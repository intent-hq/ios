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

    @Test func filteredMessagesKeepsWorkspaceEvents() async {
        // Event wakes render as a banner (or fall back to the user bubble
        // on legacy text-only rows) — they are no longer hidden.
        let vm = makeVM()
        vm.store.messages = [
            textMessage(role: .user, text: "[WORKSPACE EVENTS] something happened"),
        ]
        #expect(vm.filteredMessages.count == 1)
    }

    @Test func filteredMessagesKeepsTaskWake() async {
        let vm = makeVM()
        vm.store.messages = [
            textMessage(role: .user, text: "[TASK WAKE] waking up"),
        ]
        #expect(vm.filteredMessages.count == 1)
    }

    @Test func filteredMessagesKeepsAgentMessage() async {
        // A2A sends are no longer hidden — MessageView renders them with a
        // sender attribution header instead.
        let vm = makeVM()
        vm.store.messages = [
            textMessage(role: .user, text: "[AGENT MESSAGE] from another agent"),
        ]
        #expect(vm.filteredMessages.count == 1)
    }

    @Test func filteredMessagesKeepsEventNotificationMetadata() async {
        let vm = makeVM()
        vm.store.messages = [
            textMessage(role: .user, text: "event data",
                        metadata: ["type": AnyCodable("event_notification")]),
        ]
        #expect(vm.filteredMessages.count == 1)
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
            textMessage(role: .user, text: "[AGENT MESSAGE] z"),
            textMessage(role: .assistant, text: "Done"),
        ]
        #expect(vm.filteredMessages.count == 5)
    }

    // MARK: - queuedMessages display filter

    private func queuedEntry(id: String, content: String = "c",
                             metadata: [String: AnyCodable]? = nil) -> QueuedMessage {
        QueuedMessage(id: id, content: content, queuedAt: "2025-01-01T00:00:00Z",
                      position: 0, imageBlocks: nil, messageMetadata: metadata)
    }

    @Test func queuedMessagesHidesNonUserEntries() async {
        let vm = makeVM()
        vm.store.queuedMessages = [
            queuedEntry(id: "q-user"),
            // Malformed agent message (no fromAgentId): typed metadata → hidden.
            queuedEntry(id: "q-agent-bad", metadata: ["type": AnyCodable("agent_message")]),
            queuedEntry(id: "q-system", metadata: ["source": AnyCodable("system")]),
            queuedEntry(id: "q-benign", metadata: ["userAppMessageId": AnyCodable("uam-1")]),
        ]
        #expect(vm.queuedMessages.map(\.id) == ["q-user", "q-benign"])
        // The store keeps the full queue (flush behavior untouched).
        #expect(vm.store.queuedMessages.count == 4)
    }

    @Test func queuedMessagesHidesAgentMessageEntries() async {
        // Agent-to-agent sends are daemon-originated: hidden from the section.
        let vm = makeVM()
        vm.store.queuedMessages = [
            queuedEntry(id: "q-agent", metadata: [
                "type": AnyCodable("agent_message"), "fromAgentId": AnyCodable("agent-2"),
                "fromAgentName": AnyCodable("Verifier"),
            ]),
        ]
        #expect(vm.queuedMessages.isEmpty)
    }

    @Test func queuedMessagesHidesEventNotificationEntries() async {
        // Metadata-typed event-notification wakes are hidden; legacy
        // content-prefix entries without metadata fail open as user-authored
        // (`isUserMessage` rules unchanged).
        let vm = makeVM()
        vm.store.queuedMessages = [
            queuedEntry(id: "q-event", metadata: ["type": AnyCodable("event_notification")]),
            queuedEntry(id: "q-event-legacy", content: "[WORKSPACE EVENTS] 1 event"),
        ]
        #expect(vm.queuedMessages.map(\.id) == ["q-event-legacy"])
    }

    @Test func queuedMessagesEmptyWhenOnlyNonUserEntries() async {
        let vm = makeVM()
        vm.store.queuedMessages = [
            queuedEntry(id: "q-agent", metadata: ["fromAgentId": AnyCodable("agent-2")]),
        ]
        #expect(vm.queuedMessages.isEmpty)
    }

    @Test func queuedMessagesHidesWakeEntries() async {
        // Hook and PR-monitor wakes (PROTOCOL §5.40 / §5.42) are
        // daemon-originated: hidden from the section.
        let vm = makeVM()
        vm.store.queuedMessages = [
            queuedEntry(id: "q-hook", metadata: [
                "type": AnyCodable("hook_wake"), "hookId": AnyCodable("h-1"),
                "hookName": AnyCodable("CI watcher"), "reason": AnyCodable("dispatched"),
            ]),
            queuedEntry(id: "q-pr", metadata: [
                "type": AnyCodable("pr_monitor_wake"), "monitorId": AnyCodable("m-1"),
                "repo": AnyCodable("intent-hq/intentd"), "prNumber": AnyCodable(7),
            ]),
            // Malformed PR wake (no repo): still a typed entry → hidden.
            queuedEntry(id: "q-pr-bad", metadata: ["type": AnyCodable("pr_monitor_wake")]),
        ]
        #expect(vm.queuedMessages.isEmpty)
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

    @Test func suggestedPromptsSpanningTwoTextBlocks() async {
        // Text blocks are joined with newlines, so a block boundary must not
        // fuse the opener onto the first prompt line.
        let vm = makeVM()
        vm.store.messages = [
            ConversationMessage(
                id: UUID().uuidString, role: .assistant,
                contentBlocks: [
                    ContentBlock(type: .text, text: "Done!\n<!-- suggested-prompts"),
                    ContentBlock(type: .text, text: "Run the tests\n-->"),
                ],
                metadata: nil
            ),
        ]
        #expect(vm.suggestedPrompts == ["Run the tests"])
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

    /// Wire the view model's store AND upload service to a
    /// FakeConnectionManager so the `agent.sendMessage` /
    /// `file.placeAttachment` outcomes are controlled per test.
    private func makeFakeBackedVM(sendError: Error? = nil)
        -> (vm: ConversationViewModel, fake: FakeConnectionManager) {
        let vm = makeVM()
        let fake = FakeConnectionManager()
        if let sendError {
            fake.errorMap["agent.sendMessage"] = sendError
        } else {
            fake.responseMap["agent.sendMessage"] = ["messageId": "srv-1"]
        }
        fake.responseMap["file.placeAttachment"] = [
            "attachmentId": "att-1", "fileName": "image.jpg",
            "path": ".intent/attachments/att-1/image.jpg", "size": 3,
            "mimeType": "image/jpeg",
        ] as [String: Any]
        vm.store = ConversationStore(connectionManager: fake)
        vm.uploadService = AttachmentUploadService(connection: fake)
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

        await vm.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

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

    @Test func submitQuestionAnswersTagsWireMessageWithQuestionAnswersMetadata() async throws {
        // Regression (intent-hq/monorepo#1789): the daemon only retires the
        // question hold (and the workspace's needs_attention status) when the
        // answer send carries messageMetadata { type: "question_answers",
        // answeredQuestionsMessageId } naming the question-bearing assistant
        // message — an untagged answer leaves the hold pending forever.
        let (vm, fake) = makeFakeBackedVM()
        vm.store.messages = [questionMessage(id: "a1")]
        let answers = try firstAnswer(vm)

        await vm.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        let metadata = try #require(sent.params["messageMetadata"] as? [String: Any])
        #expect(metadata["type"] as? String == "question_answers")
        #expect(metadata["answeredQuestionsMessageId"] as? String == "a1")
    }

    @Test func submitQuestionAnswersTagsWithMountTimeIdEvenWhenDerivationFlips() async throws {
        // Regression (PR #84 review): the wizard hands its mount-time
        // question-bearing message id to the submit — never re-derived after
        // the onComplete Task hop. If a pushed stream start (isStreaming) or
        // a superseding row flips the pendingQuestions derivation nil in that
        // window, the answer must STILL go out tagged with the mount-time id;
        // an untagged send would silently reproduce the #1789 symptom.
        let (vm, fake) = makeFakeBackedVM()
        vm.store.messages = [questionMessage(id: "a1")]
        let answers = try firstAnswer(vm)
        vm.store.isStreaming = true
        #expect(vm.pendingQuestions == nil, "derivation flipped nil pre-submit")

        await vm.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        let metadata = try #require(sent.params["messageMetadata"] as? [String: Any])
        #expect(metadata["type"] as? String == "question_answers")
        #expect(metadata["answeredQuestionsMessageId"] as? String == "a1")
    }

    @Test func plainSendMessageCarriesNoMessageMetadata() async throws {
        // Ordinary sends must stay byte-identical to before: no metadata key.
        let (vm, fake) = makeFakeBackedVM()

        await vm.sendMessage("just a normal message")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        #expect(sent.params["messageMetadata"] == nil)
    }

    @Test func submitQuestionAnswersClearsPendingImages() async throws {
        // Regression (PR #55 review): stale composer attachments must not
        // silently ride a later normal message after a wizard submit
        // (FE parity: ChatPanel.performLocalSendCleanup).
        let (vm, _) = makeFakeBackedVM()
        vm.store.messages = [questionMessage()]
        vm.addImage(UIImage(systemName: "star")!)
        let answers = try firstAnswer(vm)

        await vm.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

        #expect(vm.pendingImages.isEmpty)
    }

    @Test func dismissQuestionsRetiresPendingSet() async throws {
        let (vm, fake) = makeFakeBackedVM()
        fake.responseMap["agent.dismissQuestions"] = [
            "success": true, "dismissedQuestionsMessageId": "a1",
        ] as [String: Any]
        vm.store.messages = [questionMessage(id: "a1")]
        #expect(vm.pendingQuestions != nil)

        await vm.dismissQuestions(messageId: "a1")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.dismissQuestions" })
        #expect(sent.params["agentId"] as? String == "test-agent")
        #expect(sent.params["messageId"] as? String == "a1")
        #expect(sent.params["workspaceId"] as? String == "test-ws")
        #expect(vm.pendingQuestions == nil, "the dismissed set never re-pends")
    }

    @Test func failedDismissKeepsQuestionsPending() async {
        let (vm, fake) = makeFakeBackedVM()
        fake.errorMap["agent.dismissQuestions"] = NSError(domain: "WebSocket", code: -32000)
        vm.store.messages = [questionMessage(id: "a1")]

        await vm.dismissQuestions(messageId: "a1")

        #expect(vm.pendingQuestions != nil, "a failed dismiss must leave the wizard pending")
    }

    @Test func failedDismissSurfacesVisibleError() async {
        // Regression (intent-hq/monorepo#1800): a failed dismiss must surface
        // an explicit user-visible error, not just silently re-pend the
        // wizard — and the surface must be non-destructive (rollback intact).
        let (vm, fake) = makeFakeBackedVM()
        fake.errorMap["agent.dismissQuestions"] = NSError(domain: "WebSocket", code: -32000)
        vm.store.messages = [questionMessage(id: "a1")]
        #expect(vm.dismissQuestionsError == nil)

        await vm.dismissQuestions(messageId: "a1")

        #expect(vm.dismissQuestionsError != nil,
                "a failed dismiss surfaces a user-visible error")
        #expect(vm.pendingQuestions != nil,
                "the error surface is non-destructive — the wizard still re-pends")
    }

    @Test func successfulDismissRetryClearsPriorError() async {
        // A later successful dismiss must not leave a stale error surfaced.
        let (vm, fake) = makeFakeBackedVM()
        fake.errorMap["agent.dismissQuestions"] = NSError(domain: "WebSocket", code: -32000)
        vm.store.messages = [questionMessage(id: "a1")]
        await vm.dismissQuestions(messageId: "a1")
        #expect(vm.dismissQuestionsError != nil)

        fake.errorMap["agent.dismissQuestions"] = nil
        fake.responseMap["agent.dismissQuestions"] = [
            "success": true, "dismissedQuestionsMessageId": "a1",
        ] as [String: Any]
        await vm.dismissQuestions(messageId: "a1")

        #expect(vm.dismissQuestionsError == nil,
                "a successful retry clears the stale error")
        #expect(vm.pendingQuestions == nil)
    }

    @Test func newerQuestionSetPendsAfterDismissingOlderOne() async throws {
        let (vm, fake) = makeFakeBackedVM()
        fake.responseMap["agent.dismissQuestions"] = [
            "success": true, "dismissedQuestionsMessageId": "a1",
        ] as [String: Any]
        vm.store.messages = [questionMessage(id: "a1")]
        await vm.dismissQuestions(messageId: "a1")

        vm.store.messages.append(questionMessage(id: "a2"))

        let set = try #require(vm.pendingQuestions)
        #expect(set.messageId == "a2", "a newer question set pends normally")
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

        await vm.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

        #expect(vm.messages.count == 1, "optimistic user message rolled back")
        #expect(vm.messages.last?.role == .assistant)
        #expect(vm.isStreaming == false)
        #expect(vm.pendingQuestions != nil, "questions re-pend after failure")
    }

    // MARK: - Suggested-prompt send (draft retention)

    @Test func sendSuggestedPromptDoesNotAttachPendingImages() async throws {
        // Regression: draft attachments must not silently ride a suggested
        // prompt — the prompt sends text only.
        let (vm, fake) = makeFakeBackedVM()
        vm.addImage(UIImage(systemName: "star")!)

        await vm.sendSuggestedPrompt("Run the tests")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        #expect(sent.params["imageBlocks"] == nil)
        #expect(vm.pendingImages.count == 1, "pending images stay attached to the draft")
    }

    @Test func sendSuggestedPromptLeavesDraftIntact() async {
        // Regression: a suggested-prompt send must not clear the persisted
        // composer draft or the on-screen draft text.
        let (vm, _) = makeFakeBackedVM()
        PersistenceManager.shared.saveDraft(
            "half-typed draft", workspaceId: vm.workspaceId, agentId: vm.agentId)
        vm.messageText = "half-typed draft"

        await vm.sendSuggestedPrompt("Run the tests")

        #expect(vm.messageText == "half-typed draft")
        #expect(PersistenceManager.shared.loadDraft(
            workspaceId: vm.workspaceId, agentId: vm.agentId) == "half-typed draft")
        PersistenceManager.shared.clearDraft(workspaceId: vm.workspaceId, agentId: vm.agentId)
    }

    @Test func sendMessageStillClearsDraftAndUsesExplicitImages() async throws {
        // The normal composer path is unchanged: explicit images are sent and
        // the persisted draft is cleared after a successful send.
        let (vm, fake) = makeFakeBackedVM()
        PersistenceManager.shared.saveDraft(
            "outgoing", workspaceId: vm.workspaceId, agentId: vm.agentId)

        await vm.sendMessage("outgoing", images: [UIImage(systemName: "star")!])

        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        #expect(sent.params["imageBlocks"] != nil)
        #expect(PersistenceManager.shared.loadDraft(
            workspaceId: vm.workspaceId, agentId: vm.agentId) == "")
    }

    // MARK: - Image placement (attachment references, monorepo#3338)

    @Test func buildImageBlocksPlacesImagesAndBuildsReferenceBlocks() async throws {
        // Sending an image places it (`file.placeAttachment`) and the wire
        // block is `{ type: "image", attachmentId, mimeType }` — never
        // inline base64 (FE parity: toImageReferenceBlocks).
        let (vm, fake) = makeFakeBackedVM()

        await vm.sendMessage("with image", images: [UIImage(systemName: "star")!])

        let placement = try #require(
            fake.requestLog.last { $0.method == "file.placeAttachment" })
        #expect(placement.params["workspaceId"] as? String == "test-ws")
        #expect(placement.params["mimeType"] as? String == "image/jpeg")
        #expect((placement.params["fileName"] as? String)?.hasSuffix(".jpg") == true)

        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        let blocks = try #require(sent.params["imageBlocks"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"] as? String == "image")
        #expect(blocks[0]["attachmentId"] as? String == "att-1")
        #expect(blocks[0]["mimeType"] as? String == "image/jpeg")
        #expect(blocks[0]["data"] == nil, "no inline data key for placed images")
    }

    @Test func failedPlacementSurfacesErrorAndDoesNotSend() async throws {
        // FAIL-CLOSED (FE parity): a placement failure aborts the send — no
        // agent.sendMessage goes out, the error surfaces, and the composer
        // state (text + captured images) is restored.
        let (vm, fake) = makeFakeBackedVM()
        fake.errorMap["file.placeAttachment"] = NSError(
            domain: "WebSocket", code: -32000,
            userInfo: [NSLocalizedDescriptionKey: "registry full"])

        await vm.sendMessage("with image", images: [UIImage(systemName: "star")!])

        #expect(fake.requestLog.allSatisfy { $0.method != "agent.sendMessage" },
                "the message is never sent when placement fails")
        #expect(vm.imagePlacementError != nil)
        #expect(vm.messageText == "with image", "draft text restored")
        #expect(vm.pendingImages.count == 1, "captured images restored")
    }

    @Test func oversizedImageSurfacesErrorInsteadOfSilentSkip() async throws {
        // The silent 10 MB skip is gone: an image over the daemon's 30 MiB
        // image-reference cap fails the send with an explicit error.
        let (vm, fake) = makeFakeBackedVM()
        // A noise image so JPEG can't compress below the cap — 36 Mpx at
        // ≳1 byte/pixel lands above 30 MiB without the memory weight of a
        // larger bitmap.
        let oversized = makeIncompressibleImage(side: 6000)

        await vm.sendMessage("big", images: [oversized])

        #expect(fake.requestLog.isEmpty, "no RPC at all for an oversized image")
        #expect(vm.imagePlacementError?.contains("too large") == true)
        #expect(vm.pendingImages.count == 1, "captured image restored")
    }

    @Test func aggregateOversizedImagesSurfaceErrorBeforeAnyPlacement() async throws {
        // The daemon enforces the 30 MiB image-reference cap in AGGREGATE
        // across a message's blocks too (§5.5): two images each under the
        // per-image cap but over it together fail closed before any RPC.
        let (vm, fake) = makeFakeBackedVM()
        // ~25 Mpx noise ≈ 25 MB each as JPEG: under the per-image cap,
        // over 30 MiB in aggregate.
        let image = makeIncompressibleImage(side: 5000)

        await vm.sendMessage("big pair", images: [image, image])

        #expect(fake.requestLog.isEmpty, "no RPC at all for an aggregate-oversized send")
        #expect(vm.imagePlacementError?.contains("too large") == true)
        #expect(vm.pendingImages.count == 2, "captured images restored")
    }

    @Test func queueMessageFailedPlacementKeepsPendingImages() async throws {
        // The queue path never pre-clears pendingImages; a placement failure
        // must keep them attached and never reach agent.queueMessage.
        let (vm, fake) = makeFakeBackedVM()
        fake.errorMap["file.placeAttachment"] = NSError(
            domain: "WebSocket", code: -32000)
        vm.addImage(UIImage(systemName: "star")!)

        await vm.queueMessage("queued with image")

        #expect(fake.requestLog.allSatisfy { $0.method != "agent.queueMessage" })
        #expect(vm.imagePlacementError != nil)
        #expect(vm.pendingImages.count == 1)
    }

    @Test func queueMessagePlacesImagesAndClearsPending() async throws {
        let (vm, fake) = makeFakeBackedVM()
        fake.responseMap["agent.queueMessage"] = [:] as [String: Any]
        vm.addImage(UIImage(systemName: "star")!)

        await vm.queueMessage("queued with image")

        let queued = try #require(fake.requestLog.last { $0.method == "agent.queueMessage" })
        let blocks = try #require(queued.params["imageBlocks"] as? [[String: Any]])
        #expect(blocks[0]["attachmentId"] as? String == "att-1")
        #expect(blocks[0]["data"] == nil)
        #expect(vm.pendingImages.isEmpty)
    }

    @Test func sendMessageWithoutImagesSkipsPlacement() async throws {
        // Text-only sends never touch the attachment registry.
        let (vm, fake) = makeFakeBackedVM()

        await vm.sendMessage("plain text")

        #expect(fake.requestLog.allSatisfy { $0.method != "file.placeAttachment" })
        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        #expect(sent.params["imageBlocks"] == nil)
        #expect(sent.params["fileBlocks"] == nil)
    }

    // MARK: - File placement (send-time uploads)

    @Test func sendMessagePlacesFilesAndBuildsFileBlocks() async throws {
        // Sending with a pending file places it (`file.placeAttachment`,
        // single-shot under 25 MB) and the wire block is
        // `{ type: "file", attachmentId, fileName, mimeType, size }`; the
        // pending list clears only after the successful send.
        let (vm, fake) = makeFakeBackedVM()
        fake.responseMap["file.placeAttachment"] = [
            "attachmentId": "att-f1", "fileName": "notes.txt",
            "path": ".intent/attachments/att-f1/notes.txt", "size": 5,
            "mimeType": "text/plain",
        ] as [String: Any]
        let url = try makeTempFile(named: "notes.txt", contents: "hello")
        defer { try? FileManager.default.removeItem(at: url) }
        vm.addFiles([url])

        await vm.sendMessage("with file")

        let placement = try #require(
            fake.requestLog.last { $0.method == "file.placeAttachment" })
        #expect(placement.params["workspaceId"] as? String == "test-ws")
        #expect(placement.params["fileName"] as? String == "notes.txt")
        #expect(placement.params["mimeType"] as? String == "text/plain")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        let blocks = try #require(sent.params["fileBlocks"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"] as? String == "file")
        #expect(blocks[0]["attachmentId"] as? String == "att-f1")
        #expect(blocks[0]["fileName"] as? String == "notes.txt")
        #expect(blocks[0]["mimeType"] as? String == "text/plain")
        #expect(blocks[0]["size"] as? Int == 5)
        #expect(vm.pendingFiles.isEmpty, "pending files clear on successful send")
        #expect(vm.fileUploadProgress.isEmpty, "progress state cleared after send")
    }

    @Test func failedFilePlacementSurfacesErrorAndDoesNotSend() async throws {
        // FAIL-CLOSED: a file placement failure aborts the send — no
        // agent.sendMessage goes out, the error surfaces, the draft text is
        // restored, and the pending files stay attached.
        let (vm, fake) = makeFakeBackedVM()
        fake.errorMap["file.placeAttachment"] = NSError(
            domain: "WebSocket", code: -32000,
            userInfo: [NSLocalizedDescriptionKey: "registry full"])
        let url = try makeTempFile(named: "notes.txt", contents: "hello")
        defer { try? FileManager.default.removeItem(at: url) }
        vm.addFiles([url])

        await vm.sendMessage("with file")

        #expect(fake.requestLog.allSatisfy { $0.method != "agent.sendMessage" },
                "the message is never sent when file placement fails")
        #expect(vm.filePlacementError != nil)
        #expect(vm.messageText == "with file", "draft text restored")
        #expect(vm.pendingFiles.count == 1, "pending files stay attached")
        #expect(vm.fileUploadProgress.isEmpty, "progress state cleared after failure")
    }

    @Test func oversizedPendingFileFailsWithoutAnyRPC() async throws {
        // A pending file whose pick-time size exceeds the daemon's 1 GiB cap
        // fails the send client-side with an explicit error.
        let (vm, fake) = makeFakeBackedVM()
        vm.pendingFiles.append(PendingFile(
            url: URL(fileURLWithPath: "/tmp/huge.bin"),
            displayName: "huge.bin",
            size: Int64(AttachmentUploadService.maxAttachmentBytes) + 1))

        await vm.sendMessage("big file")

        #expect(fake.requestLog.isEmpty, "no RPC at all for an oversized file")
        #expect(vm.filePlacementError?.contains("too large") == true)
        #expect(vm.pendingFiles.count == 1)
    }

    @Test func queueMessagePlacesFilesAndClearsPending() async throws {
        let (vm, fake) = makeFakeBackedVM()
        fake.responseMap["agent.queueMessage"] = [:] as [String: Any]
        fake.responseMap["file.placeAttachment"] = [
            "attachmentId": "att-f1", "fileName": "notes.txt",
            "path": ".intent/attachments/att-f1/notes.txt", "size": 5,
        ] as [String: Any]
        let url = try makeTempFile(named: "notes.txt", contents: "hello")
        defer { try? FileManager.default.removeItem(at: url) }
        vm.addFiles([url])

        await vm.queueMessage("queued with file")

        let queued = try #require(fake.requestLog.last { $0.method == "agent.queueMessage" })
        let blocks = try #require(queued.params["fileBlocks"] as? [[String: Any]])
        #expect(blocks[0]["attachmentId"] as? String == "att-f1")
        #expect(blocks[0]["mimeType"] == nil, "mimeType omitted when the daemon returns none")
        #expect(vm.pendingFiles.isEmpty)
    }

    @Test func queueMessageFailedFilePlacementKeepsPendingFiles() async throws {
        let (vm, fake) = makeFakeBackedVM()
        fake.errorMap["file.placeAttachment"] = NSError(
            domain: "WebSocket", code: -32000)
        let url = try makeTempFile(named: "notes.txt", contents: "hello")
        defer { try? FileManager.default.removeItem(at: url) }
        vm.addFiles([url])

        await vm.queueMessage("queued with file")

        #expect(fake.requestLog.allSatisfy { $0.method != "agent.queueMessage" })
        #expect(vm.filePlacementError != nil)
        #expect(vm.pendingFiles.count == 1)
    }

    /// Write a small temp file and return its URL (caller removes it).
    private func makeTempFile(named name: String, contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    /// A `side`×`side` per-pixel random-noise bitmap: JPEG cannot compress
    /// noise (≳1 byte/pixel at 0.8 quality), so the encoded payload lands
    /// well above the 30 MiB reference cap.
    private func makeIncompressibleImage(side: Int) -> UIImage {
        var bytes = Data(count: side * side * 4)
        bytes.withUnsafeMutableBytes { buf in
            arc4random_buf(buf.baseAddress!, buf.count)
        }
        let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        bytes.withUnsafeBytes { buf in
            ctx.data!.copyMemory(from: buf.baseAddress!, byteCount: buf.count)
        }
        return UIImage(cgImage: ctx.makeImage()!)
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
            userInfo: [NSLocalizedDescriptionKey: "unknown agent id: test-agent",
                       NSError.intentErrorDataCodeKey: "not-found"])
        let (vm, _) = makeLoadableVM(errors: [
            "agent.getConversation": notFound,
            "agent.get": notFound,
        ])

        await vm.load()

        #expect(vm.agentNotFound, "not-found at load must surface agentNotFound")
    }

    @Test func loadBare32602DoesNotRaiseAgentNotFound() async {
        // -32602 without data.code == "not-found" (invalid-params or a legacy
        // daemon omitting data) must NOT read as deletion (docs/PROTOCOL.md §9)
        let bare = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: agentId"])
        let (vm, _) = makeLoadableVM(errors: [
            "agent.getConversation": bare,
            "agent.get": bare,
        ])

        await vm.load()

        #expect(!vm.agentNotFound, "a -32602 without data.code == \"not-found\" must not read as deletion")
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

    @Test func loadSettlesBeforeTranscriptCanMount() async {
        // Regression (PR #112 review): on first open the transcript view
        // mounts only after load() settles (the loading placeholder renders
        // while isLoading is true), so the entry scroll must be runnable from
        // the transcript's onAppear against already-settled state: isLoading
        // false and the divider anchor latched by the time load() returns.
        let (vm, fake) = makeLoadableVM()
        fake.responseMap["agent.getConversation"] = ["messages": [
            ["id": "m1", "role": "assistant", "contentBlocks": [["type": "text", "text": "old"]]],
            ["id": "m2", "role": "assistant", "contentBlocks": [["type": "text", "text": "new"]]],
        ]]
        fake.responseMap["agent.get"] = ["agent": [
            "id": "test-agent", "name": "Test",
            "metadata": ["lastSeenMessageId": "m1"],
        ]] as [String: Any]

        await vm.load()

        #expect(!vm.isLoading, "load() returns with isLoading already settled")
        #expect(vm.filteredMessages.count == 2)
        #expect(vm.newMessagesDividerAnchorId == "m1",
                "the divider anchor is latched before the transcript can mount")
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

        // sendMessage with explicit images works even though pendingImages is
        // empty. With no server, placement fails — and the FAIL-CLOSED restore
        // path (surfacePlacementFailure) re-attaches the captured images so
        // nothing is silently lost.
        await vm.sendMessage("test with images", images: capturedImages)

        #expect(vm.imagePlacementError != nil)
        #expect(vm.pendingImages.count == 2, "captured images restored on failed placement")
    }

    // MARK: - Seen-marker triggers (agent.markSeen, PROTOCOL §5.5)

    /// Fake-backed VM with a short markSeen debounce for trigger tests.
    private func makeSeenVM(debounceNanos: UInt64 = 20_000_000)
        -> (vm: ConversationViewModel, fake: FakeConnectionManager) {
        let vm = makeVM()
        let fake = FakeConnectionManager()
        fake.responseMap["agent.sendMessage"] = ["messageId": "srv-1"]
        fake.responseMap["agent.markSeen"] = ["success": true] as [String: Any]
        vm.store = ConversationStore(connectionManager: fake)
        vm.markSeenDebounceNanos = debounceNanos
        return (vm, fake)
    }

    /// Poll (yielding the main actor) until `agent.markSeen` has been called
    /// `count` times or the timeout elapses.
    private func waitForMarkSeen(_ fake: FakeConnectionManager, count: Int = 1,
                                 timeoutMs: Double = 2_000) async {
        let deadline = Date().addingTimeInterval(timeoutMs / 1000)
        while Date() < deadline {
            if fake.paramsForMethod("agent.markSeen").count >= count { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test func turnFinishFiresDebouncedMarkSeenOnceWithNewestPersistedId() async {
        let (vm, fake) = makeSeenVM()
        vm.conversationAppeared()
        vm.store.messages = [
            textMessage(id: "m1", role: .user, text: "hi"),
            textMessage(id: "m2", role: .assistant, text: "done"),
        ]

        vm.store.isStreaming = true
        vm.store.isStreaming = false

        await waitForMarkSeen(fake)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let params = fake.paramsForMethod("agent.markSeen")
        #expect(params.count == 1, "a single turn finish fires exactly once")
        #expect(params.first?["messageId"] as? String == "m2")
    }

    @Test func turnFinishOffScreenDoesNotMarkSeen() async {
        let (vm, fake) = makeSeenVM()
        // No conversationAppeared() — the conversation is not on screen.
        vm.store.messages = [textMessage(id: "m1", role: .assistant, text: "done")]

        vm.store.isStreaming = true
        vm.store.isStreaming = false

        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(!fake.didCallMethod("agent.markSeen"),
                "turn finish is gated on the conversation being on screen")
    }

    @Test func turnFinishWhileAppInactiveDoesNotMarkSeen() async {
        let (vm, fake) = makeSeenVM()
        vm.conversationAppeared()
        vm.store.messages = [textMessage(id: "m1", role: .assistant, text: "old")]
        vm.store.lastSeenMessageId = "m1"
        vm.scenePhaseChanged(isActive: false)
        // Let the backgrounding boundary fire settle (it dedupes against the
        // current marker, so no RPC goes out for it).
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!fake.didCallMethod("agent.markSeen"))

        // A turn finishing while backgrounded must not schedule the debounce
        // — otherwise m2 (newer than the marker) would be sent below.
        vm.store.messages.append(textMessage(id: "m2", role: .assistant, text: "new"))
        vm.store.isStreaming = true
        vm.store.isStreaming = false

        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(!fake.didCallMethod("agent.markSeen"),
                "turn finish is gated on the app being active")
    }

    @Test func plainEntryDoesNotMarkSeen() async {
        let (vm, fake) = makeSeenVM()
        vm.store.messages = [textMessage(id: "m1", role: .assistant, text: "old")]

        vm.conversationAppeared()

        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(!fake.didCallMethod("agent.markSeen"),
                "entry never marks seen — the divider anchor must survive")
    }

    @Test func sendMessageSchedulesDebouncedMarkSeenWithoutFocusGate() async throws {
        let (vm, fake) = makeSeenVM()
        // No conversationAppeared() — composing is proof of looking.

        await vm.sendMessage("hello")

        await waitForMarkSeen(fake)
        let params = fake.paramsForMethod("agent.markSeen")
        #expect(params.count == 1)
        let optimisticId = try #require(vm.messages.last?.id)
        #expect(params.first?["messageId"] as? String == optimisticId,
                "the user's own (persisted-id) message is the marker target")
    }

    @Test func failedSendDoesNotScheduleMarkSeen() async {
        // Regression (PR #112 review): a failed send delivered nothing, so
        // the seen marker must not advance — markSeen is scheduled only on
        // the sendMessage success path (desktop parity).
        let (vm, fake) = makeSeenVM()
        fake.errorMap["agent.sendMessage"] = NSError(domain: "WebSocket", code: -32000)
        vm.store.messages = [textMessage(id: "m1", role: .assistant, text: "unseen")]

        await vm.sendMessage("hello")

        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(!fake.didCallMethod("agent.markSeen"),
                "a failed send must not schedule the debounced markSeen")
    }

    @Test func leavingConversationFiresMarkSeenImmediately() async {
        // Debounce far beyond the poll window: a call proves the immediate path.
        let (vm, fake) = makeSeenVM(debounceNanos: 10_000_000_000)
        vm.conversationAppeared()
        vm.store.messages = [textMessage(id: "m1", role: .assistant, text: "done")]

        vm.conversationDisappeared()

        await waitForMarkSeen(fake)
        let params = fake.paramsForMethod("agent.markSeen")
        #expect(params.count == 1)
        #expect(params.first?["messageId"] as? String == "m1")
    }

    @Test func leaveDuringDebounceWindowDropsPendingMarkSeen() async {
        let (vm, fake) = makeSeenVM(debounceNanos: 200_000_000)
        vm.conversationAppeared()
        vm.store.messages = [textMessage(id: "m1", role: .assistant, text: "done")]
        vm.store.isStreaming = true
        vm.store.isStreaming = false // schedules the 200ms debounce

        vm.conversationDisappeared() // immediate fire supersedes the debounce
        await waitForMarkSeen(fake)
        // A message lands after the boundary; the cancelled debounce must NOT
        // fire a second call targeting it once its window elapses.
        vm.store.messages.append(textMessage(id: "m2", role: .assistant, text: "late"))

        try? await Task.sleep(nanoseconds: 500_000_000)
        let params = fake.paramsForMethod("agent.markSeen")
        #expect(params.count == 1, "the pending debounce was dropped, not just deduped")
        #expect(params.first?["messageId"] as? String == "m1")
    }

    @Test func backgroundingFiresMarkSeenImmediately() async {
        let (vm, fake) = makeSeenVM(debounceNanos: 10_000_000_000)
        vm.conversationAppeared()
        vm.store.messages = [textMessage(id: "m1", role: .assistant, text: "done")]

        vm.scenePhaseChanged(isActive: false)

        await waitForMarkSeen(fake)
        let params = fake.paramsForMethod("agent.markSeen")
        #expect(params.count == 1)
        #expect(params.first?["messageId"] as? String == "m1")
    }

    @Test func boundaryDoesNotResendWhenMarkerAlreadyCurrent() async {
        let (vm, fake) = makeSeenVM()
        vm.store.messages = [textMessage(id: "m1", role: .assistant, text: "done")]
        vm.store.lastSeenMessageId = "m1"
        vm.conversationAppeared()

        vm.conversationDisappeared()

        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(!fake.didCallMethod("agent.markSeen"),
                "all triggers funnel through the store's dedupe")
    }

    // MARK: - Pending files

    /// Writes a real temp file so `addFiles` can resolve name/size via
    /// `resourceValues`. Plain file URLs are not security-scoped, so
    /// `startAccessingSecurityScopedResource()` returning false is exercised
    /// implicitly (no balancing stop is owed).
    private func makeTempFile(name: String, bytes: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0, count: bytes).write(to: url)
        return url
    }

    @Test func addFilesPopulatesDisplayNameAndSize() throws {
        let vm = makeVM()
        let url = try makeTempFile(name: "report.pdf", bytes: 1234)

        vm.addFiles([url])

        #expect(vm.pendingFiles.count == 1)
        #expect(vm.pendingFiles[0].url == url)
        #expect(vm.pendingFiles[0].displayName == "report.pdf")
        #expect(vm.pendingFiles[0].size == 1234)
        #expect(vm.pendingFiles[0].formattedSize?.isEmpty == false)
    }

    @Test func addFilesFallsBackToLastPathComponentForUnreadableURL() {
        let vm = makeVM()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-missing.bin")

        vm.addFiles([missing])

        #expect(vm.pendingFiles.count == 1)
        #expect(vm.pendingFiles[0].displayName == missing.lastPathComponent)
        #expect(vm.pendingFiles[0].size == nil)
        #expect(vm.pendingFiles[0].formattedSize == nil)
    }

    @Test func addFilesSkipsAlreadyPendingURL() throws {
        let vm = makeVM()
        let url = try makeTempFile(name: "dup.txt", bytes: 10)

        vm.addFiles([url])
        vm.addFiles([url, url])

        #expect(vm.pendingFiles.count == 1)
    }

    @Test func removePendingFileRemovesCorrectEntry() throws {
        let vm = makeVM()
        let first = try makeTempFile(name: "a.txt", bytes: 1)
        let second = try makeTempFile(name: "b.txt", bytes: 2)
        vm.addFiles([first, second])

        vm.removePendingFile(at: 0)

        #expect(vm.pendingFiles.map(\.displayName) == ["b.txt"])
    }

    @Test func removePendingFileIgnoresOutOfBoundsIndex() throws {
        let vm = makeVM()
        vm.addFiles([try makeTempFile(name: "a.txt", bytes: 1)])

        vm.removePendingFile(at: 5)
        vm.removePendingFile(at: -1)

        #expect(vm.pendingFiles.count == 1)
    }

    @Test func clearPendingFilesEmptiesList() throws {
        let vm = makeVM()
        vm.addFiles([
            try makeTempFile(name: "a.txt", bytes: 1),
            try makeTempFile(name: "b.txt", bytes: 2),
        ])

        vm.clearPendingFiles()

        #expect(vm.pendingFiles.isEmpty)
    }

    @Test func hasPendingAttachmentsCoversImagesAndFiles() throws {
        let vm = makeVM()
        #expect(!vm.hasPendingAttachments)

        vm.addFiles([try makeTempFile(name: "a.txt", bytes: 1)])
        #expect(vm.hasPendingAttachments)

        vm.clearPendingFiles()
        vm.pendingImages = [UIImage()]
        #expect(vm.hasPendingAttachments)

        vm.pendingImages = []
        #expect(!vm.hasPendingAttachments)
    }
}

