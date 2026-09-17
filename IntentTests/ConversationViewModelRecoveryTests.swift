import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing
import UIKit

extension ConversationViewModelTests {
    // MARK: - Marked question recovery (row outside the loaded page, Phase 2)

    /// A loaded page that does NOT contain the marked row `a1`.
    private func offPageTranscript() -> [ConversationMessage] {
        [
            textMessage(role: .user, text: "later wake", id: "u9"),
            textMessage(
                role: .assistant,
                text: "Done\n<!-- suggested-prompts\nRun tests\n-->",
                id: "a9"
            )
        ]
    }

    @Test func recoveredMarkedSetRendersWhenRowIsOffPage() throws {
        let viewModel = makeVM()
        viewModel.store.messages = offPageTranscript()
        viewModel.store.pendingQuestionsMessageId = "a1"
        viewModel.store.pendingQuestionRecovery = PendingQuestionRecovery(
            messageId: "a1",
            status: .found,
            message: questionMessage(id: "a1")
        )

        let set = try #require(viewModel.pendingQuestions, "the recovered row feeds the wizard")
        #expect(set.messageId == "a1")
        #expect(set.questions.count == 1)
        #expect(viewModel.isPendingQuestionRecoveryLoading == false)
        #expect(viewModel.suggestedPrompts.isEmpty, "prompts stay hidden while the wizard pends")
    }

    @Test func recoveredMarkedSetStaysWhileStreaming() {
        let viewModel = makeVM()
        viewModel.store.messages = offPageTranscript()
        viewModel.store.pendingQuestionsMessageId = "a1"
        viewModel.store.pendingQuestionRecovery = PendingQuestionRecovery(
            messageId: "a1",
            status: .found,
            message: questionMessage(id: "a1")
        )
        viewModel.store.isStreaming = true

        #expect(viewModel.pendingQuestions?.messageId == "a1", "marker authority applies to the recovered copy")
    }

    @Test func recoveredMarkedSetAnswersLikeResidentOne() async throws {
        let (viewModel, fake) = makeFakeBackedVM()
        viewModel.store.messages = offPageTranscript()
        viewModel.store.pendingQuestionsMessageId = "a1"
        viewModel.store.pendingQuestionRecovery = PendingQuestionRecovery(
            messageId: "a1",
            status: .found,
            message: questionMessage(id: "a1")
        )
        let answers = try firstAnswer(viewModel)

        await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        let metadata = try #require(sent.params["messageMetadata"] as? [String: Any])
        #expect(metadata["answeredQuestionsMessageId"] as? String == "a1")
        #expect(viewModel.messages.last?.answeredQuestionsMessageId == "a1")
        #expect(viewModel.pendingQuestions == nil, "the tagged optimistic row hides the recovered wizard")
        #expect(
            viewModel.isPendingQuestionRecoveryLoading == false,
            "an answered recovered set does not fail closed"
        )
        #expect(viewModel.store.pendingQuestionsMessageId == "a1", "no daemon update has landed yet")

        viewModel.store.pendingQuestionsMessageId = ""
        #expect(viewModel.pendingQuestions == nil)
        #expect(viewModel.isPendingQuestionRecoveryLoading == false)
    }

    @Test func recoveredMarkedSetHiddenByQueuedTaggedAnswer() {
        let viewModel = makeVM()
        viewModel.store.messages = offPageTranscript()
        viewModel.store.pendingQuestionsMessageId = "a1"
        viewModel.store.pendingQuestionRecovery = PendingQuestionRecovery(
            messageId: "a1",
            status: .found,
            message: questionMessage(id: "a1")
        )
        viewModel.store.queuedMessages = [
            queuedEntry(id: "q-1", metadata: [
                "type": AnyCodable("question_answers"),
                "answeredQuestionsMessageId": AnyCodable("a1")
            ])
        ]

        #expect(viewModel.pendingQuestions == nil, "the queued tagged answer bridge applies to the recovered copy")
        #expect(viewModel.isPendingQuestionRecoveryLoading == false)
    }

    @Test func recoveredMarkedSetDismissesLikeResidentOne() async {
        let (viewModel, fake) = makeFakeBackedVM()
        fake.responseMap["agent.dismissQuestions"] = [
            "success": true,
            "dismissedQuestionsMessageId": "a1"
        ] as [String: Any]
        viewModel.store.messages = offPageTranscript()
        viewModel.store.pendingQuestionsMessageId = "a1"
        viewModel.store.pendingQuestionRecovery = PendingQuestionRecovery(
            messageId: "a1",
            status: .found,
            message: questionMessage(id: "a1")
        )
        #expect(viewModel.pendingQuestions != nil)

        await viewModel.dismissQuestions(messageId: "a1")

        #expect(viewModel.pendingQuestions == nil, "the dismissed recovered set never re-pends")
        #expect(
            viewModel.isPendingQuestionRecoveryLoading == false,
            "a dismissed recovered set does not fail closed"
        )
        #expect(viewModel.suggestedPrompts == ["Run tests"], "the ordinary composer slot is back")
    }

    @Test func recoveryLoadingHidesPromptsAndFailsClosed() {
        let viewModel = makeVM()
        viewModel.store.messages = offPageTranscript()
        viewModel.store.pendingQuestionsMessageId = "a1"
        viewModel.store.pendingQuestionRecovery = PendingQuestionRecovery(messageId: "a1", status: .loading)

        #expect(viewModel.pendingQuestions == nil, "nothing to render yet")
        #expect(viewModel.isPendingQuestionRecoveryLoading, "composer withheld while the seek is in flight")
        #expect(viewModel.suggestedPrompts.isEmpty, "prompts withheld while the seek is in flight")
    }

    @Test func recoveryNotFoundStaysFailClosedUntilMarkerCleared() {
        // Exhaustion ends the network retries, not marker authority: the
        // composer stays withheld until the daemon clears/replaces the marker.
        let viewModel = makeVM()
        viewModel.store.messages = offPageTranscript()
        viewModel.store.pendingQuestionsMessageId = "a1"
        viewModel.store.pendingQuestionRecovery = PendingQuestionRecovery(messageId: "a1", status: .notFound)

        #expect(viewModel.pendingQuestions == nil)
        #expect(viewModel.isPendingQuestionRecoveryLoading, "not-found still fails closed")
        #expect(viewModel.suggestedPrompts.isEmpty)

        viewModel.store.pendingQuestionRecovery = PendingQuestionRecovery(messageId: "a1", status: .error)
        #expect(viewModel.isPendingQuestionRecoveryLoading, "exhausted retries still fail closed")

        viewModel.store.pendingQuestionsMessageId = ""
        viewModel.store.pendingQuestionRecovery = nil
        #expect(viewModel.isPendingQuestionRecoveryLoading == false, "the marker clear reopens the composer")
        #expect(viewModel.suggestedPrompts == ["Run tests"])
    }

    @Test func recoveryFailsClosedBeforeStoreSeekStarts() {
        // Marker set, row not resident, store has not started a seek — still
        // fail closed (the store issues the seek on its next reconcile).
        let viewModel = makeVM()
        viewModel.store.messages = offPageTranscript()
        viewModel.store.pendingQuestionsMessageId = "a1"
        viewModel.store.pendingQuestionRecovery = nil

        #expect(viewModel.isPendingQuestionRecoveryLoading, "marker authority fails closed even before the seek starts")
    }

    @Test func recoveryLoadingFalseWhileInitialFetchInFlight() {
        // The row may simply not have loaded yet: no fail-closed gate (and no
        // placeholder) until the initial transcript fetch has settled.
        let viewModel = makeVM()
        viewModel.store.messages = []
        viewModel.store.isLoading = true
        viewModel.store.pendingQuestionsMessageId = "a1"

        #expect(viewModel.isPendingQuestionRecoveryLoading == false)

        viewModel.store.isLoading = false
        #expect(viewModel.isPendingQuestionRecoveryLoading, "settled fetch without the row fails closed")
    }

    @Test func recoveryLoadingFalseWhenMarkedRowIsResident() {
        let viewModel = makeVM()
        viewModel.store.messages = [questionMessage(id: "a1")]
        viewModel.store.pendingQuestionsMessageId = "a1"

        #expect(viewModel.pendingQuestions?.messageId == "a1")
        #expect(viewModel.isPendingQuestionRecoveryLoading == false)
    }

    @Test func recoveryLoadingFalseWithoutMarker() {
        let viewModel = makeVM()
        viewModel.store.messages = offPageTranscript()
        #expect(viewModel.isPendingQuestionRecoveryLoading == false, "legacy path: no marker, no gate")
        #expect(viewModel.suggestedPrompts == ["Run tests"])

        viewModel.store.pendingQuestionsMessageId = ""
        #expect(viewModel.isPendingQuestionRecoveryLoading == false, "cleared marker: no gate")
    }

    @Test func residentRowPreferredOverStaleRecoveredCopy() throws {
        // The recovered copy is superseded once the row is in the transcript:
        // the resident row (with its current content) drives the wizard.
        let viewModel = makeVM()
        let staleCopy = ConversationMessage(
            id: "a1",
            role: .assistant,
            contentBlocks: [questionResourceBlock(attachmentId: "tar-stale00000000", question: "Stale?")]
        )
        viewModel.store.messages = [
            questionMessage(id: "a1"),
            textMessage(role: .user, text: "later wake", id: "u9")
        ]
        viewModel.store.pendingQuestionsMessageId = "a1"
        viewModel.store.pendingQuestionRecovery = PendingQuestionRecovery(
            messageId: "a1",
            status: .found,
            message: staleCopy
        )

        let set = try #require(viewModel.pendingQuestions)
        #expect(set.questions.map(\.attachmentId) == ["tar-0123456789ab"], "the resident row wins")
        #expect(viewModel.isPendingQuestionRecoveryLoading == false)
    }

    @Test func recoveredCopyForAnotherMarkerIdIsIgnored() {
        // A recovery that settled for a previous marker id must not render
        // under a newer marker (the store drops it on reconcile; the view
        // model never trusts a mismatched id either).
        let viewModel = makeVM()
        viewModel.store.messages = offPageTranscript()
        viewModel.store.pendingQuestionsMessageId = "a2"
        viewModel.store.pendingQuestionRecovery = PendingQuestionRecovery(
            messageId: "a1",
            status: .found,
            message: questionMessage(id: "a1")
        )

        #expect(viewModel.pendingQuestions == nil)
        #expect(viewModel.isPendingQuestionRecoveryLoading, "the new marker fails closed until its own seek settles")
    }
}

extension ConversationViewModelTests {
    @Test func recoveredRowWithoutQuestionsStaysFailClosed() {
        // Found, but the row carries no valid question set: nothing can
        // render, so the composer stays withheld under marker authority.
        let viewModel = makeVM()
        viewModel.store.messages = offPageTranscript()
        viewModel.store.pendingQuestionsMessageId = "a1"
        viewModel.store.pendingQuestionRecovery = PendingQuestionRecovery(
            messageId: "a1",
            status: .found,
            message: textMessage(role: .assistant, text: "no questions here", id: "a1")
        )

        #expect(viewModel.pendingQuestions == nil)
        #expect(viewModel.isPendingQuestionRecoveryLoading)
    }

    @Test func recoveredSetRendersThroughStoreSeek() async throws {
        // End to end through the store: the marker push names an off-page
        // row, the seek recovers it, and the wizard renders from the copy.
        let viewModel = makeVM()
        let fake = FakeConnectionManager()
        let questionJSON = """
        {"attachmentId": "tar-0123456789ab", "header": "Auth", \
        "question": "Which auth method?", \
        "options": [{"label": "OAuth"}, {"label": "API key"}]}
        """
        let resourceBlock: [String: Any] = [
            "type": "resource",
            "resource": [
                "uri": "intent-question://q",
                "mimeType": Question.resourceMimeType,
                "text": questionJSON
            ] as [String: Any]
        ]
        let pageRow: [String: Any] = [
            "id": "u9",
            "role": "user",
            "timestamp": "2024-01-01T00:00:00Z",
            "contentBlocks": [["type": "text", "id": "u9:0", "text": "later wake"] as [String: Any]]
        ]
        let markedRow: [String: Any] = [
            "id": "a1",
            "role": "assistant",
            "timestamp": "2024-01-01T00:00:00Z",
            "contentBlocks": [resourceBlock]
        ]
        fake.responseQueueMap["agent.getConversation"] = [
            ["messages": [pageRow]] as [String: Any],
            ["messages": [markedRow]] as [String: Any]
        ]
        viewModel.store = ConversationStore(connectionManager: fake)
        await viewModel.store.fetchConversation(agentId: "test-agent", workspaceId: "test-ws")
        #expect(viewModel.isPendingQuestionRecoveryLoading == false)

        viewModel.store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:updated",
                "data": [
                    "agentId": "test-agent",
                    "pendingQuestionsMessageId": "a1"
                ]
            ] as [String: Any]
        ])
        #expect(viewModel.pendingQuestions == nil)
        #expect(viewModel.isPendingQuestionRecoveryLoading, "fails closed while the seek is in flight")
        try await waitUntil("the seek to settle") { !viewModel.isPendingQuestionRecoveryLoading }

        let set = try #require(viewModel.pendingQuestions, "the recovered row renders the wizard")
        #expect(set.messageId == "a1")
        #expect(set.questions.map(\.attachmentId) == ["tar-0123456789ab"])
        #expect(viewModel.isPendingQuestionRecoveryLoading == false)
    }

    // MARK: - Suggested-prompt send (draft retention)

    @Test func sendSuggestedPromptDoesNotAttachPendingImages() async throws {
        // Regression: draft attachments must not silently ride a suggested
        // prompt — the prompt sends text only.
        let (viewModel, fake) = makeFakeBackedVM()
        viewModel.addImage(try #require(UIImage(systemName: "star")))

        await viewModel.sendSuggestedPrompt("Run the tests")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        #expect(sent.params["imageBlocks"] == nil)
        #expect(viewModel.pendingImages.count == 1, "pending images stay attached to the draft")
    }

    @Test func sendSuggestedPromptLeavesDraftIntact() async {
        // Regression: a suggested-prompt send must not clear the persisted
        // composer draft or the on-screen draft text.
        let (viewModel, _) = makeFakeBackedVM()
        PersistenceManager.shared.saveDraft(
            "half-typed draft",
            workspaceId: viewModel.workspaceId,
            agentId: viewModel.agentId
        )
        viewModel.messageText = "half-typed draft"

        await viewModel.sendSuggestedPrompt("Run the tests")

        #expect(viewModel.messageText == "half-typed draft")
        #expect(PersistenceManager.shared.loadDraft(
            workspaceId: viewModel.workspaceId,
            agentId: viewModel.agentId
        ) == "half-typed draft")
        PersistenceManager.shared.clearDraft(workspaceId: viewModel.workspaceId, agentId: viewModel.agentId)
    }

    @Test func sendMessageStillClearsDraftAndUsesExplicitImages() async throws {
        // The normal composer path is unchanged: explicit images are sent and
        // the persisted draft is cleared after a successful send.
        let (viewModel, fake) = makeFakeBackedVM()
        PersistenceManager.shared.saveDraft(
            "outgoing",
            workspaceId: viewModel.workspaceId,
            agentId: viewModel.agentId
        )

        await viewModel.sendMessage("outgoing", images: [try #require(UIImage(systemName: "star"))])

        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        #expect(sent.params["imageBlocks"] != nil)
        #expect(PersistenceManager.shared.loadDraft(
            workspaceId: viewModel.workspaceId,
            agentId: viewModel.agentId
        ).isEmpty)
    }
}
