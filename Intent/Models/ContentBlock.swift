import Foundation

/// The type of a content block in a conversation message.
enum ContentBlockType: String, Codable {
    case text
    case code
    case toolUse = "tool_use"
    case toolResult = "tool_result"
    case thinking
    case image
    case file

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ContentBlockType(rawValue: rawValue) ?? .text
    }
}

/// A content block within a conversation message.
/// Supports multiple content types (text, code, tool_use, tool_result, thinking, image, file)
/// with backward-compatible field aliases.
struct ContentBlock: Identifiable, Codable {
    /// Auto-generated if not present in JSON
    let id: String
    let type: ContentBlockType

    // Text content fields
    var text: String?
    private var content: String?  // legacy alias for text

    // Code block fields
    var language: String?

    // Tool use fields
    var name: String?
    private var toolName: String?  // legacy alias for name
    var input: [String: AnyCodable]?
    var toolCallId: String?

    // Tool result fields
    var toolUseId: String?
    private var tool_use_id: String?  // snake_case alias
    var output: AnyCodable?
    var isError: Bool?
    private var is_error: Bool?  // snake_case alias

    // Media fields (image/file)
    var data: String?       // base64 encoded
    var mimeType: String?
    var fileName: String?

    // Metadata
    var metadata: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case id, type, text, content, language, name, toolName
        case input, toolCallId, toolUseId, tool_use_id
        case output, isError, is_error
        case data, mimeType, fileName, metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Auto-generate ID if missing
        id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
        type = (try? container.decode(ContentBlockType.self, forKey: .type)) ?? .text

        // Text with fallback to content
        text = try? container.decode(String.self, forKey: .text)
        content = try? container.decode(String.self, forKey: .content)

        language = try? container.decode(String.self, forKey: .language)

        // Name with fallback to toolName
        name = try? container.decode(String.self, forKey: .name)
        toolName = try? container.decode(String.self, forKey: .toolName)

        input = try? container.decode([String: AnyCodable].self, forKey: .input)
        toolCallId = try? container.decode(String.self, forKey: .toolCallId)

        // toolUseId with fallback to tool_use_id
        toolUseId = try? container.decode(String.self, forKey: .toolUseId)
        tool_use_id = try? container.decode(String.self, forKey: .tool_use_id)

        output = try? container.decode(AnyCodable.self, forKey: .output)

        // isError with fallback to is_error
        isError = try? container.decode(Bool.self, forKey: .isError)
        is_error = try? container.decode(Bool.self, forKey: .is_error)

        data = try? container.decode(String.self, forKey: .data)
        mimeType = try? container.decode(String.self, forKey: .mimeType)
        fileName = try? container.decode(String.self, forKey: .fileName)
        metadata = try? container.decode([String: AnyCodable].self, forKey: .metadata)
    }

    /// Resolved text content, falling back to legacy `content` field.
    var resolvedText: String? {
        text ?? content
    }

    /// Resolved tool name, falling back to legacy `toolName` field.
    var resolvedName: String? {
        name ?? toolName
    }

    /// Resolved tool use ID, falling back to snake_case `tool_use_id` field.
    var resolvedToolUseId: String? {
        toolUseId ?? tool_use_id
    }

    /// Resolved error flag, falling back to snake_case `is_error` field.
    var resolvedIsError: Bool? {
        isError ?? is_error
    }

    // MARK: - Convenience initializer for programmatic creation

    init(
        id: String = UUID().uuidString,
        type: ContentBlockType,
        text: String? = nil,
        language: String? = nil,
        name: String? = nil,
        input: [String: AnyCodable]? = nil,
        toolUseId: String? = nil,
        output: AnyCodable? = nil,
        isError: Bool? = nil,
        data: String? = nil,
        mimeType: String? = nil,
        fileName: String? = nil
    ) {
        self.id = id
        self.type = type
        self.text = text
        self.content = nil
        self.language = language
        self.name = name
        self.toolName = nil
        self.input = input
        self.toolCallId = nil
        self.toolUseId = toolUseId
        self.tool_use_id = nil
        self.output = output
        self.isError = isError
        self.is_error = nil
        self.data = data
        self.mimeType = mimeType
        self.fileName = fileName
        self.metadata = nil
    }
}

