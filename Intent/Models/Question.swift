import Foundation

/// Agent Q&A question resource (PROTOCOL §7.1 standalone resource block).
/// The daemon attaches one resource block per `ws.app.question.ask` call as a
/// trailing block on the turn's final assistant message. There is NO
/// questionId — pending vs. answered is derived purely from whether a later
/// user message exists after the question-bearing assistant message.
///
/// Questions are WIZARD-ONLY: they never render in the conversation transcript
/// (pending or resolved). Mirrors the cloudlands-fe contract in
/// `src/shared/types/question-resource.ts`.
struct QuestionOption: Equatable, Decodable {
    let label: String
    let description: String?

    private enum CodingKeys: String, CodingKey { case label, description }

    /// Strict decode identical to the FE's `isQuestionOption`: `label` must be
    /// a non-empty string; `description` absent or a string (null rejected).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        guard !label.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .label, in: container, debugDescription: "label must be non-empty")
        }
        description = container.contains(.description)
            ? try container.decode(String.self, forKey: .description)
            : nil
    }

    init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

struct Question: Equatable, Identifiable, Decodable {
    /// MIME type of a question resource block.
    static let resourceMimeType = "application/vnd.intent.question+json"

    /// Turn-attachment registry id (`tar-…`) stamped by the daemon.
    let attachmentId: String
    /// Short category label rendered above the question (e.g. "Auth method").
    let header: String
    let question: String
    /// Optional longer context shown expandable.
    let explanation: String?
    /// At least 2 options; free-form "Other" is implicit (always offered).
    let options: [QuestionOption]
    /// Absent on the wire means single-select.
    let multiSelect: Bool

    var id: String { attachmentId }

    private enum CodingKeys: String, CodingKey {
        case attachmentId, header, question, explanation, options, multiSelect
    }

    /// Strict decode identical to the FE's `isQuestion`: `attachmentId` any
    /// string (no length check, FE parity), `header`/`question` non-empty
    /// strings, `explanation` absent or a string (null rejected), `options` an
    /// array of >=2 valid options, `multiSelect` absent or a boolean
    /// (null / numeric rejected).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attachmentId = try container.decode(String.self, forKey: .attachmentId)
        header = try container.decode(String.self, forKey: .header)
        question = try container.decode(String.self, forKey: .question)
        guard !header.isEmpty, !question.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .header, in: container,
                debugDescription: "header and question must be non-empty")
        }
        explanation = container.contains(.explanation)
            ? try container.decode(String.self, forKey: .explanation)
            : nil
        options = try container.decode([QuestionOption].self, forKey: .options)
        guard options.count >= 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .options, in: container,
                debugDescription: "at least 2 options required")
        }
        multiSelect = container.contains(.multiSelect)
            ? try container.decode(Bool.self, forKey: .multiSelect)
            : false
    }

    init(
        attachmentId: String,
        header: String,
        question: String,
        explanation: String? = nil,
        options: [QuestionOption],
        multiSelect: Bool = false
    ) {
        self.attachmentId = attachmentId
        self.header = header
        self.question = question
        self.explanation = explanation
        self.options = options
        self.multiSelect = multiSelect
    }

    // MARK: - Parsing helpers

    /// Whether a content block is a question resource block. Payload validity
    /// is irrelevant here: even a malformed question payload must not surface
    /// in the transcript, so the check is MIME-only (FE parity:
    /// `isQuestionResourceBlock`).
    static func isQuestionResourceBlock(_ block: ContentBlock) -> Bool {
        block.type == .resource && block.resource?.mimeType == resourceMimeType
    }

    /// Parse the question payload out of a resource block, or nil when the
    /// MIME type does not match or the payload is malformed (FE parity:
    /// `getQuestionFromResourceBlock`, including the legacy
    /// `metadata.resource` fallback).
    static func question(from block: ContentBlock) -> Question? {
        let mimeType: String?
        let text: String?
        if let resource = block.resource {
            mimeType = resource.mimeType
            text = resource.text
        } else if let dict = block.metadata?["resource"]?.dictValue {
            mimeType = dict["mimeType"] as? String
            text = dict["text"] as? String
        } else {
            return nil
        }
        guard mimeType == resourceMimeType, let text else { return nil }
        return try? JSONDecoder().decode(Question.self, from: Data(text.utf8))
    }
}

/// Pending Agent Q&A questions for the composer-slot wizard (wire contract:
/// pending vs. answered is derived purely from the transcript — questions on
/// the LAST assistant message with NO later user message are pending; ANY
/// later user message supersedes them). Port of the FE's
/// `derivePendingQuestions` in `chat/questions/pending-questions.ts`.
struct PendingQuestionSet: Equatable {
    /// Id of the question-bearing assistant message (keys wizard remounts).
    let messageId: String
    /// The questions in transcript order (at least one), deduped by
    /// `attachmentId` (first occurrence kept).
    let questions: [Question]

    /// Derive the pending question set, or nil when there is none.
    ///
    /// Nil whenever the agent's own turn is still active (`isTurnActive`), an
    /// optimistic pending user bubble is shown, the last assistant message is
    /// still streaming, or a user message trails the last assistant message
    /// (superseded). Because this reads only the transcript, restored sessions
    /// re-surface unanswered questions automatically.
    static func derive(
        messages: [ConversationMessage],
        isTurnActive: Bool,
        showingPendingUserMessage: Bool = false
    ) -> PendingQuestionSet? {
        if isTurnActive || showingPendingUserMessage || messages.isEmpty {
            return nil
        }
        // Walk back to the last assistant message; a user message encountered
        // first supersedes any questions (resolution is derivational, not id-keyed).
        var lastAssistant: ConversationMessage?
        for msg in messages.reversed() {
            if msg.role == .user { return nil }
            if msg.role == .assistant {
                lastAssistant = msg
                break
            }
        }
        guard let lastAssistant, lastAssistant.isStreaming != true else { return nil }
        var seenAttachmentIds = Set<String>()
        var questions: [Question] = []
        for block in lastAssistant.contentBlocks ?? [] {
            guard let question = Question.question(from: block) else { continue }
            if seenAttachmentIds.insert(question.attachmentId).inserted {
                questions.append(question)
            }
        }
        guard !questions.isEmpty else { return nil }
        return PendingQuestionSet(messageId: lastAssistant.id, questions: questions)
    }
}

/// Answer flattening for the Agent Q&A wizard (wire contract): all answers of
/// a question set collapse into ONE plain-text user message of `Q:`/`A:`
/// pairs separated by a blank line — multi-select answers comma-joined,
/// free-form replies prefixed `(Other)`, skipped questions reported as
/// `(skipped)`. The message travels through the ordinary `agent.sendMessage`
/// path tagged with `messageMetadata { type: "question_answers",
/// answeredQuestionsMessageId }` — the structured tag (never the answer text)
/// is what resolves the pending set on the daemon. Port of the FE's
/// `chat/questions/answer-message.ts`.
struct QuestionAnswer: Equatable {
    let question: Question
    /// Labels of the selected options (selection order).
    let selectedLabels: [String]
    /// Trimmed free-form "Other" text ("" when none).
    let freeText: String
    /// True when the question was explicitly skipped.
    let skipped: Bool

    private var formattedAnswer: String {
        if skipped { return "(skipped)" }
        var parts = selectedLabels
        if !freeText.isEmpty { parts.append("(Other) \(freeText)") }
        // A question left unanswered without an explicit Skip (only reachable
        // via Back-then-Send edge flows) reads the same as a skip on the wire.
        if parts.isEmpty { return "(skipped)" }
        return parts.joined(separator: ", ")
    }

    /// Flatten the wizard's answers into the single plain-text user message.
    static func flattenToMessage(_ answers: [QuestionAnswer]) -> String {
        answers
            .map { "Q: \($0.question.question)\nA: \($0.formattedAnswer)" }
            .joined(separator: "\n\n")
    }
}
