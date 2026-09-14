import Foundation

/// Decodes daemon JSON dictionaries (already parsed by `JSONSerialization`)
/// into wire models through one shared `JSONDecoder` instead of allocating a
/// decoder per value. Nonisolated so the off-main inbound frame parse can run
/// it; `JSONDecoder` is `Sendable` and reentrant.
nonisolated enum WireDictionaryDecoder {
    private static let decoder = JSONDecoder()

    static func decode<T: Decodable>(_ type: T.Type, from dictionary: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

/// The role of a message sender.
nonisolated enum MessageRole: String, Codable {
    case user
    case assistant
    case system
    case error

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = MessageRole(rawValue: rawValue) ?? .system
    }
}

/// A tool call within a conversation message.
nonisolated struct ToolCall: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    var arguments: AnyCodable?
    var result: AnyCodable?
    var error: String?
    var status: String?  // pending, running, completed, failed
    var timestamp: String?

    // Legacy aliases
    private var toolName: String?
    private var parameters: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case id, name, arguments, result, error, status, timestamp
        case toolName, parameters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)

        // name with fallback to toolName
        let decodedName = try? container.decode(String.self, forKey: .name)
        let decodedToolName = try? container.decode(String.self, forKey: .toolName)
        name = decodedName ?? decodedToolName ?? "unknown"
        toolName = decodedToolName

        // arguments with fallback to parameters
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

    init(id: String, name: String, arguments: AnyCodable? = nil, result: AnyCodable? = nil,
         error: String? = nil, status: String? = nil) {
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

/// A tool result within a conversation message.
nonisolated struct ToolResult: Codable, Equatable {
    let toolCallId: String
    var content: AnyCodable?
    var isError: Bool?
    var timestamp: String?
}

/// An image block for queued messages. Either arm as accepted by the daemon
/// (PROTOCOL §5.5): inline base64 `data` (legacy) or an attachment-registry
/// `attachmentId` reference (monorepo#3338). Synthesized Codable omits nil
/// keys, so placed references never carry a `data` key on the wire.
struct ImageBlock: Codable {
    let type: String  // "image"
    let data: String?  // base64 (inline arm; nil for placed references)
    let attachmentId: String?  // attachment-registry reference
    let mimeType: String?  // optional on the reference arm (§5.5)

    init(type: String, data: String? = nil, attachmentId: String? = nil, mimeType: String? = nil) {
        self.type = type
        self.data = data
        self.attachmentId = attachmentId
        self.mimeType = mimeType
    }
}

/// A queued message waiting to be sent to an agent.
struct QueuedMessage: Identifiable, Codable {
    let id: String
    var content: String
    let queuedAt: String
    var position: Int
    var imageBlocks: [ImageBlock]?
    var messageMetadata: [String: AnyCodable]? = nil

    /// Whether this entry was authored by the user. Non-user entries carry
    /// `messageMetadata` with a string `type` (except the user-authored
    /// `question_answers` wizard tag), a non-blank `fromAgentId`, or
    /// `source == "system"` (PROTOCOL §5.5); absent/malformed metadata fails
    /// open (treated as user-authored).
    var isUserMessage: Bool {
        guard let metadata = messageMetadata else { return true }
        // The Q&A wizard's answer message is USER-authored despite its tag
        // (`{ type: "question_answers", answeredQuestionsMessageId }`): it
        // travels through the ordinary send path and can be auto-queued
        // during the turn-startup race, so it must stay visible in the queue.
        if metadata["type"]?.stringValue == "question_answers" { return true }
        if metadata["type"]?.stringValue != nil { return false }
        if let fromAgentId = metadata["fromAgentId"]?.stringValue,
           !fromAgentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if metadata["source"]?.stringValue == "system" { return false }
        return true
    }
}

/// A single message in an agent conversation.
///
/// `Equatable` is synthesized over every stored field so transcript rows can
/// be compared by value and skip re-rendering when a streaming delta did not
/// touch them (see `MessageRowContent`).
struct ConversationMessage: Identifiable, Codable, Equatable {
    let id: String
    let role: MessageRole
    var contentBlocks: [ContentBlock]?
    var timestamp: String  // ISO 8601 string from server
    var turnNumber: Int?
    var toolCalls: [ToolCall]?
    var toolResults: [ToolResult]?
    var error: String?
    var isStreaming: Bool?
    var metadata: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case id, role, contentBlocks, timestamp, turnNumber
        case toolCalls, toolResults, error, isStreaming, metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = (try? container.decode(MessageRole.self, forKey: .role)) ?? .system
        contentBlocks = try? container.decode([ContentBlock].self, forKey: .contentBlocks)
        timestamp = (try? container.decode(String.self, forKey: .timestamp)) ?? ""
        turnNumber = try? container.decode(Int.self, forKey: .turnNumber)
        toolCalls = try? container.decode([ToolCall].self, forKey: .toolCalls)
        toolResults = try? container.decode([ToolResult].self, forKey: .toolResults)
        error = try? container.decode(String.self, forKey: .error)
        isStreaming = try? container.decode(Bool.self, forKey: .isStreaming)
        metadata = try? container.decode([String: AnyCodable].self, forKey: .metadata)
    }

    // MARK: - Convenience initializer

    /// Nonisolated (with `parseMessage`) so chat snapshots can be built off
    /// MainActor in the inbound frame parse.
    nonisolated init(
        id: String,
        role: MessageRole,
        contentBlocks: [ContentBlock]? = nil,
        timestamp: String = ISO8601DateFormatter().string(from: Date()),
        turnNumber: Int? = nil,
        toolCalls: [ToolCall]? = nil,
        toolResults: [ToolResult]? = nil,
        error: String? = nil,
        isStreaming: Bool? = nil,
        metadata: [String: AnyCodable]? = nil
    ) {
        self.id = id
        self.role = role
        self.contentBlocks = contentBlocks
        self.timestamp = timestamp
        self.turnNumber = turnNumber
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.error = error
        self.isStreaming = isStreaming
        self.metadata = metadata
    }

    // MARK: - Parsing from dictionary (JSON-RPC response)

    nonisolated static func parseMessage(_ dict: [String: Any]) -> ConversationMessage? {
        guard let id = dict["id"] as? String else { return nil }

        let roleStr = dict["role"] as? String ?? "system"
        let role = MessageRole(rawValue: roleStr) ?? .system

        var contentBlocks: [ContentBlock]?
        if let blocksArray = dict["contentBlocks"] as? [[String: Any]] {
            contentBlocks = blocksArray.compactMap { ContentBlock.decode($0) }
        }

        var toolCalls: [ToolCall]?
        if let callsArray = dict["toolCalls"] as? [[String: Any]] {
            toolCalls = callsArray.compactMap { WireDictionaryDecoder.decode(ToolCall.self, from: $0) }
        }

        var toolResults: [ToolResult]?
        if let resultsArray = dict["toolResults"] as? [[String: Any]] {
            toolResults = resultsArray.compactMap { WireDictionaryDecoder.decode(ToolResult.self, from: $0) }
        }

        var metadata: [String: AnyCodable]?
        if let metaDict = dict["metadata"] as? [String: Any] {
            metadata = metaDict.mapValues { AnyCodable($0) }
        }

        return ConversationMessage(
            id: id,
            role: role,
            contentBlocks: contentBlocks,
            timestamp: dict["timestamp"] as? String ?? "",
            turnNumber: dict["turnNumber"] as? Int,
            toolCalls: toolCalls,
            toolResults: toolResults,
            error: dict["error"] as? String,
            isStreaming: dict["isStreaming"] as? Bool,
            metadata: metadata
        )
    }
}

