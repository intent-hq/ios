import Foundation

struct QuestionOption: Equatable, Decodable {
    let label: String
    let description: String?

    private enum CodingKeys: String, CodingKey { case label, description }

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
    static let resourceMimeType = "application/vnd.intent.question+json"

    let attachmentId: String
    let header: String
    let question: String
    let explanation: String?
    let options: [QuestionOption]
    let multiSelect: Bool

    var id: String { attachmentId }

    private enum CodingKeys: String, CodingKey {
        case attachmentId, header, question, explanation, options, multiSelect
    }

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
        explanation: String?,
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

    static func isQuestionResourceBlock(_ block: ContentBlock) -> Bool {
        block.type == .resource && block.resource?.mimeType == resourceMimeType
    }

    static func question(from block: ContentBlock) -> Self? {
        let mimeType: String?
        let text: String?
        if let resource = block.resource {
            mimeType = resource.mimeType
            text = resource.text
        } else if case let .value(dict) = block.metadata["resource"]?.dictValue {
            mimeType = dict["mimeType"] as? String
            text = dict["text"] as? String
        } else {
            return nil
        }
        guard mimeType == resourceMimeType, let text else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(text.utf8))
    }
}

extension Question {
    init(
        attachmentId: String,
        header: String,
        question: String,
        options: [QuestionOption],
        multiSelect: Bool = false
    ) {
        self.init(
            attachmentId: attachmentId,
            header: header,
            question: question,
            explanation: nil,
            options: options,
            multiSelect: multiSelect
        )
    }
}

struct PendingQuestionSet: Equatable {
    let messageId: String
    let questions: [Question]

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
            return deriveMarkedSet(
                messages: messages,
                markedId: markedId,
                dismissedQuestionsMessageId: dismissedQuestionsMessageId,
                queuedAnsweredQuestionsMessageIds: queuedAnsweredQuestionsMessageIds
            )
        case .absent:
            return deriveLegacySet(
                messages: messages,
                isTurnActive: isTurnActive,
                dismissedQuestionsMessageId: dismissedQuestionsMessageId
            )
        }
    }

    private static func deriveMarkedSet(
        messages: [ConversationMessage],
        markedId: String,
        dismissedQuestionsMessageId: String?,
        queuedAnsweredQuestionsMessageIds: Set<String>
    ) -> Self? {
        guard let marked = messages.first(where: { $0.id == markedId }) else {
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
    }

    private static func deriveLegacySet(
        messages: [ConversationMessage],
        isTurnActive: Bool,
        dismissedQuestionsMessageId: String?
    ) -> Self? {
        if isTurnActive { return nil }
        for message in messages.reversed() {
            if message.role == .system { continue }
            guard message.role == .assistant, message.isStreaming != true else { return nil }
            return questionSet(from: message, dismissedQuestionsMessageId: dismissedQuestionsMessageId)
        }
        return nil
    }

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
        for block in message.contentBlocks {
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
    var answeredQuestionsMessageId: String? {
        if let answered = questionAnswersTaggedMessageId(metadata) { return answered }
        for block in contentBlocks where block.type == .text {
            if let answered = questionAnswersTaggedMessageId(block.messageMetadata) { return answered }
        }
        return nil
    }
}

extension QueuedMessage {
    var answeredQuestionsMessageId: String? {
        questionAnswersTaggedMessageId(messageMetadata)
    }
}

private func questionAnswersTaggedMessageId(_ metadata: [String: AnyCodable]) -> String? {
    guard metadata["type"]?.stringValue == "question_answers",
          let answered = metadata["answeredQuestionsMessageId"]?.stringValue,
          !answered.isEmpty else {
        return nil
    }
    return answered
}

struct QuestionAnswer: Equatable {
    let question: Question
    let selectedLabels: [String]
    let freeText: String
    let skipped: Bool

    private var formattedAnswer: String {
        if skipped { return "(skipped)" }
        var parts = selectedLabels
        if !freeText.isEmpty { parts.append("(Other) \(freeText)") }
        if parts.isEmpty { return "(skipped)" }
        return parts.joined(separator: ", ")
    }

    static func flattenToMessage(_ answers: [Self]) -> String {
        answers
            .map { "Q: \($0.question.question)\nA: \($0.formattedAnswer)" }
            .joined(separator: "\n\n")
    }
}
