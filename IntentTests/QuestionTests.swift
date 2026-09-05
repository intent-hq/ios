import Foundation
import Testing
@testable import Intent

// MARK: - Shared fixtures

private let questionMime = "application/vnd.intent.question+json"

private func questionJSON(
    attachmentId: String = "tar-0123456789ab",
    header: String = "Auth method",
    question: String = "Which auth method?",
    extras: String = ""
) -> String {
    """
    {"attachmentId": "\(attachmentId)", "header": "\(header)", \
    "question": "\(question)", \
    "options": [{"label": "OAuth"}, {"label": "API key"}]\(extras)}
    """
}

private func decodeBlock(_ json: String) throws -> ContentBlock {
    try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
}

private func questionBlock(text: String, mimeType: String = questionMime) -> ContentBlock {
    ContentBlock(
        type: .resource,
        resource: ResourceContents(uri: "intent-question://q", mimeType: mimeType, text: text)
    )
}

private func parseQuestion(_ json: String) -> Question? {
    try? JSONDecoder().decode(Question.self, from: Data(json.utf8))
}

// MARK: - Resource block decoding

struct ResourceBlockDecodingTests {
    @Test func decodesResourceBlock() throws {
        let block = try decodeBlock("""
        {"type": "resource", "resource": {"uri": "intent-question://q", \
        "mimeType": "\(questionMime)", "text": "{}"}}
        """)
        #expect(block.type == .resource)
        #expect(block.resource?.uri == "intent-question://q")
        #expect(block.resource?.mimeType == questionMime)
        #expect(block.resource?.text == "{}")
    }

    @Test func resourceWithoutContentsStillDecodes() throws {
        let block = try decodeBlock("{\"type\": \"resource\"}")
        #expect(block.type == .resource)
        #expect(block.resource == nil)
    }

    @Test func unknownTypeStillFallsBackToText() throws {
        let block = try decodeBlock("{\"type\": \"bogus\", \"text\": \"hi\"}")
        #expect(block.type == .text)
        #expect(block.resolvedText == "hi")
    }

    /// The ConversationStore decode paths (`parseMessage` for snapshots,
    /// `upsertChatBlock` for deltas) both funnel through
    /// `JSONDecoder().decode(ContentBlock.self, ...)` — this asserts resource
    /// blocks survive the snapshot path.
    @Test func resourceBlockSurvivesParseMessage() throws {
        let dict: [String: Any] = [
            "id": "msg-1", "role": "assistant", "timestamp": "2026-01-01T00:00:00Z",
            "contentBlocks": [
                ["type": "text", "text": "hello"],
                ["type": "resource",
                 "resource": ["mimeType": questionMime, "text": questionJSON()]],
            ],
        ]
        let msg = try #require(ConversationMessage.parseMessage(dict))
        let blocks = try #require(msg.contentBlocks)
        #expect(blocks.count == 2)
        #expect(blocks[1].type == .resource)
        #expect(Question.question(from: blocks[1])?.header == "Auth method")
    }
}

// MARK: - Question payload validation (FE `isQuestion` parity)

struct QuestionValidationTests {
    @Test func decodesFullPayload() throws {
        let q = try #require(parseQuestion("""
        {"attachmentId": "tar-0123456789ab", "header": "Auth", "question": "Which?", \
        "explanation": "Because", "multiSelect": true, "options": [\
        {"label": "A", "description": "first"}, {"label": "B"}]}
        """))
        #expect(q.attachmentId == "tar-0123456789ab")
        #expect(q.explanation == "Because")
        #expect(q.multiSelect == true)
        #expect(q.options == [
            QuestionOption(label: "A", description: "first"),
            QuestionOption(label: "B"),
        ])
    }

    @Test func minimalPayloadDefaultsMultiSelectFalse() throws {
        let q = try #require(parseQuestion(questionJSON()))
        #expect(q.explanation == nil)
        #expect(q.multiSelect == false)
    }

    @Test func extraKeysAreAllowed() {
        #expect(parseQuestion(questionJSON(extras: ", \"unknownKey\": 1")) != nil)
    }

    @Test func emptyAttachmentIdAllowed() {
        // FE parity: isQuestion only checks typeof string for attachmentId.
        #expect(parseQuestion(questionJSON(attachmentId: "")) != nil)
    }

    @Test func rejectsMissingAttachmentId() {
        #expect(parseQuestion("""
        {"header": "H", "question": "Q?", "options": [{"label": "A"}, {"label": "B"}]}
        """) == nil)
    }

    @Test func rejectsNonStringAttachmentId() {
        #expect(parseQuestion("""
        {"attachmentId": 1, "header": "H", "question": "Q?", \
        "options": [{"label": "A"}, {"label": "B"}]}
        """) == nil)
    }

    @Test func rejectsEmptyHeader() {
        #expect(parseQuestion(questionJSON(header: "")) == nil)
    }

    @Test func rejectsEmptyQuestion() {
        #expect(parseQuestion(questionJSON(question: "")) == nil)
    }

    @Test func rejectsNullExplanation() {
        #expect(parseQuestion(questionJSON(extras: ", \"explanation\": null")) == nil)
    }

    @Test func rejectsNumericMultiSelect() {
        #expect(parseQuestion(questionJSON(extras: ", \"multiSelect\": 1")) == nil)
    }

    @Test func rejectsNullMultiSelect() {
        #expect(parseQuestion(questionJSON(extras: ", \"multiSelect\": null")) == nil)
    }

    @Test func rejectsSingleOption() {
        #expect(parseQuestion("""
        {"attachmentId": "tar-0123456789ab", "header": "H", "question": "Q?", \
        "options": [{"label": "A"}]}
        """) == nil)
    }

    @Test func rejectsEmptyOptionLabel() {
        #expect(parseQuestion("""
        {"attachmentId": "tar-0123456789ab", "header": "H", "question": "Q?", \
        "options": [{"label": ""}, {"label": "B"}]}
        """) == nil)
    }

    @Test func rejectsNullOptionDescription() {
        #expect(parseQuestion("""
        {"attachmentId": "tar-0123456789ab", "header": "H", "question": "Q?", \
        "options": [{"label": "A", "description": null}, {"label": "B"}]}
        """) == nil)
    }

    @Test func rejectsNonArrayOptions() {
        #expect(parseQuestion(questionJSON()
            .replacingOccurrences(
                of: "[{\"label\": \"OAuth\"}, {\"label\": \"API key\"}]",
                with: "\"nope\"")) == nil)
    }

    @Test func rejectsMalformedJSON() {
        #expect(parseQuestion("not json") == nil)
        #expect(parseQuestion("[1, 2]") == nil)
    }
}

// MARK: - Parsing helpers (MIME-only strip + question(from:))

struct QuestionParsingHelperTests {
    @Test func isQuestionResourceBlockIsMimeOnly() {
        // Malformed payload is still a question resource block (must be stripped).
        #expect(Question.isQuestionResourceBlock(questionBlock(text: "garbage")))
        #expect(Question.isQuestionResourceBlock(questionBlock(text: questionJSON())))
    }

    @Test func isQuestionResourceBlockRejectsOtherMimeAndTypes() {
        #expect(!Question.isQuestionResourceBlock(questionBlock(text: "{}", mimeType: "text/plain")))
        #expect(!Question.isQuestionResourceBlock(ContentBlock(type: .text, text: "hi")))
        #expect(!Question.isQuestionResourceBlock(ContentBlock(type: .resource)))
    }

    @Test func questionFromValidBlock() throws {
        let q = try #require(Question.question(from: questionBlock(text: questionJSON())))
        #expect(q.question == "Which auth method?")
        #expect(q.options.count == 2)
    }

    @Test func questionFromMalformedOrWrongMimeIsNil() {
        #expect(Question.question(from: questionBlock(text: "garbage")) == nil)
        #expect(Question.question(from: questionBlock(text: questionJSON(), mimeType: "text/plain")) == nil)
        #expect(Question.question(from: ContentBlock(type: .resource)) == nil)
    }

    @Test func questionFromMetadataResourceFallback() throws {
        let block = ContentBlock(
            id: "b1", type: .resource,
            metadata: ["resource": AnyCodable([
                "mimeType": questionMime, "text": questionJSON(),
            ] as [String: Any])]
        )
        let q = try #require(Question.question(from: block))
        #expect(q.attachmentId == "tar-0123456789ab")
    }
}

// MARK: - Pending derivation (FE `derivePendingQuestions` parity)

struct PendingQuestionDerivationTests {
    private func assistant(
        id: String = "a1", blocks: [ContentBlock], isStreaming: Bool? = nil
    ) -> ConversationMessage {
        ConversationMessage(id: id, role: .assistant, contentBlocks: blocks, isStreaming: isStreaming)
    }

    private func user(id: String = "u1") -> ConversationMessage {
        ConversationMessage(id: id, role: .user, contentBlocks: [ContentBlock(type: .text, text: "hi")])
    }

    /// A user row carrying the wizard's answer tag on the row `metadata`
    /// (the shape the optimistic send row and the persisted row share).
    private func answerRow(id: String = "u-ans", answering messageId: String) -> ConversationMessage {
        ConversationMessage(
            id: id, role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "Q: Which auth method?\nA: OAuth")],
            metadata: [
                "type": AnyCodable("question_answers"),
                "answeredQuestionsMessageId": AnyCodable(messageId),
            ])
    }

    private func questionAssistant(id: String = "a1", isStreaming: Bool? = nil) -> ConversationMessage {
        assistant(id: id, blocks: [questionBlock(text: questionJSON())], isStreaming: isStreaming)
    }

    @Test func derivesPendingSetFromLastAssistant() throws {
        let messages = [
            user(),
            assistant(blocks: [
                ContentBlock(type: .text, text: "done"),
                questionBlock(text: questionJSON()),
            ]),
        ]
        let set = try #require(PendingQuestionSet.derive(messages: messages, isTurnActive: false))
        #expect(set.messageId == "a1")
        #expect(set.questions.count == 1)
        #expect(set.questions[0].attachmentId == "tar-0123456789ab")
    }

    @Test func nilWhenUserMessageSupersedes() {
        let messages = [
            assistant(blocks: [questionBlock(text: questionJSON())]),
            user(),
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
            messages: messages, isTurnActive: false, showingPendingUserMessage: true) == nil)
    }

    @Test func nilWhileLastAssistantStreaming() {
        let messages = [assistant(blocks: [questionBlock(text: questionJSON())], isStreaming: true)]
        #expect(PendingQuestionSet.derive(messages: messages, isTurnActive: false) == nil)
    }

    @Test func nilWhenNoMessagesOrNoAssistant() {
        #expect(PendingQuestionSet.derive(messages: [], isTurnActive: false) == nil)
        let systemOnly = [ConversationMessage(id: "s1", role: .system, contentBlocks: [])]
        #expect(PendingQuestionSet.derive(messages: systemOnly, isTurnActive: false) == nil)
    }

    @Test func nilWhenNoQuestionBlocks() {
        let messages = [assistant(blocks: [ContentBlock(type: .text, text: "plain")])]
        #expect(PendingQuestionSet.derive(messages: messages, isTurnActive: false) == nil)
    }

    @Test func malformedQuestionBlocksAreSkipped() {
        let messages = [assistant(blocks: [
            questionBlock(text: "garbage"),
            questionBlock(text: questionJSON()),
        ])]
        let set = PendingQuestionSet.derive(messages: messages, isTurnActive: false)
        #expect(set?.questions.count == 1)
    }

    @Test func dedupesByAttachmentId() {
        let messages = [assistant(blocks: [
            questionBlock(text: questionJSON(header: "First")),
            questionBlock(text: questionJSON(header: "Duplicate")),
            questionBlock(text: questionJSON(attachmentId: "tar-ba9876543210", header: "Second")),
        ])]
        let set = PendingQuestionSet.derive(messages: messages, isTurnActive: false)
        #expect(set?.questions.map(\.header) == ["First", "Second"])
    }

    @Test func trailingSystemMessageDoesNotSupersede() throws {
        let messages = [
            assistant(blocks: [questionBlock(text: questionJSON())]),
            ConversationMessage(id: "s1", role: .system, contentBlocks: []),
        ]
        let set = try #require(PendingQuestionSet.derive(messages: messages, isTurnActive: false))
        #expect(set.messageId == "a1")
    }

    // MARK: - Dismissal marker (FE `wizard-gate.ts` parity)

    @Test func nilWhenDismissalMarkerMatches() {
        let messages = [assistant(id: "a1", blocks: [questionBlock(text: questionJSON())])]
        #expect(PendingQuestionSet.derive(
            messages: messages, isTurnActive: false,
            dismissedQuestionsMessageId: "a1") == nil)
    }

    @Test func newerQuestionSetPendsDespiteOlderDismissalMarker() throws {
        let messages = [assistant(id: "a2", blocks: [questionBlock(text: questionJSON())])]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages, isTurnActive: false,
            dismissedQuestionsMessageId: "a1"))
        #expect(set.messageId == "a2")
    }

    @Test func nilMarkerLeavesDerivationUnchanged() throws {
        let messages = [assistant(id: "a1", blocks: [questionBlock(text: questionJSON())])]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages, isTurnActive: false,
            dismissedQuestionsMessageId: nil))
        #expect(set.messageId == "a1")
    }

    // MARK: - Pending marker (FE `classifyPendingQuestionMarker` / marker authority parity)

    @Test func markerSetPendsWhileTurnActive() throws {
        let messages = [user(), questionAssistant(id: "a1")]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages, isTurnActive: true, pendingQuestionsMessageId: "a1"))
        #expect(set.messageId == "a1")
        #expect(set.questions.map(\.attachmentId) == ["tar-0123456789ab"])
    }

    @Test func markerSetPendsDespiteLaterPlainUserMessage() throws {
        let messages = [questionAssistant(id: "a1"), user(id: "u2")]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages, isTurnActive: false, pendingQuestionsMessageId: "a1"))
        #expect(set.messageId == "a1")
    }

    @Test func markerSetPendsDespiteLaterAssistantTurn() throws {
        let messages = [
            questionAssistant(id: "a1"),
            user(id: "u2"),
            assistant(id: "a2", blocks: [ContentBlock(type: .text, text: "later turn")], isStreaming: true),
            ConversationMessage(id: "s1", role: .system, contentBlocks: []),
        ]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages, isTurnActive: true, pendingQuestionsMessageId: "a1"))
        #expect(set.messageId == "a1")
    }

    @Test func markerSetSelectsMarkedRowOverQuestionBearingTail() throws {
        let messages = [
            questionAssistant(id: "a1"),
            user(id: "u2"),
            assistant(id: "a2", blocks: [
                questionBlock(text: questionJSON(attachmentId: "tar-ba9876543210", header: "Newer")),
            ]),
        ]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages, isTurnActive: false, pendingQuestionsMessageId: "a1"))
        #expect(set.messageId == "a1")
        #expect(set.questions.map(\.header) == ["Auth method"])
    }

    @Test func markerClearedIsNilEvenWithQuestionBearingTail() {
        let messages = [user(), questionAssistant(id: "a1")]
        #expect(PendingQuestionSet.derive(
            messages: messages, isTurnActive: false, pendingQuestionsMessageId: "") == nil)
    }

    @Test func markerSetNilOnceTaggedAnswerRowNamesIt() {
        let messages = [questionAssistant(id: "a1"), answerRow(answering: "a1")]
        #expect(PendingQuestionSet.derive(
            messages: messages, isTurnActive: false, pendingQuestionsMessageId: "a1") == nil)
    }

    @Test func markerSetNilWhenAnswerTagRidesTextBlockMessageMetadata() {
        let tagged = ConversationMessage(
            id: "u-ans", role: .user,
            contentBlocks: [ContentBlock(
                type: .text, text: "Q: Which auth method?\nA: OAuth",
                messageMetadata: [
                    "type": AnyCodable("question_answers"),
                    "answeredQuestionsMessageId": AnyCodable("a1"),
                ])])
        let messages = [questionAssistant(id: "a1"), tagged]
        #expect(PendingQuestionSet.derive(
            messages: messages, isTurnActive: false, pendingQuestionsMessageId: "a1") == nil)
    }

    @Test func markerSetIgnoresAnswerRowNamingAnotherSet() throws {
        let messages = [questionAssistant(id: "a1"), answerRow(answering: "a0")]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages, isTurnActive: false, pendingQuestionsMessageId: "a1"))
        #expect(set.messageId == "a1")
    }

    @Test func markerSetNilWhenQueuedAnswerNamesIt() {
        // The daemon auto-queued the tagged answer mid-turn: the optimistic
        // row is gone and the only local tag lives on the queue entry.
        let messages = [questionAssistant(id: "a1")]
        #expect(PendingQuestionSet.derive(
            messages: messages, isTurnActive: true, pendingQuestionsMessageId: "a1",
            queuedAnsweredQuestionsMessageIds: ["a1"]) == nil)
    }

    @Test func markerSetPendsWhenQueuedAnswerNamesAnotherSet() throws {
        let messages = [questionAssistant(id: "a1")]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages, isTurnActive: false, pendingQuestionsMessageId: "a1",
            queuedAnsweredQuestionsMessageIds: ["a0"]))
        #expect(set.messageId == "a1")
    }

    @Test func queuedMessageAnsweredQuestionsMessageIdReadsTagOnly() {
        func queued(_ metadata: [String: AnyCodable]?) -> QueuedMessage {
            QueuedMessage(id: "q", content: "x", queuedAt: "t", position: 0,
                          imageBlocks: nil, messageMetadata: metadata)
        }
        #expect(queued([
            "type": AnyCodable("question_answers"),
            "answeredQuestionsMessageId": AnyCodable("a1"),
        ]).answeredQuestionsMessageId == "a1")
        #expect(queued(nil).answeredQuestionsMessageId == nil)
        #expect(queued([
            "type": AnyCodable("agent_message"),
            "answeredQuestionsMessageId": AnyCodable("a1"),
        ]).answeredQuestionsMessageId == nil)
        #expect(queued([
            "type": AnyCodable("question_answers"),
            "answeredQuestionsMessageId": AnyCodable(""),
        ]).answeredQuestionsMessageId == nil)
    }

    @Test func markerSetIgnoresAnswerTagOnNonUserRow() throws {
        let taggedAssistant = ConversationMessage(
            id: "a2", role: .assistant,
            contentBlocks: [ContentBlock(type: .text, text: "echo")],
            metadata: [
                "type": AnyCodable("question_answers"),
                "answeredQuestionsMessageId": AnyCodable("a1"),
            ])
        let messages = [questionAssistant(id: "a1"), taggedAssistant]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages, isTurnActive: false, pendingQuestionsMessageId: "a1"))
        #expect(set.messageId == "a1")
    }

    @Test func markerSetNilWhenDismissalMarkerMatches() {
        let messages = [questionAssistant(id: "a1")]
        #expect(PendingQuestionSet.derive(
            messages: messages, isTurnActive: false,
            dismissedQuestionsMessageId: "a1", pendingQuestionsMessageId: "a1") == nil)
    }

    @Test func markerSetPendsWhenDismissalMarkerNamesOlderSet() throws {
        let messages = [questionAssistant(id: "a2")]
        let set = try #require(PendingQuestionSet.derive(
            messages: messages, isTurnActive: false,
            dismissedQuestionsMessageId: "a1", pendingQuestionsMessageId: "a2"))
        #expect(set.messageId == "a2")
    }

    @Test func markerSetNilWhileMarkedRowStreaming() {
        let messages = [questionAssistant(id: "a1", isStreaming: true)]
        #expect(PendingQuestionSet.derive(
            messages: messages, isTurnActive: false, pendingQuestionsMessageId: "a1") == nil)
    }

    @Test func markerSetNilWhenMarkedRowMissing() {
        let messages = [questionAssistant(id: "a1")]
        #expect(PendingQuestionSet.derive(
            messages: messages, isTurnActive: false, pendingQuestionsMessageId: "a-gone") == nil)
    }

    @Test func markerSetNilWhenMarkedRowIsNotAssistant() {
        let messages = [
            ConversationMessage(id: "u1", role: .user, contentBlocks: [questionBlock(text: questionJSON())]),
        ]
        #expect(PendingQuestionSet.derive(
            messages: messages, isTurnActive: false, pendingQuestionsMessageId: "u1") == nil)
    }

    @Test func markerSetNilWhenMarkedRowHasNoValidQuestions() {
        let messages = [assistant(id: "a1", blocks: [
            ContentBlock(type: .text, text: "plain"),
            questionBlock(text: "garbage"),
        ])]
        #expect(PendingQuestionSet.derive(
            messages: messages, isTurnActive: false, pendingQuestionsMessageId: "a1") == nil)
    }

    @Test func markerSetStillNilWhileShowingPendingUserMessageOrEmpty() {
        let messages = [questionAssistant(id: "a1")]
        #expect(PendingQuestionSet.derive(
            messages: messages, isTurnActive: false, showingPendingUserMessage: true,
            pendingQuestionsMessageId: "a1") == nil)
        #expect(PendingQuestionSet.derive(
            messages: [], isTurnActive: false, pendingQuestionsMessageId: "a1") == nil)
    }

    @Test func markerSetDedupesByAttachmentId() {
        let messages = [assistant(id: "a1", blocks: [
            questionBlock(text: questionJSON(header: "First")),
            questionBlock(text: questionJSON(header: "Duplicate")),
            questionBlock(text: questionJSON(attachmentId: "tar-ba9876543210", header: "Second")),
        ])]
        let set = PendingQuestionSet.derive(
            messages: messages, isTurnActive: false, pendingQuestionsMessageId: "a1")
        #expect(set?.questions.map(\.header) == ["First", "Second"])
    }

    @Test func markerStateClassification() {
        #expect(PendingQuestionSet.MarkerState(nil) == .absent)
        #expect(PendingQuestionSet.MarkerState("") == .cleared)
        #expect(PendingQuestionSet.MarkerState("a1") == .set(messageId: "a1"))
    }

    @Test func answeredQuestionsMessageIdRejectsWrongTypeOrEmptyId() {
        let wrongType = ConversationMessage(
            id: "u1", role: .user,
            metadata: ["type": AnyCodable("questions_dismissed"),
                       "answeredQuestionsMessageId": AnyCodable("a1")])
        let emptyId = ConversationMessage(
            id: "u2", role: .user,
            metadata: ["type": AnyCodable("question_answers"),
                       "answeredQuestionsMessageId": AnyCodable("")])
        #expect(wrongType.answeredQuestionsMessageId == nil)
        #expect(emptyId.answeredQuestionsMessageId == nil)
        #expect(answerRow(answering: "a1").answeredQuestionsMessageId == "a1")
    }
}

// MARK: - Answer flattening (FE `answer-message.ts` parity)

struct AnswerFlatteningTests {
    private let question = Question(
        attachmentId: "tar-0123456789ab", header: "Auth method",
        question: "Which auth method?",
        options: [QuestionOption(label: "OAuth"), QuestionOption(label: "API key")]
    )

    private func answer(
        selectedLabels: [String] = [], freeText: String = "", skipped: Bool = false
    ) -> QuestionAnswer {
        QuestionAnswer(
            question: question, selectedLabels: selectedLabels,
            freeText: freeText, skipped: skipped)
    }

    @Test func singleSelection() {
        #expect(QuestionAnswer.flattenToMessage([answer(selectedLabels: ["OAuth"])])
            == "Q: Which auth method?\nA: OAuth")
    }

    @Test func multiSelectCommaJoined() {
        #expect(QuestionAnswer.flattenToMessage([answer(selectedLabels: ["OAuth", "API key"])])
            == "Q: Which auth method?\nA: OAuth, API key")
    }

    @Test func freeTextAppendedAsOther() {
        #expect(QuestionAnswer.flattenToMessage([answer(selectedLabels: ["OAuth"], freeText: "mTLS")])
            == "Q: Which auth method?\nA: OAuth, (Other) mTLS")
    }

    @Test func freeTextOnly() {
        #expect(QuestionAnswer.flattenToMessage([answer(freeText: "mTLS")])
            == "Q: Which auth method?\nA: (Other) mTLS")
    }

    @Test func skippedWinsOverSelections() {
        #expect(QuestionAnswer.flattenToMessage([answer(selectedLabels: ["OAuth"], skipped: true)])
            == "Q: Which auth method?\nA: (skipped)")
    }

    @Test func emptyAnswerReadsAsSkipped() {
        #expect(QuestionAnswer.flattenToMessage([answer()])
            == "Q: Which auth method?\nA: (skipped)")
    }

    @Test func multipleAnswersJoinedByBlankLine() {
        let second = Question(
            attachmentId: "tar-ba9876543210", header: "Region", question: "Which region?",
            options: [QuestionOption(label: "US"), QuestionOption(label: "EU")], multiSelect: true)
        let message = QuestionAnswer.flattenToMessage([
            answer(selectedLabels: ["OAuth"]),
            QuestionAnswer(question: second, selectedLabels: ["US", "EU"], freeText: "", skipped: false),
        ])
        #expect(message == "Q: Which auth method?\nA: OAuth\n\nQ: Which region?\nA: US, EU")
    }

    @Test func emptyAnswerListIsEmptyMessage() {
        #expect(QuestionAnswer.flattenToMessage([]) == "")
    }
}
