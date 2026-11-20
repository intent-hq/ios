import Foundation

nonisolated enum MessageStreamingState: Equatable {
    case complete
    case streaming
    case unreported

    init(reportedStreaming: Bool) {
        self = reportedStreaming ? .streaming : .complete
    }
}

nonisolated enum MessageRole: String, Codable {
    case assistant
    case error
    case system
    case user

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .system
    }
}

nonisolated struct ToolCall: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    var arguments: AnyCodable?
    var result: AnyCodable?
    var error: String?
    var status: String?
    var timestamp: String?

    private var toolName: String?
    private var parameters: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case id, name, arguments, result, error, status, timestamp
        case toolName, parameters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)

        let decodedName = try? container.decode(String.self, forKey: .name)
        let decodedToolName = try? container.decode(String.self, forKey: .toolName)
        name = decodedName ?? decodedToolName ?? "unknown"
        toolName = decodedToolName

        arguments = try? container.decode(AnyCodable.self, forKey: .arguments)
        parameters = try? container.decode(AnyCodable.self, forKey: .parameters)
        if arguments == nil, let params = parameters {
            arguments = params
        }

        result = try? container.decode(AnyCodable.self, forKey: .result)
        error = try? container.decode(String.self, forKey: .error)
        status = try? container.decode(String.self, forKey: .status)
        timestamp = try? container.decode(String.self, forKey: .timestamp)
    }

    init(
        id: String,
        name: String,
        arguments: AnyCodable? = nil,
        result: AnyCodable? = nil,
        error: String? = nil,
        status: String? = nil
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.result = result
        self.error = error
        self.status = status
        self.timestamp = nil
        self.toolName = nil
        self.parameters = nil
    }
}

nonisolated struct ToolResult: Codable, Equatable {
    let toolCallId: String
    var content: AnyCodable?
    var errorOutcome: ToolExecutionOutcome
    var timestamp: String?

    private enum CodingKeys: String, CodingKey { case toolCallId, content, isError, timestamp }

    init(toolCallId: String, content: AnyCodable? = nil, errorOutcome: ToolExecutionOutcome = .unreported, timestamp: String? = nil) {
        self.toolCallId = toolCallId
        self.content = content
        self.errorOutcome = errorOutcome
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try container.decode(String.self, forKey: .toolCallId)
        content = try? container.decode(AnyCodable.self, forKey: .content)
        errorOutcome = (try? container.decode(Bool.self, forKey: .isError))
            .map(ToolExecutionOutcome.init(reportedIsError:)) ?? .unreported
        timestamp = try? container.decode(String.self, forKey: .timestamp)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolCallId, forKey: .toolCallId)
        try container.encodeIfPresent(content, forKey: .content)
        switch errorOutcome {
        case .failed: try container.encode(true, forKey: .isError)
        case .succeeded: try container.encode(false, forKey: .isError)
        case .unreported: break
        }
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
    }
}

nonisolated struct ImageBlock: Codable {
    let type: String
    let data: String?
    let attachmentId: String?
    let mimeType: String?

    init(type: String, data: String? = nil, attachmentId: String? = nil, mimeType: String? = nil) {
        self.type = type
        self.data = data
        self.attachmentId = attachmentId
        self.mimeType = mimeType
    }
}

nonisolated struct QueuedMessage: Identifiable, Codable {
    let id: String
    var content: String
    let queuedAt: String
    var position: Int
    var imageBlocks: [ImageBlock] {
        didSet { imageBlocksWereProvided = true }
    }
    var messageMetadata: [String: AnyCodable] {
        didSet { messageMetadataWasProvided = true }
    }
    private var imageBlocksWereProvided: Bool
    private var messageMetadataWasProvided: Bool

    private enum CodingKeys: String, CodingKey { case id, content, queuedAt, position, imageBlocks, messageMetadata }

    init(
        id: String,
        content: String,
        queuedAt: String,
        position: Int,
        imageBlocks: [ImageBlock] = [],
        messageMetadata: [String: AnyCodable] = [:],
        imageBlocksWereProvided: Bool = false,
        messageMetadataWasProvided: Bool = false
    ) {
        self.id = id
        self.content = content
        self.queuedAt = queuedAt
        self.position = position
        self.imageBlocks = imageBlocks
        self.messageMetadata = messageMetadata
        self.imageBlocksWereProvided = imageBlocksWereProvided || !imageBlocks.isEmpty
        self.messageMetadataWasProvided = messageMetadataWasProvided || !messageMetadata.isEmpty
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        queuedAt = try container.decode(String.self, forKey: .queuedAt)
        position = try container.decode(Int.self, forKey: .position)
        if var imageBlocksContainer = try? container.nestedUnkeyedContainer(forKey: .imageBlocks) {
            imageBlocks = Self.decodeLenientArray(ImageBlock.self, from: &imageBlocksContainer)
            imageBlocksWereProvided = true
        } else {
            imageBlocks = []
            imageBlocksWereProvided = false
        }
        if let decodedMetadata = try? container.decode([String: AnyCodable].self, forKey: .messageMetadata) {
            messageMetadata = decodedMetadata
            messageMetadataWasProvided = true
        } else {
            messageMetadata = [:]
            messageMetadataWasProvided = false
        }
    }

    private static func decodeLenientArray<Element: Decodable>(
        _: Element.Type,
        from container: inout UnkeyedDecodingContainer
    ) -> [Element] {
        var items: [Element] = []
        while !container.isAtEnd {
            guard let elementDecoder = try? container.superDecoder() else { break }
            if let item = try? Element(from: elementDecoder) {
                items.append(item)
            }
        }
        return items
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(queuedAt, forKey: .queuedAt)
        try container.encode(position, forKey: .position)
        if imageBlocksWereProvided { try container.encode(imageBlocks, forKey: .imageBlocks) }
        if messageMetadataWasProvided { try container.encode(messageMetadata, forKey: .messageMetadata) }
    }

    var hasReportedImageBlocks: Bool { imageBlocksWereProvided }
    var hasReportedMessageMetadata: Bool { messageMetadataWasProvided }

    var isUserMessage: Bool {
        let metadata = messageMetadata
        if metadata["type"]?.stringValue == "question_answers" { return true }
        if metadata["type"]?.stringValue != nil { return false }
        if let fromAgentId = metadata["fromAgentId"]?.stringValue,
           !fromAgentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if metadata["source"]?.stringValue == "system" { return false }
        return true
    }
}

nonisolated struct ConversationMessage: Identifiable, Codable, Equatable {
    let id: String
    var appMessageId: String?
    let role: MessageRole
    var contentBlocks: [ContentBlock] {
        didSet { contentBlocksWereProvided = true }
    }
    var timestamp: String
    var turnNumber: Int?
    var toolCalls: [ToolCall] {
        didSet { toolCallsWereProvided = true }
    }
    var toolResults: [ToolResult] {
        didSet { toolResultsWereProvided = true }
    }
    var error: String?
    var streamingState: MessageStreamingState
    var metadata: [String: AnyCodable] {
        didSet { metadataWasProvided = true }
    }
    private var contentBlocksWereProvided: Bool
    private var toolCallsWereProvided: Bool
    private var toolResultsWereProvided: Bool
    private var metadataWasProvided: Bool

    var isStreaming: Bool {
        get { streamingState == .streaming }
        set { streamingState = newValue ? .streaming : .complete }
    }

    var hasReportedContentBlocks: Bool { contentBlocksWereProvided }
    var hasReportedToolCalls: Bool { toolCallsWereProvided }
    var hasReportedToolResults: Bool { toolResultsWereProvided }
    var hasReportedMetadata: Bool { metadataWasProvided }

    enum CodingKeys: String, CodingKey {
        case id, appMessageId, role, contentBlocks, timestamp, turnNumber
        case toolCalls, toolResults, error, isStreaming, metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let messageId = try container.decode(String.self, forKey: .id)
        id = messageId
        appMessageId = try? container.decode(String.self, forKey: .appMessageId)
        role = (try? container.decode(MessageRole.self, forKey: .role)) ?? .system
        if var blocksContainer = try? container.nestedUnkeyedContainer(forKey: .contentBlocks) {
            contentBlocks = Self.decodeContentBlocks(from: &blocksContainer, messageId: messageId)
            contentBlocksWereProvided = true
        } else {
            contentBlocks = []
            contentBlocksWereProvided = false
        }
        timestamp = (try? container.decode(String.self, forKey: .timestamp)) ?? ""
        turnNumber = try? container.decode(Int.self, forKey: .turnNumber)
        if var toolCallsContainer = try? container.nestedUnkeyedContainer(forKey: .toolCalls) {
            toolCalls = Self.decodeLenientArray(ToolCall.self, from: &toolCallsContainer)
            toolCallsWereProvided = true
        } else {
            toolCalls = []
            toolCallsWereProvided = false
        }
        if var toolResultsContainer = try? container.nestedUnkeyedContainer(forKey: .toolResults) {
            toolResults = Self.decodeLenientArray(ToolResult.self, from: &toolResultsContainer)
            toolResultsWereProvided = true
        } else {
            toolResults = []
            toolResultsWereProvided = false
        }
        error = try? container.decode(String.self, forKey: .error)
        streamingState = (try? container.decode(Bool.self, forKey: .isStreaming))
            .map(MessageStreamingState.init(reportedStreaming:)) ?? .unreported
        if let decodedMetadata = try? container.decode([String: AnyCodable].self, forKey: .metadata) {
            metadata = decodedMetadata
            metadataWasProvided = true
        } else {
            metadata = [:]
            metadataWasProvided = false
        }
    }

    // MARK: - Convenience initializer

    init(
        id: String,
        role: MessageRole,
        contentBlocks: [ContentBlock] = [],
        timestamp: String = ISO8601DateFormatter().string(from: Date()),
        turnNumber: Int? = nil,
        toolCalls: [ToolCall] = [],
        toolResults: [ToolResult] = [],
        error: String? = nil,
        streamingState: MessageStreamingState = .unreported,
        metadata: [String: AnyCodable] = [:],
        contentBlocksWereProvided: Bool = false,
        toolCallsWereProvided: Bool = false,
        toolResultsWereProvided: Bool = false,
        metadataWasProvided: Bool = false,
        appMessageId: String? = nil
    ) {
        self.id = id
        self.appMessageId = appMessageId
        self.role = role
        self.contentBlocks = contentBlocks
        self.contentBlocksWereProvided = contentBlocksWereProvided || !contentBlocks.isEmpty
        self.timestamp = timestamp
        self.turnNumber = turnNumber
        self.toolCalls = toolCalls
        self.toolCallsWereProvided = toolCallsWereProvided || !toolCalls.isEmpty
        self.toolResults = toolResults
        self.toolResultsWereProvided = toolResultsWereProvided || !toolResults.isEmpty
        self.error = error
        self.streamingState = streamingState
        self.metadata = metadata
        self.metadataWasProvided = metadataWasProvided || !metadata.isEmpty
    }

    // MARK: - Parsing from dictionary (JSON-RPC response)

    static func parseMessage(_ dict: [String: Any]) -> Self? {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func parseMessages(_ rows: [[String: Any]]) -> [Self] {
        guard !rows.isEmpty else { return [] }
        guard JSONSerialization.isValidJSONObject(rows),
              let data = try? JSONSerialization.data(withJSONObject: rows),
              let page = try? JSONDecoder().decode(LenientPage.self, from: data) else {
            return rows.compactMap { parseMessage($0) }
        }
        return page.messages
    }

    private struct LenientPage: Decodable {
        let messages: [ConversationMessage]

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            messages = ConversationMessage.decodeLenientArray(ConversationMessage.self, from: &container)
        }
    }

    private static func decodeContentBlocks(
        from container: inout UnkeyedDecodingContainer,
        messageId: String
    ) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        while !container.isAtEnd {
            let index = container.currentIndex
            guard let elementDecoder = try? container.superDecoder() else { break }
            if let block = try? ContentBlock(
                from: elementDecoder,
                fallbackIdentity: .indexed(messageId: messageId, index: index)
            ) {
                blocks.append(block)
            }
        }
        return blocks
    }

    private static func decodeLenientArray<Element: Decodable>(
        _: Element.Type,
        from container: inout UnkeyedDecodingContainer
    ) -> [Element] {
        var items: [Element] = []
        while !container.isAtEnd {
            guard let elementDecoder = try? container.superDecoder() else { break }
            if let item = try? Element(from: elementDecoder) {
                items.append(item)
            }
        }
        return items
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(appMessageId, forKey: .appMessageId)
        if contentBlocksWereProvided { try container.encode(contentBlocks, forKey: .contentBlocks) }
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(turnNumber, forKey: .turnNumber)
        if toolCallsWereProvided { try container.encode(toolCalls, forKey: .toolCalls) }
        if toolResultsWereProvided { try container.encode(toolResults, forKey: .toolResults) }
        try container.encodeIfPresent(error, forKey: .error)
        switch streamingState {
        case .complete: try container.encode(false, forKey: .isStreaming)
        case .streaming: try container.encode(true, forKey: .isStreaming)
        case .unreported: break
        }
        if metadataWasProvided { try container.encode(metadata, forKey: .metadata) }
    }
}
