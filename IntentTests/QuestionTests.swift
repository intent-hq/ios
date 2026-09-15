import Foundation
@testable import Intent
import Testing

// MARK: - Shared fixtures

private let kQuestionMime = "application/vnd.intent.question+json"

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

private func questionBlock(text: String, mimeType: String = kQuestionMime) -> ContentBlock {
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
        "mimeType": "\(kQuestionMime)", "text": "{}"}}
        """)
        #expect(block.type == .resource)
        #expect(block.resource?.uri == "intent-question://q")
        #expect(block.resource?.mimeType == kQuestionMime)
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
            "id": "msg-1",
            "role": "assistant",
            "timestamp": "2026-01-01T00:00:00Z",
            "contentBlocks": [
                ["type": "text", "text": "hello"],
                [
                    "type": "resource",
                    "resource": ["mimeType": kQuestionMime, "text": questionJSON()]
                ]
            ]
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
        let question = try #require(parseQuestion("""
        {"attachmentId": "tar-0123456789ab", "header": "Auth", "question": "Which?", \
        "explanation": "Because", "multiSelect": true, "options": [\
        {"label": "A", "description": "first"}, {"label": "B"}]}
        """))
        #expect(question.attachmentId == "tar-0123456789ab")
        #expect(question.explanation == "Because")
        #expect(question.multiSelect == true)
        #expect(question.options == [
            QuestionOption(label: "A", description: "first"),
            QuestionOption(label: "B")
        ])
    }

    @Test func minimalPayloadDefaultsMultiSelectFalse() throws {
        let question = try #require(parseQuestion(questionJSON()))
        #expect(question.explanation == nil)
        #expect(question.multiSelect == false)
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
                with: "\"nope\""
            )) == nil)
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
        let question = try #require(Question.question(from: questionBlock(text: questionJSON())))
        #expect(question.question == "Which auth method?")
        #expect(question.options.count == 2)
    }

    @Test func questionFromMalformedOrWrongMimeIsNil() {
        #expect(Question.question(from: questionBlock(text: "garbage")) == nil)
        #expect(Question.question(from: questionBlock(text: questionJSON(), mimeType: "text/plain")) == nil)
        #expect(Question.question(from: ContentBlock(type: .resource)) == nil)
    }

    @Test func questionFromMetadataResourceFallback() throws {
        let block = ContentBlock(
            id: "b1",
            type: .resource,
            metadata: [
                "resource": AnyCodable(
                    [
                        "mimeType": kQuestionMime,
                        "text": questionJSON()
                    ] as [String: Any]
                )
            ]
        )
        let question = try #require(Question.question(from: block))
        #expect(question.attachmentId == "tar-0123456789ab")
    }
}

// MARK: - Marker recovery exclusivity (visionOS composerVisible invariant)

/// `ConversationViewModel.isPendingQuestionRecoveryLoading` is true only while
/// the marker names a non-resident row and no wizard can be derived from the
/// recovered copy (`derive([recovered], isTurnActive: false,
/// pendingQuestionsMessageId:)` is nil) — or no copy exists at all;
/// `pendingQuestions` derives over the transcript with that copy prepended.
/// These pin the invariant `ConversationColumnView.composerVisible` (visionOS)
/// relies on: every state that makes the recovery gate report loading also
/// makes the full derivation nil, so the two can never both hold.
struct PendingQuestionRecoveryExclusivityTests {
    private let markedId = "a-marked"

    /// A transcript without the marked row but with a question-bearing tail,
    /// so a nil result proves marker authority rather than an empty tail.
    private var transcriptWithoutMarkedRow: [ConversationMessage] {
        [
            ConversationMessage(
                id: "u1",
                role: .user,
                contentBlocks: [ContentBlock(type: .text, text: "hi")]
            ),
            ConversationMessage(
                id: "a-other",
                role: .assistant,
                contentBlocks: [questionBlock(text: questionJSON())]
            )
        ]
    }

    /// Mirrors `ConversationViewModel.pendingQuestions` during recovery: the
    /// recovered copy (when present) is prepended to the loaded transcript.
    private func fullDerivation(recovered: ConversationMessage?) -> PendingQuestionSet? {
        var messages = transcriptWithoutMarkedRow
        if let recovered { messages.insert(recovered, at: 0) }
        return PendingQuestionSet.derive(
            messages: messages,
            isTurnActive: false,
            pendingQuestionsMessageId: markedId
        )
    }

    /// Mirrors the recovery gate's derivation
    /// (`ConversationViewModel.isPendingQuestionRecoveryLoading`): loading
    /// while this is nil.
    private func recoveredWizard(_ recovered: ConversationMessage) -> PendingQuestionSet? {
        PendingQuestionSet.derive(
            messages: [recovered],
            isTurnActive: false,
            pendingQuestionsMessageId: markedId
        )
    }

    @Test func noRecoveredCopyDerivesNilPendingSet() {
        // Seek unsettled (or notFound/error): the gate is loading and the
        // full derivation fails open to nil — no wizard renders alongside it.
        #expect(fullDerivation(recovered: nil) == nil)
    }

    @Test func nonRenderableRecoveredCopyDerivesNilPendingSet() {
        // Every recovered copy the gate derives to nil (still loading) also
        // nils the full derivation with the copy prepended.
        let nonRenderable: [ConversationMessage] = [
            ConversationMessage(
                id: markedId,
                role: .assistant,
                contentBlocks: [questionBlock(text: questionJSON())],
                streamingState: .streaming
            ),
            ConversationMessage(
                id: markedId,
                role: .user,
                contentBlocks: [questionBlock(text: questionJSON())]
            ),
            ConversationMessage(
                id: markedId,
                role: .assistant,
                contentBlocks: [questionBlock(text: "garbage")]
            )
        ]
        for recovered in nonRenderable {
            #expect(recoveredWizard(recovered) == nil)
            #expect(fullDerivation(recovered: recovered) == nil)
        }
    }

    @Test func renderableRecoveredCopyEndsLoadingAndDerivesSet() throws {
        // Converse sanity: once a wizard derives from the recovered copy the
        // gate stops loading, and the full derivation yields the same set.
        let recovered = ConversationMessage(
            id: markedId,
            role: .assistant,
            contentBlocks: [questionBlock(text: questionJSON())]
        )
        #expect(recoveredWizard(recovered) != nil)
        let set = try #require(fullDerivation(recovered: recovered))
        #expect(set.messageId == markedId)
    }
}

// MARK: - Answer flattening (FE `answer-message.ts` parity)

struct AnswerFlatteningTests {
    private let question = Question(
        attachmentId: "tar-0123456789ab",
        header: "Auth method",
        question: "Which auth method?",
        options: [QuestionOption(label: "OAuth"), QuestionOption(label: "API key")]
    )

    private func answer(
        selectedLabels: [String] = [],
        freeText: String = "",
        skipped: Bool = false
    ) -> QuestionAnswer {
        QuestionAnswer(
            question: question,
            selectedLabels: selectedLabels,
            freeText: freeText,
            skipped: skipped
        )
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
            attachmentId: "tar-ba9876543210",
            header: "Region",
            question: "Which region?",
            options: [QuestionOption(label: "US"), QuestionOption(label: "EU")],
            multiSelect: true
        )
        let message = QuestionAnswer.flattenToMessage([
            answer(selectedLabels: ["OAuth"]),
            QuestionAnswer(question: second, selectedLabels: ["US", "EU"], freeText: "", skipped: false)
        ])
        #expect(message == "Q: Which auth method?\nA: OAuth\n\nQ: Which region?\nA: US, EU")
    }

    @Test func emptyAnswerListIsEmptyMessage() {
        #expect(QuestionAnswer.flattenToMessage([]).isEmpty)
    }
}
