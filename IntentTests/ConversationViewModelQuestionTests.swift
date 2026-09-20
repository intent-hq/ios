import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing
import UIKit

extension ConversationViewModelTests {
    // MARK: - Agent Q&A pending questions (wizard glue)

    @Test func pendingQuestionsDerivedFromLastAssistant() throws {
        let viewModel = makeVM()
        viewModel.store.messages = [
            textMessage(role: .user, text: "hi"),
            questionMessage(id: "a1")
        ]
        let set = try #require(viewModel.pendingQuestions)
        #expect(set.messageId == "a1")
        #expect(set.questions.count == 1)
        #expect(set.questions[0].attachmentId == "tar-0123456789ab")
    }

    @Test func pendingQuestionsNilWhileStreaming() {
        let viewModel = makeVM()
        viewModel.store.messages = [questionMessage()]
        viewModel.store.isStreaming = true
        #expect(viewModel.pendingQuestions == nil)
    }

    @Test func pendingQuestionsNilWhenUserMessageTrails() {
        let viewModel = makeVM()
        viewModel.store.messages = [
            questionMessage(),
            textMessage(role: .user, text: "answered elsewhere")
        ]
        #expect(viewModel.pendingQuestions == nil)
    }

    @Test func pendingQuestionsNilWhenNoQuestions() {
        let viewModel = makeVM()
        viewModel.store.messages = [textMessage(role: .assistant, text: "plain reply")]
        #expect(viewModel.pendingQuestions == nil)
    }

    @Test func suggestedPromptsHiddenWhileQuestionsPend() {
        let viewModel = makeVM()
        viewModel.store.messages = [
            questionMessage(extraBlocks: [
                ContentBlock(type: .text, text: "Done\n<!-- suggested-prompts\nRun tests\n-->")
            ])
        ]
        #expect(viewModel.pendingQuestions != nil)
        #expect(viewModel.suggestedPrompts.isEmpty)
    }

    @Test func suggestedPromptsReturnOnceQuestionsSuperseded() {
        let viewModel = makeVM()
        viewModel.store.messages = [
            questionMessage(),
            textMessage(role: .user, text: "answered"),
            textMessage(
                role: .assistant,
                text: "Done\n<!-- suggested-prompts\nRun tests\n-->"
            )
        ]
        #expect(viewModel.pendingQuestions == nil)
        #expect(viewModel.suggestedPrompts == ["Run tests"])
    }

    /// Wire the view model's store AND upload service to a
    /// FakeConnectionManager so the `agent.sendMessage` /
    /// `file.placeAttachment` outcomes are controlled per test.
    func makeFakeBackedVM(sendError: Error? = nil)
        -> (viewModel: ConversationViewModel, fake: FakeConnectionManager) {
        let viewModel = makeVM()
        let fake = FakeConnectionManager()
        if let sendError {
            fake.errorMap["agent.sendMessage"] = sendError
        } else {
            fake.responseMap["agent.sendMessage"] = ["messageId": "srv-1"]
        }
        let attachmentSize = 3
        fake.responseMap["file.placeAttachment"] = [
            "attachmentId": "att-1",
            "fileName": "image.jpg",
            "path": ".intent/attachments/att-1/image.jpg",
            "size": attachmentSize,
            "mimeType": "image/jpeg"
        ] as [String: Any]
        viewModel.store = ConversationStore(connectionManager: fake)
        viewModel.uploadService = AttachmentUploadService(connection: fake)
        return (viewModel, fake)
    }

    /// The init-injected upload service must feed the attachment pipeline so
    /// pinned windows place attachments on their own backend, not the
    /// default one.
    @Test func initRoutesInjectedUploadServiceIntoAttachmentPipeline() {
        let service = AttachmentUploadService(connection: FakeConnectionManager())
        let viewModel = ConversationViewModel(
            agentId: "test-agent",
            workspaceId: "test-ws",
            agentName: "Test",
            connection: ConnectionManager.shared,
            uploadService: service,
            optionsStore: CreationOptionsStore()
        )
        #expect(viewModel.uploadService === service)
    }

    func firstAnswer(_ viewModel: ConversationViewModel) throws -> [QuestionAnswer] {
        let set = try #require(viewModel.pendingQuestions)
        return [
            QuestionAnswer(
                question: set.questions[0],
                selectedLabels: ["OAuth"],
                freeText: "",
                skipped: false
            )
        ]
    }

    @Test func submitQuestionAnswersSendsFlattenedMessageThroughSendPath() async throws {
        let (viewModel, fake) = makeFakeBackedVM()
        viewModel.store.messages = [questionMessage()]
        let answers = try firstAnswer(viewModel)

        await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

        let last = try #require(viewModel.messages.last)
        #expect(last.role == .user)
        let text = last.contentBlocks.compactMap { $0.resolvedText }.joined()
        #expect(text == "Q: Which auth method?\nA: OAuth")
        // The trailing user message supersedes the questions derivationally,
        // so the wizard hides while the send is in flight and after it lands.
        #expect(viewModel.pendingQuestions == nil)
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
        let (viewModel, fake) = makeFakeBackedVM()
        viewModel.store.messages = [questionMessage(id: "a1")]
        let answers = try firstAnswer(viewModel)

        await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

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
        let (viewModel, fake) = makeFakeBackedVM()
        viewModel.store.messages = [questionMessage(id: "a1")]
        let answers = try firstAnswer(viewModel)
        viewModel.store.isStreaming = true
        #expect(viewModel.pendingQuestions == nil, "derivation flipped nil pre-submit")

        await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        let metadata = try #require(sent.params["messageMetadata"] as? [String: Any])
        #expect(metadata["type"] as? String == "question_answers")
        #expect(metadata["answeredQuestionsMessageId"] as? String == "a1")
    }

    @Test func plainSendMessageCarriesNoMessageMetadata() async throws {
        // Ordinary sends must stay byte-identical to before: no metadata key.
        let (viewModel, fake) = makeFakeBackedVM()

        await viewModel.sendMessage("just a normal message")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        #expect(sent.params["messageMetadata"] == nil)
    }

    @Test func submitQuestionAnswersClearsPendingImages() async throws {
        // Regression (PR #55 review): stale composer attachments must not
        // silently ride a later normal message after a wizard submit
        // (FE parity: ChatPanel.performLocalSendCleanup).
        let (viewModel, _) = makeFakeBackedVM()
        viewModel.store.messages = [questionMessage()]
        viewModel.addImage(try #require(UIImage(systemName: "star")))
        let answers = try firstAnswer(viewModel)

        await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

        #expect(viewModel.pendingImages.isEmpty)
    }

    @Test func dismissQuestionsRetiresPendingSet() async throws {
        let (viewModel, fake) = makeFakeBackedVM()
        fake.responseMap["agent.dismissQuestions"] = [
            "success": true,
            "dismissedQuestionsMessageId": "a1"
        ] as [String: Any]
        viewModel.store.messages = [questionMessage(id: "a1")]
        #expect(viewModel.pendingQuestions != nil)

        await viewModel.dismissQuestions(messageId: "a1")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.dismissQuestions" })
        #expect(sent.params["agentId"] as? String == "test-agent")
        #expect(sent.params["messageId"] as? String == "a1")
        #expect(sent.params["workspaceId"] as? String == "test-ws")
        #expect(viewModel.pendingQuestions == nil, "the dismissed set never re-pends")
    }

    @Test func failedDismissKeepsQuestionsPending() async {
        let (viewModel, fake) = makeFakeBackedVM()
        fake.errorMap["agent.dismissQuestions"] = NSError(domain: "WebSocket", code: -32_000)
        viewModel.store.messages = [questionMessage(id: "a1")]

        await viewModel.dismissQuestions(messageId: "a1")

        #expect(viewModel.pendingQuestions != nil, "a failed dismiss must leave the wizard pending")
    }

    @Test func failedDismissSurfacesVisibleError() async {
        // Regression (intent-hq/monorepo#1800): a failed dismiss must surface
        // an explicit user-visible error, not just silently re-pend the
        // wizard — and the surface must be non-destructive (rollback intact).
        let (viewModel, fake) = makeFakeBackedVM()
        fake.errorMap["agent.dismissQuestions"] = NSError(domain: "WebSocket", code: -32_000)
        viewModel.store.messages = [questionMessage(id: "a1")]
        #expect(viewModel.dismissQuestionsError == nil)

        await viewModel.dismissQuestions(messageId: "a1")

        #expect(
            viewModel.dismissQuestionsError != nil,
            "a failed dismiss surfaces a user-visible error"
        )
        #expect(
            viewModel.pendingQuestions != nil,
            "the error surface is non-destructive — the wizard still re-pends"
        )
    }
}

extension ConversationViewModelTests {
    @Test func successfulDismissRetryClearsPriorError() async {
        // A later successful dismiss must not leave a stale error surfaced.
        let (viewModel, fake) = makeFakeBackedVM()
        fake.errorMap["agent.dismissQuestions"] = NSError(domain: "WebSocket", code: -32_000)
        viewModel.store.messages = [questionMessage(id: "a1")]
        await viewModel.dismissQuestions(messageId: "a1")
        #expect(viewModel.dismissQuestionsError != nil)

        fake.errorMap["agent.dismissQuestions"] = nil
        fake.responseMap["agent.dismissQuestions"] = [
            "success": true,
            "dismissedQuestionsMessageId": "a1"
        ] as [String: Any]
        await viewModel.dismissQuestions(messageId: "a1")

        #expect(
            viewModel.dismissQuestionsError == nil,
            "a successful retry clears the stale error"
        )
        #expect(viewModel.pendingQuestions == nil)
    }

    @Test func newerQuestionSetPendsAfterDismissingOlderOne() async throws {
        let (viewModel, fake) = makeFakeBackedVM()
        fake.responseMap["agent.dismissQuestions"] = [
            "success": true,
            "dismissedQuestionsMessageId": "a1"
        ] as [String: Any]
        viewModel.store.messages = [questionMessage(id: "a1")]
        await viewModel.dismissQuestions(messageId: "a1")

        viewModel.store.messages.append(questionMessage(id: "a2"))

        let set = try #require(viewModel.pendingQuestions)
        #expect(set.messageId == "a2", "a newer question set pends normally")
    }

    @Test func failedSubmitRollsBackOptimisticMessageAndRestoresQuestions() async throws {
        // Regression (PR #55 review): a failed send must not permanently
        // supersede the pending questions — the optimistic user message is
        // rolled back so the wizard re-derives and returns.
        let (viewModel, _) = makeFakeBackedVM(
            sendError: NSError(domain: "WebSocket", code: -32_000)
        )
        viewModel.store.messages = [questionMessage()]
        let answers = try firstAnswer(viewModel)
        #expect(viewModel.pendingQuestions != nil)

        await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

        #expect(viewModel.messages.count == 1, "optimistic user message rolled back")
        #expect(viewModel.messages.last?.role == .assistant)
        #expect(viewModel.isStreaming == false)
        #expect(viewModel.pendingQuestions != nil, "questions re-pend after failure")
    }

    // MARK: - Sticky wizard on the daemon marker (PROTOCOL §5.5 pendingQuestionsMessageId)

    @Test func pendingQuestionsStaysWhileStreamingWhenMarkerNamesQuestionRow() throws {
        let viewModel = makeVM()
        viewModel.store.messages = [questionMessage(id: "a1")]
        viewModel.store.pendingQuestionsMessageId = "a1"
        viewModel.store.isStreaming = true

        let set = try #require(
            viewModel.pendingQuestions,
            "the marked set stays pending while a later turn runs"
        )
        #expect(set.messageId == "a1")
        #expect(viewModel.suggestedPrompts.isEmpty)
    }

    @Test func pendingQuestionsStaysAfterPlainUserMessageWhenMarkerSet() throws {
        let viewModel = makeVM()
        viewModel.store.messages = [
            questionMessage(id: "a1"),
            textMessage(role: .user, text: "unrelated wake")
        ]
        viewModel.store.pendingQuestionsMessageId = "a1"

        let set = try #require(viewModel.pendingQuestions)
        #expect(set.messageId == "a1")
    }

    @Test func pendingQuestionsNilWhenMarkerCleared() {
        let viewModel = makeVM()
        viewModel.store.messages = [questionMessage(id: "a1")]
        viewModel.store.pendingQuestionsMessageId = ""

        #expect(
            viewModel.pendingQuestions == nil,
            "a written-empty marker means nothing pends, even with a question-bearing tail"
        )
    }

    @Test func submitQuestionAnswersHidesWizardBeforeDaemonClearsMarker() async throws {
        // The optimistic answer row mirrors the question_answers tag, so the
        // marker-authoritative gate hides the wizard on Send — before any
        // agent:updated marker clear arrives — and never pops it back in.
        let (viewModel, _) = makeFakeBackedVM()
        viewModel.store.messages = [questionMessage(id: "a1")]
        viewModel.store.pendingQuestionsMessageId = "a1"
        let answers = try firstAnswer(viewModel)

        await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

        let last = try #require(viewModel.messages.last)
        #expect(last.role == .user)
        #expect(last.answeredQuestionsMessageId == "a1")
        #expect(viewModel.store.pendingQuestionsMessageId == "a1", "no daemon update has landed yet")
        #expect(viewModel.pendingQuestions == nil)

        viewModel.store.pendingQuestionsMessageId = ""
        #expect(viewModel.pendingQuestions == nil, "the later marker clear keeps it hidden")
    }

    @Test func submitQuestionAnswersStaysHiddenWhenDaemonAutoQueuesAnswer() async throws {
        // Regression (PR #210 review): when the tagged answer is auto-queued
        // (agent busy / turn startup), the optimistic tagged row is removed
        // from the transcript while the daemon still names the set in
        // pendingQuestionsMessageId — the wizard must not pop back in and
        // invite a duplicate submission. The queue entry's tag counts as the
        // answer until the drain lands the user row / clears the marker.
        let (viewModel, fake) = makeFakeBackedVM()
        fake.responseMap["agent.sendMessage"] = [
            "success": true,
            "queued": true,
            "queuedMessage": [
                "id": "q-1",
                "content": "Q: Which auth method?\nA: OAuth",
                "queuedAt": "2026-01-01T00:00:00Z",
                "position": 0,
                "messageMetadata": [
                    "type": "question_answers",
                    "answeredQuestionsMessageId": "a1"
                ]
            ] as [String: Any]
        ] as [String: Any]
        viewModel.store.messages = [questionMessage(id: "a1")]
        viewModel.store.pendingQuestionsMessageId = "a1"
        viewModel.store.isStreaming = true
        let answers = try firstAnswer(viewModel)

        await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

        #expect(viewModel.messages.count == 1, "the optimistic row moved to the queue panel")
        #expect(viewModel.store.queuedMessages.map(\.id) == ["q-1"])
        #expect(viewModel.store.pendingQuestionsMessageId == "a1", "no daemon update has landed yet")
        #expect(viewModel.pendingQuestions == nil, "the queued tagged answer keeps the wizard hidden")

        // The drain delivers the row and the daemon clears the marker.
        viewModel.store.queuedMessages = []
        viewModel.store.pendingQuestionsMessageId = ""
        #expect(viewModel.pendingQuestions == nil)
    }

    @Test func failedSubmitRePendsMarkedSetAfterRollback() async throws {
        let (viewModel, _) = makeFakeBackedVM(
            sendError: NSError(domain: "WebSocket", code: -32_000)
        )
        viewModel.store.messages = [questionMessage(id: "a1")]
        viewModel.store.pendingQuestionsMessageId = "a1"
        let answers = try firstAnswer(viewModel)

        await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

        #expect(viewModel.messages.count == 1, "the tagged optimistic row is rolled back")
        #expect(viewModel.pendingQuestions?.messageId == "a1", "the marked set re-pends")
    }

    @Test func dismissRetiresMarkedSetWhileMarkerStillSet() async {
        let (viewModel, fake) = makeFakeBackedVM()
        fake.responseMap["agent.dismissQuestions"] = [
            "success": true,
            "dismissedQuestionsMessageId": "a1"
        ] as [String: Any]
        viewModel.store.messages = [questionMessage(id: "a1")]
        viewModel.store.pendingQuestionsMessageId = "a1"
        viewModel.store.isStreaming = true
        #expect(viewModel.pendingQuestions != nil)

        await viewModel.dismissQuestions(messageId: "a1")

        #expect(viewModel.pendingQuestions == nil, "dismissal wins even while the marker still names the set")
    }

    @Test func newerMarkerReplacesWizardContent() {
        let viewModel = makeVM()
        viewModel.store.messages = [
            questionMessage(id: "a1"),
            textMessage(role: .user, text: "answered elsewhere"),
            questionMessage(id: "a2")
        ]
        viewModel.store.pendingQuestionsMessageId = "a1"
        #expect(viewModel.pendingQuestions?.messageId == "a1")

        viewModel.store.pendingQuestionsMessageId = "a2"

        #expect(viewModel.pendingQuestions?.messageId == "a2", "a new marker id keys a new wizard mount")
    }
}
