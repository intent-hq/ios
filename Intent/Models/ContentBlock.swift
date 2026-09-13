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
    case resource

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ContentBlockType(rawValue: rawValue) ?? .text
    }
}

/// Nested contents of a standalone `resource` content block (PROTOCOL §7.1):
/// `{ type: "resource", resource: { uri?, mimeType, text } }`. Decoded leniently —
/// consumers validate the fields they need (e.g. question parsing is MIME-gated).
struct ResourceContents: Codable, Equatable {
    var uri: String?
    var mimeType: String?
    var text: String?
}

/// A content block within a conversation message.
/// Supports multiple content types (text, code, tool_use, tool_result, thinking, image, file, resource)
/// with backward-compatible field aliases.
///
/// `Equatable` is synthesized over every stored field (legacy aliases
/// included) so a `ConversationMessage` compares by value; `AnyCodable`
/// fields compare via their JSON encoding.
struct ContentBlock: Identifiable, Codable, Equatable {
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
    /// Attachment-registry reference for placed attachment blocks (PROTOCOL
    /// §5.5 v6.12) — persisted file/image references carry no inline `data`.
    var attachmentId: String?
    /// Byte length for attachment-reference file blocks.
    var size: Int?

    // Standalone resource block contents (type == .resource)
    var resource: ResourceContents?

    // Metadata
    var metadata: [String: AnyCodable]?
    private var meta: [String: AnyCodable]?  // wire alias for metadata (PROTOCOL §5.5 notice rows)
    /// Per-message send metadata persisted on the delivered block (PROTOCOL
    /// §5.5, e.g. the `questions_dismissed` dismissal notice tag).
    var messageMetadata: [String: AnyCodable]?

    // Slim projection truncation flags (PROTOCOL §5.5, opt-in via
    // `projection: "slim"`). A served block whose oversized body was replaced
    // by a bounded preview / thumbnail carries the additive flags below; the
    // full body is fetched on demand via `agent.getMessageBlock`.
    var inputTruncated: Bool?      // tool_use.input replaced by a bounded preview
    var inputBytes: Int?           // serialized byte size of the full input
    var outputTruncated: Bool?     // tool_result.output replaced by a bounded preview
    var outputBytes: Int?          // serialized byte size of the full output
    var dataTruncated: Bool?       // image.data replaced by a thumbnail (or omitted)
    var dataIsThumbnail: Bool?     // present with dataTruncated when data carries the thumbnail
    var dataBytes: Int?            // byte size of the full image data

    enum CodingKeys: String, CodingKey {
        case id, type, text, content, language, name, toolName
        case input, toolCallId, toolUseId, tool_use_id
        case output, isError, is_error
        case data, mimeType, fileName, attachmentId, size
        case resource, metadata, meta, messageMetadata
        case inputTruncated, inputBytes, outputTruncated, outputBytes
        case dataTruncated, dataIsThumbnail, dataBytes
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
        attachmentId = try? container.decode(String.self, forKey: .attachmentId)
        size = try? container.decode(Int.self, forKey: .size)
        resource = try? container.decode(ResourceContents.self, forKey: .resource)
        metadata = try? container.decode([String: AnyCodable].self, forKey: .metadata)
        meta = try? container.decode([String: AnyCodable].self, forKey: .meta)
        messageMetadata = try? container.decode([String: AnyCodable].self, forKey: .messageMetadata)

        inputTruncated = try? container.decode(Bool.self, forKey: .inputTruncated)
        inputBytes = try? container.decode(Int.self, forKey: .inputBytes)
        outputTruncated = try? container.decode(Bool.self, forKey: .outputTruncated)
        outputBytes = try? container.decode(Int.self, forKey: .outputBytes)
        dataTruncated = try? container.decode(Bool.self, forKey: .dataTruncated)
        dataIsThumbnail = try? container.decode(Bool.self, forKey: .dataIsThumbnail)
        dataBytes = try? container.decode(Int.self, forKey: .dataBytes)
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

    /// Resolved metadata, falling back to the wire `meta` alias used by
    /// daemon-persisted notice rows (e.g. `meta.kind = "discussion-request"`).
    var resolvedMetadata: [String: AnyCodable]? {
        metadata ?? meta
    }

    /// True when the daemon served this block slim-truncated (PROTOCOL §5.5):
    /// a `tool_use`/`tool_result` body reduced to a bounded preview, or an
    /// `image` reduced to a thumbnail/placeholder. Such a block can be
    /// hydrated to its full body on demand via `agent.getMessageBlock`.
    var isSlimTruncated: Bool {
        inputTruncated == true || outputTruncated == true || dataTruncated == true
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
        fileName: String? = nil,
        attachmentId: String? = nil,
        size: Int? = nil,
        resource: ResourceContents? = nil,
        metadata: [String: AnyCodable]? = nil,
        messageMetadata: [String: AnyCodable]? = nil,
        inputTruncated: Bool? = nil,
        inputBytes: Int? = nil,
        outputTruncated: Bool? = nil,
        outputBytes: Int? = nil,
        dataTruncated: Bool? = nil,
        dataIsThumbnail: Bool? = nil,
        dataBytes: Int? = nil
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
        self.attachmentId = attachmentId
        self.size = size
        self.resource = resource
        self.metadata = metadata
        self.meta = nil
        self.messageMetadata = messageMetadata
        self.inputTruncated = inputTruncated
        self.inputBytes = inputBytes
        self.outputTruncated = outputTruncated
        self.outputBytes = outputBytes
        self.dataTruncated = dataTruncated
        self.dataIsThumbnail = dataIsThumbnail
        self.dataBytes = dataBytes
    }
}

