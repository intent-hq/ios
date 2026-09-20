import Foundation
@testable import Intent
import Testing

private let kQuestionMime = "application/vnd.intent.question+json"

private func questionJSON(attachmentId: String = "tar-0123456789ab", header: String = "Auth method", question: String = "Which auth method?", extras: String = "") -> String {
    """
    {"attachmentId": "\(attachmentId)", "header": "\(header)", \
    "question": "\(question)", \
    "options": [{"label": "OAuth"}, {"label": "API key"}]\(extras)}
    """
}

private func questionBlock(text: String, mimeType: String = kQuestionMime) -> ContentBlock {
    ContentBlock(type: .resource, resource: ResourceContents(uri: "intent-question://q", mimeType: mimeType, text: text))
}

// MARK: - Pending derivation (FE `derivePendingQuestions` parity)

struct PendingQuestionDerivationTests {
    private func assistant(
        blocks: [ContentBlock],
        id: String = "a1",
        streamingState: MessageStreamingState = .unreported
    ) -> ConversationMessage {
        ConversationMessage(
            id: id,
            role: .assistant,
            contentBlocks: blocks,
            streamingState: streamingState,
            contentBlocksWereProvided: true
        )
    }

    private func user(id: String = "u1") -> ConversationMessage {
        ConversationMessage(id: id, role: .user, contentBlocks: [ContentBlock(type: .text, text: "hi")])
    }

    /// A user row carrying the wizard's answer tag on the row `metadata`
    /// (the shape the optimistic send row and the persisted row share).
    private func answerRow(answering messageId: String, id: String = "u-ans") -> ConversationMessage {
        ConversationMessage(
            id: id,
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "Q: Which auth method?\nA: OAuth")],
            metadata: [
                "type": AnyCodable("question_answers"),
                "answeredQuestionsMessageId": AnyCodable(messageId)
            ]
        )
    }

    private func questionAssistant(
        id: String = "a1",
        streamingState: MessageStreamingState = .unreported
    ) -> ConversationMessage {
        assistant(blocks: [questionBlock(text: questionJSON())], id: id, streamingState: streamingState)
    }

    @Test func derivesPendingSetFromLastAssistant() throws {
        let messages = [
            user(),
            assistant(blocks: [
                ContentBlock(type: .text, text: "done"),
                questionBlock(text: questionJSON())
            ])
        ]
        let set = try #require(PendingQuestionSet.derive(messages: messages, isTurnActive: false))
        #expect(set.messageId == "a1")
        #expect(set.questions.count == 1)
        #expect(set.questions[0].attachmentId == "tar-0123456789ab")
    }

    @Test func nilWhenUserMessageSupersedes() {
        let messages = [
            assistant(blocks: [questionBlock(text: questionJSON())]),
            user()
        ]
        #expect(PendingQuestionSet.derive(messages: messages, isTurnActive: false) == nil)
    }

    @Test func nilWhileTurnActive() {
        let messages = [assistant(blocks: [questionBlock(text: questionJSON())])]
        #expect(PendingQuestionSet.derive(messages: messages, isTurnActive: true) == nil)
    }

    @Test func nilWhileShowingPendingUserMessage() {
        let messages = [assistant(blocks: [questionBlock(text: questionJSON())])]
        #expect(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            showingPendingUserMessage: true
        ) == nil)
    }

    @Test func nilWhileLastAssistantStreaming() {
        let messages = [assistant(blocks: [questionBlock(text: questionJSON())], streamingState: .streaming)]
        #expect(PendingQuestionSet.derive(messages: messages, isTurnActive: false) == nil)
    }

    @Test func nilWhenNoMessagesOrNoAssistant() {
        #expect(PendingQuestionSet.derive(messages: [], isTurnActive: false) == nil)
        let systemOnly = [
            ConversationMessage(
                id: "s1",
                role: .system,
                contentBlocks: [],
                contentBlocksWereProvided: true
            )
        ]
        #expect(PendingQuestionSet.derive(messages: systemOnly, isTurnActive: false) == nil)
    }

    @Test func nilWhenNoQuestionBlocks() {
        let messages = [assistant(blocks: [ContentBlock(type: .text, text: "plain")])]
        #expect(PendingQuestionSet.derive(messages: messages, isTurnActive: false) == nil)
    }

    @Test func malformedQuestionBlocksAreSkipped() {
        let messages = [
            assistant(blocks: [
                questionBlock(text: "garbage"),
                questionBlock(text: questionJSON())
            ])
        ]
        let set = PendingQuestionSet.derive(messages: messages, isTurnActive: false)
        #expect(set?.questions.count == 1)
    }

    @Test func dedupesByAttachmentId() {
        let messages = [
            assistant(blocks: [
                questionBlock(text: questionJSON(header: "First")),
                questionBlock(text: questionJSON(header: "Duplicate")),
                questionBlock(text: questionJSON(attachmentId: "tar-ba9876543210", header: "Second"))
            ])
        ]
        let set = PendingQuestionSet.derive(messages: messages, isTurnActive: false)
        #expect(set?.questions.map(\.header) == ["First", "Second"])
    }

    @Test func trailingSystemMessageDoesNotSupersede() throws {
        let messages = [
            assistant(blocks: [questionBlock(text: questionJSON())]),
            ConversationMessage(
                id: "s1",
                role: .system,
                contentBlocks: [],
                contentBlocksWereProvided: true
            )
        ]
        let set = try #require(PendingQuestionSet.derive(messages: messages, isTurnActive: false))
        #expect(set.messageId == "a1")
    }
}

extension PendingQuestionDerivationTests {
    // MARK: - Dismissal marker (FE `wizard-gate.ts` parity)

    @Test func nilWhenDismissalMarkerMatches() {
        let messages = [assistant(blocks: [questionBlock(text: questionJSON())], id: "a1")]
        #expect(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            dismissedQuestionsMessageId: "a1"
        ) == nil)
    }

    @Test func newerQuestionSetPendsDespiteOlderDismissalMarker() throws {
        let messages = [assistant(blocks: [questionBlock(text: questionJSON())], id: "a2")]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            dismissedQuestionsMessageId: "a1"
        ))
        #expect(set.messageId == "a2")
    }

    @Test func nilMarkerLeavesDerivationUnchanged() throws {
        let messages = [assistant(blocks: [questionBlock(text: questionJSON())], id: "a1")]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            dismissedQuestionsMessageId: nil
        ))
        #expect(set.messageId == "a1")
    }

    // MARK: - Pending marker (FE `classifyPendingQuestionMarker` / marker authority parity)

    @Test func markerSetPendsWhileTurnActive() throws {
        let messages = [user(), questionAssistant(id: "a1")]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: true,
            pendingQuestionsMessageId: "a1"
        ))
        #expect(set.messageId == "a1")
        #expect(set.questions.map(\.attachmentId) == ["tar-0123456789ab"])
    }

    @Test func markerSetPendsDespiteLaterPlainUserMessage() throws {
        let messages = [questionAssistant(id: "a1"), user(id: "u2")]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            pendingQuestionsMessageId: "a1"
        ))
        #expect(set.messageId == "a1")
    }

    @Test func markerSetPendsDespiteLaterAssistantTurn() throws {
        let messages = [
            questionAssistant(id: "a1"),
            user(id: "u2"),
            assistant(blocks: [ContentBlock(type: .text, text: "later turn")], id: "a2", streamingState: .streaming),
            ConversationMessage(
                id: "s1",
                role: .system,
                contentBlocks: [],
                contentBlocksWereProvided: true
            )
        ]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: true,
            pendingQuestionsMessageId: "a1"
        ))
        #expect(set.messageId == "a1")
    }

    @Test func markerSetSelectsMarkedRowOverQuestionBearingTail() throws {
        let messages = [
            questionAssistant(id: "a1"),
            user(id: "u2"),
            assistant(blocks: [
                questionBlock(text: questionJSON(attachmentId: "tar-ba9876543210", header: "Newer"))
            ], id: "a2")
        ]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            pendingQuestionsMessageId: "a1"
        ))
        #expect(set.messageId == "a1")
        #expect(set.questions.map(\.header) == ["Auth method"])
    }

    @Test func markerClearedIsNilEvenWithQuestionBearingTail() {
        let messages = [user(), questionAssistant(id: "a1")]
        #expect(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            pendingQuestionsMessageId: ""
        ) == nil)
    }

    @Test func markerSetNilOnceTaggedAnswerRowNamesIt() {
        let messages = [questionAssistant(id: "a1"), answerRow(answering: "a1")]
        #expect(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            pendingQuestionsMessageId: "a1"
        ) == nil)
    }

    @Test func markerSetNilWhenAnswerTagRidesTextBlockMessageMetadata() {
        let tagged = ConversationMessage(
            id: "u-ans",
            role: .user,
            contentBlocks: [
                ContentBlock(
                    type: .text,
                    text: "Q: Which auth method?\nA: OAuth",
                    messageMetadata: [
                        "type": AnyCodable("question_answers"),
                        "answeredQuestionsMessageId": AnyCodable("a1")
                    ]
                )
            ]
        )
        let messages = [questionAssistant(id: "a1"), tagged]
        #expect(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            pendingQuestionsMessageId: "a1"
        ) == nil)
    }

    @Test func markerSetIgnoresAnswerRowNamingAnotherSet() throws {
        let messages = [questionAssistant(id: "a1"), answerRow(answering: "a0")]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            pendingQuestionsMessageId: "a1"
        ))
        #expect(set.messageId == "a1")
    }

    @Test func markerSetNilWhenQueuedAnswerNamesIt() {
        // The daemon auto-queued the tagged answer mid-turn: the optimistic
        // row is gone and the only local tag lives on the queue entry.
        let messages = [questionAssistant(id: "a1")]
        #expect(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: true,
            pendingQuestionsMessageId: "a1",
            queuedAnsweredQuestionsMessageIds: ["a1"]
        ) == nil)
    }

    @Test func markerSetPendsWhenQueuedAnswerNamesAnotherSet() throws {
        let messages = [questionAssistant(id: "a1")]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            pendingQuestionsMessageId: "a1",
            queuedAnsweredQuestionsMessageIds: ["a0"]
        ))
        #expect(set.messageId == "a1")
    }
}

extension PendingQuestionDerivationTests {
    @Test func queuedMessageAnsweredQuestionsMessageIdReadsTagOnly() {
        func queued(_ metadata: [String: AnyCodable] = [:]) -> QueuedMessage {
            QueuedMessage(
                id: "q",
                content: "x",
                queuedAt: "t",
                position: 0,
                messageMetadata: metadata
            )
        }
        #expect(queued([
            "type": AnyCodable("question_answers"),
            "answeredQuestionsMessageId": AnyCodable("a1")
        ]).answeredQuestionsMessageId == "a1")
        #expect(queued().answeredQuestionsMessageId == nil)
        #expect(queued([
            "type": AnyCodable("agent_message"),
            "answeredQuestionsMessageId": AnyCodable("a1")
        ]).answeredQuestionsMessageId == nil)
        #expect(queued([
            "type": AnyCodable("question_answers"),
            "answeredQuestionsMessageId": AnyCodable("")
        ]).answeredQuestionsMessageId == nil)
    }

    @Test func markerSetIgnoresAnswerTagOnNonUserRow() throws {
        let taggedAssistant = ConversationMessage(
            id: "a2",
            role: .assistant,
            contentBlocks: [ContentBlock(type: .text, text: "echo")],
            metadata: [
                "type": AnyCodable("question_answers"),
                "answeredQuestionsMessageId": AnyCodable("a1")
            ]
        )
        let messages = [questionAssistant(id: "a1"), taggedAssistant]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            pendingQuestionsMessageId: "a1"
        ))
        #expect(set.messageId == "a1")
    }

    @Test func markerSetNilWhenDismissalMarkerMatches() {
        let messages = [questionAssistant(id: "a1")]
        #expect(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            dismissedQuestionsMessageId: "a1",
            pendingQuestionsMessageId: "a1"
        ) == nil)
    }

    @Test func markerSetPendsWhenDismissalMarkerNamesOlderSet() throws {
        let messages = [questionAssistant(id: "a2")]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            dismissedQuestionsMessageId: "a1",
            pendingQuestionsMessageId: "a2"
        ))
        #expect(set.messageId == "a2")
    }

    @Test func markerSetNilWhileMarkedRowStreaming() {
        let messages = [questionAssistant(id: "a1", streamingState: .streaming)]
        #expect(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            pendingQuestionsMessageId: "a1"
        ) == nil)
    }

    @Test func markerSetNilWhenMarkedRowMissing() {
        let messages = [questionAssistant(id: "a1")]
        #expect(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            pendingQuestionsMessageId: "a-gone"
        ) == nil)
    }

    @Test func markerSetNilWhenMarkedRowIsNotAssistant() {
        let messages = [
            ConversationMessage(id: "u1", role: .user, contentBlocks: [questionBlock(text: questionJSON())])
        ]
        #expect(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            pendingQuestionsMessageId: "u1"
        ) == nil)
    }

    @Test func markerSetNilWhenMarkedRowHasNoValidQuestions() {
        let messages = [
            assistant(blocks: [
                ContentBlock(type: .text, text: "plain"),
                questionBlock(text: "garbage")
            ], id: "a1")
        ]
        #expect(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            pendingQuestionsMessageId: "a1"
        ) == nil)
    }

    @Test func markerSetNilWhileShowingPendingUserMessage() {
        let messages = [questionAssistant(id: "a1")]
        #expect(PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            showingPendingUserMessage: true,
            pendingQuestionsMessageId: "a1"
        ) == nil)
    }

    @Test func markerSetNilOnEmptyTranscript() {
        #expect(PendingQuestionSet.derive(
            messages: [],
            isTurnActive: false,
            pendingQuestionsMessageId: "a1"
        ) == nil)
    }

    @Test func markerSetDedupesByAttachmentId() {
        let messages = [
            assistant(blocks: [
                questionBlock(text: questionJSON(header: "First")),
                questionBlock(text: questionJSON(header: "Duplicate")),
                questionBlock(text: questionJSON(attachmentId: "tar-ba9876543210", header: "Second"))
            ], id: "a1")
        ]
        let set = PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            pendingQuestionsMessageId: "a1"
        )
        #expect(set?.questions.map(\.header) == ["First", "Second"])
    }

    @Test func markerStateClassification() {
        #expect(PendingQuestionSet.MarkerState(nil) == .absent)
        #expect(PendingQuestionSet.MarkerState("") == .cleared)
        #expect(PendingQuestionSet.MarkerState("a1") == .set(messageId: "a1"))
    }

    @Test func answeredQuestionsMessageIdRejectsWrongTypeOrEmptyId() {
        let wrongType = ConversationMessage(
            id: "u1",
            role: .user,
            metadata: [
                "type": AnyCodable("questions_dismissed"),
                "answeredQuestionsMessageId": AnyCodable("a1")
            ]
        )
        let emptyId = ConversationMessage(
            id: "u2",
            role: .user,
            metadata: [
                "type": AnyCodable("question_answers"),
                "answeredQuestionsMessageId": AnyCodable("")
            ]
        )
        #expect(wrongType.answeredQuestionsMessageId == nil)
        #expect(emptyId.answeredQuestionsMessageId == nil)
        #expect(answerRow(answering: "a1").answeredQuestionsMessageId == "a1")
    }
}
