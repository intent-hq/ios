import Foundation

/// The role of a message sender.
enum MessageRole: String, Codable {
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
struct ToolCall: Identifiable, Codable {
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
struct ToolResult: Codable {
    let toolCallId: String
    var content: AnyCodable?
    var isError: Bool?
    var timestamp: String?
}

/// An image block for queued messages.
struct ImageBlock: Codable {
    let type: String  // "image"
    let data: String  // base64
    let mimeType: String
}

/// A queued message waiting to be sent to an agent.
struct QueuedMessage: Identifiable, Codable {
    let id: String
    var content: String
    let queuedAt: String
    var position: Int
    var imageBlocks: [ImageBlock]?
}

/// A single message in an agent conversation.
struct ConversationMessage: Identifiable, Codable {
    let id: String
    let role: MessageRole
    var contentBlocks: [ContentBlock]?
    let timestamp: String  // ISO 8601 string from server
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

    init(
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

    static func parseMessage(_ dict: [String: Any]) -> ConversationMessage? {
        guard let id = dict["id"] as? String else { return nil }

        let roleStr = dict["role"] as? String ?? "system"
        let role = MessageRole(rawValue: roleStr) ?? .system

        var contentBlocks: [ContentBlock]?
        if let blocksArray = dict["contentBlocks"] as? [[String: Any]] {
            contentBlocks = blocksArray.compactMap { blockDict -> ContentBlock? in
                guard let data = try? JSONSerialization.data(withJSONObject: blockDict),
                      let block = try? JSONDecoder().decode(ContentBlock.self, from: data) else {
                    return nil
                }
                return block
            }
        }

        var toolCalls: [ToolCall]?
        if let callsArray = dict["toolCalls"] as? [[String: Any]] {
            toolCalls = callsArray.compactMap { callDict -> ToolCall? in
                guard let data = try? JSONSerialization.data(withJSONObject: callDict),
                      let call = try? JSONDecoder().decode(ToolCall.self, from: data) else {
                    return nil
                }
                return call
            }
        }

        var toolResults: [ToolResult]?
        if let resultsArray = dict["toolResults"] as? [[String: Any]] {
            toolResults = resultsArray.compactMap { resultDict -> ToolResult? in
                guard let data = try? JSONSerialization.data(withJSONObject: resultDict),
                      let result = try? JSONDecoder().decode(ToolResult.self, from: data) else {
                    return nil
                }
                return result
            }
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

