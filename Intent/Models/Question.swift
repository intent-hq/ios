import Foundation

/// Agent Q&A question resource (PROTOCOL §7.1 standalone resource block).
/// The daemon attaches one resource block per `ws.app.question.ask` call as a
/// trailing block on the turn's final assistant message. There is NO
/// questionId — pending vs. answered is keyed on the question-bearing
/// assistant message id via the daemon's session-metadata marker (PROTOCOL
/// §5.5 `pendingQuestionsMessageId`), with a transcript-tail fallback for
/// legacy sessions; see `PendingQuestionSet.derive`.
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
                forKey: .label,
                in: container,
                debugDescription: "label must be non-empty"
            )
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
                forKey: .header,
                in: container,
                debugDescription: "header and question must be non-empty"
            )
        }
        explanation = container.contains(.explanation)
            ? try container.decode(String.self, forKey: .explanation)
            : nil
        options = try container.decode([QuestionOption].self, forKey: .options)
        guard options.count >= 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .options,
                in: container,
                debugDescription: "at least 2 options required"
            )
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
    static func question(from block: ContentBlock) -> Self? {
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
        return try? JSONDecoder().decode(Self.self, from: Data(text.utf8))
    }
}

/// Pending Agent Q&A questions for the composer-slot wizard. The daemon's
/// three-state pending marker (PROTOCOL §5.5 `pendingQuestionsMessageId`) is
/// authoritative when present: an empty string clears the slot, while a
/// message id permits only that question-bearing row — and keeps it pending
/// across later automatic/user turns until the daemon clears it (answer or
/// dismissal). Legacy sessions without the marker use the daemon's
/// transcript-tail fallback. Port of the FE's `derivePendingQuestions` in
/// `chat/questions/pending-questions.ts`.
struct PendingQuestionSet: Equatable {
    /// Id of the question-bearing assistant message (keys wizard remounts).
    let messageId: String
    /// The questions in transcript order (at least one), deduped by
    /// `attachmentId` (first occurrence kept).
    let questions: [Question]

    /// Daemon marker classification that keeps absent and written-empty
    /// distinct (FE parity: `classifyPendingQuestionMarker`).
    enum MarkerState: Equatable {
        case absent
        case cleared
        case set(messageId: String)

        init(_ pendingQuestionsMessageId: String?) {
            guard let id = pendingQuestionsMessageId else {
                self = .absent
                return
            }
            self = id.isEmpty ? .cleared : .set(messageId: id)
        }
    }

    /// Derive the pending question set, or nil when there is none.
    ///
    /// With the daemon marker set, the marked question-bearing row stays
    /// pending regardless of `isTurnActive`: the marker is only written once
    /// the asking turn has ended, and later automatic/user turns must not hide
    /// the wizard. It is nil only while that row is still streaming (or is
    /// missing / not an assistant row / carries no valid question), once a
    /// tagged answer row names it, or while an optimistic pending user bubble
    /// is shown. A marker of `""` means nothing is pending.
    ///
    /// `queuedAnsweredQuestionsMessageIds` are the question sets answered by
    /// sends that are not in the transcript yet — the daemon auto-queued the
    /// tagged answer during an active turn, so the only local `question_answers`
    /// tag lives on the queue entry (`QueuedMessage.answeredQuestionsMessageId`).
    /// A marked set named there is treated as answered exactly like a tagged
    /// user row, so the wizard cannot pop back in (and take a duplicate
    /// submission) before the queued answer is delivered. Callers pass the ids
    /// in rather than this helper reading the store.
    ///
    /// Without the marker (legacy daemon) the transcript-tail fallback applies
    /// and is additionally nil whenever the agent's OWN turn is active
    /// (`isTurnActive`): trailing system rows are transparent and only a
    /// question-bearing assistant row at the non-system tail is pending — ANY
    /// trailing user message supersedes it.
    ///
    /// In both paths a question set the user dismissed never pends: the daemon
    /// persists the dismissed message id in session metadata
    /// (`agent.dismissQuestions`, PROTOCOL §5.5 `dismissedQuestionsMessageId`),
    /// so when it matches the question-bearing message the set is retired —
    /// survives reload, while a NEWER question-bearing message (different id)
    /// pends normally (FE parity: `wizard-gate.ts` /
    /// `isQuestionMessageDismissed`).
    static func derive(
        messages: [ConversationMessage],
        isTurnActive: Bool,
        showingPendingUserMessage: Bool = false,
        dismissedQuestionsMessageId: String? = nil,
        pendingQuestionsMessageId: String? = nil,
        queuedAnsweredQuestionsMessageIds: Set<String> = []
    ) -> Self? {
        if showingPendingUserMessage || messages.isEmpty {
            return nil
        }
        switch MarkerState(pendingQuestionsMessageId) {
        case .cleared:
            return nil
        case .set(let markedId):
            guard let marked = messages.first(where: { $0.id == markedId }) else {
                // Fails open (no wizard, plain composer): the marked row is not
                // in the loaded window (slim transcript truncation). Recovery is
                // a follow-up; log so the case is diagnosable in the field.
                AppLog.conversation.debug(
                    "[PendingQuestionSet] marker \(markedId) set but row not loaded"
                )
                return nil
            }
            guard marked.role == .assistant, marked.isStreaming != true else {
                return nil
            }
            if queuedAnsweredQuestionsMessageIds.contains(markedId)
                || isQuestionSetAnswered(messages: messages, messageId: markedId) {
                return nil
            }
            return questionSet(from: marked, dismissedQuestionsMessageId: dismissedQuestionsMessageId)
        case .absent:
            if isTurnActive { return nil }
            // Match the daemon's pre-marker fallback: trailing system rows are
            // transparent, but the first non-system row must itself be a
            // question-bearing assistant message (a user row supersedes).
            for msg in messages.reversed() {
                if msg.role == .system { continue }
                guard msg.role == .assistant, msg.isStreaming != true else { return nil }
                return questionSet(from: msg, dismissedQuestionsMessageId: dismissedQuestionsMessageId)
            }
            return nil
        }
    }

    /// True when a user row in `messages` carries the wizard's answer tag
    /// (`{ type: "question_answers", answeredQuestionsMessageId }`) naming
    /// `messageId`. Bridges the window between the user hitting Send (the
    /// optimistic row mirrors the tag) and the daemon's `agent:updated`
    /// clearing the marker, so an answered set never pops back in (FE parity:
    /// `isQuestionSetAnswered`).
    static func isQuestionSetAnswered(
        messages: [ConversationMessage],
        messageId: String
    ) -> Bool {
        messages.contains { $0.role == .user && $0.answeredQuestionsMessageId == messageId }
    }

    private static func questionSet(
        from message: ConversationMessage,
        dismissedQuestionsMessageId: String?
    ) -> Self? {
        if let dismissedId = dismissedQuestionsMessageId, dismissedId == message.id {
            return nil
        }
        var seenAttachmentIds = Set<String>()
        var questions: [Question] = []
        for block in message.contentBlocks ?? [] {
            guard let question = Question.question(from: block) else { continue }
            if seenAttachmentIds.insert(question.attachmentId).inserted {
                questions.append(question)
            }
        }
        guard !questions.isEmpty else { return nil }
        return Self(messageId: message.id, questions: questions)
    }
}

extension ConversationMessage {
    /// Id of the question set this user message answers, or nil for every
    /// other message. Reads the row's `metadata` first, falling back to the
    /// text blocks' `messageMetadata` (the same dual surface the daemon
    /// persists a tagged message on — see `QuestionsDismissedNotice`; FE
    /// parity: `getAnsweredQuestionsMessageId`).
    var answeredQuestionsMessageId: String? {
        if let answered = questionAnswersTaggedMessageId(metadata) { return answered }
        for block in contentBlocks ?? [] where block.type == .text {
            if let answered = questionAnswersTaggedMessageId(block.messageMetadata) { return answered }
        }
        return nil
    }
}

extension QueuedMessage {
    /// Id of the question set this queued entry answers, or nil for every
    /// other entry. The wizard's tagged answer is auto-queued by the daemon
    /// when it is sent during an active turn, and until it is delivered the
    /// queue entry's `messageMetadata` is the only local copy of the
    /// `question_answers` tag (the optimistic transcript row is removed on
    /// `queued: true`).
    var answeredQuestionsMessageId: String? {
        questionAnswersTaggedMessageId(messageMetadata)
    }
}

/// The `answeredQuestionsMessageId` of a `{ type: "question_answers",
/// answeredQuestionsMessageId }` tag, or nil when `metadata` is not that tag.
private func questionAnswersTaggedMessageId(_ metadata: [String: AnyCodable]?) -> String? {
    guard let metadata,
          metadata["type"]?.stringValue == "question_answers",
          let answered = metadata["answeredQuestionsMessageId"]?.stringValue,
          !answered.isEmpty else {
        return nil
    }
    return answered
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
    static func flattenToMessage(_ answers: [Self]) -> String {
        answers
            .map { "Q: \($0.question.question)\nA: \($0.formattedAnswer)" }
            .joined(separator: "\n\n")
    }
}
