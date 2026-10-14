import Foundation

/// The type of a content block in a conversation message.
nonisolated enum ContentBlockType: String, Codable {
    case code
    case file
    case image
    case resource
    case text
    case thinking
    case toolResult = "tool_result"
    case toolUse = "tool_use"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .text
    }
}

/// Nested contents of a standalone `resource` content block (PROTOCOL §7.1):
/// `{ type: "resource", resource: { uri?, mimeType, text } }`. Decoded leniently —
/// consumers validate the fields they need (e.g. question parsing is MIME-gated).
nonisolated struct ResourceContents: Codable, Equatable {
    var uri: String?
    var mimeType: String?
    var text: String?
}

nonisolated enum ToolExecutionOutcome: Equatable {
    case failed
    case succeeded
    case unreported

    init(reportedIsError: Bool) {
        self = reportedIsError ? .failed : .succeeded
    }

    var isFailure: Bool { self == .failed }
}

nonisolated enum ProjectionTruncation: Equatable {
    case full
    case truncated
    case unreported

    init(reportedTruncated: Bool) {
        self = reportedTruncated ? .truncated : .full
    }

    var isTruncated: Bool { self == .truncated }
}

nonisolated enum ImageDataRepresentation: Equatable {
    case full
    case thumbnail
    case unreported

    init(reportedThumbnail: Bool) {
        self = reportedThumbnail ? .thumbnail : .full
    }
}

/// A content block within a conversation message.
/// Supports multiple content types (text, code, tool_use, tool_result, thinking, image, file, resource)
/// with backward-compatible field aliases.
nonisolated struct ContentBlock: Identifiable, Codable, Equatable {
    /// Wire `id`, or the `FallbackIdentity`-derived id when absent
    /// (see `ContentBlock+Identity.swift`).
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
    var input: [String: AnyCodable] {
        didSet { inputWasProvided = true }
    }
    private var inputWasProvided: Bool
    var toolCallId: String?

    // Tool result fields
    var toolUseId: String?
    private var tool_use_id: String?  // snake_case alias
    var output: AnyCodable?
    var errorOutcome: ToolExecutionOutcome
    private var legacyErrorOutcome: ToolExecutionOutcome

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
    var metadata: [String: AnyCodable] {
        didSet { metadataWasProvided = true }
    }
    private var metadataWasProvided: Bool
    private var legacyMetadata: [String: AnyCodable]
    private var legacyMetadataWasProvided: Bool
    /// Per-message send metadata persisted on the delivered block (PROTOCOL
    /// §5.5, e.g. the `questions_dismissed` dismissal notice tag).
    var messageMetadata: [String: AnyCodable] {
        didSet { messageMetadataWasProvided = true }
    }
    private var messageMetadataWasProvided: Bool

    // Slim projection truncation flags (PROTOCOL §5.5, opt-in via
    // `projection: "slim"`). A served block whose oversized body was replaced
    // by a bounded preview / thumbnail carries the additive flags below; the
    // full body is fetched on demand via `agent.getMessageBlock`.
    var inputTruncation: ProjectionTruncation      // tool_use.input replaced by a bounded preview
    var inputBytes: Int?           // serialized byte size of the full input
    var outputTruncation: ProjectionTruncation     // tool_result.output replaced by a bounded preview
    var outputBytes: Int?          // serialized byte size of the full output
    var dataTruncation: ProjectionTruncation       // image.data replaced by a thumbnail (or omitted)
    var dataRepresentation: ImageDataRepresentation // whether present data is the thumbnail
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

    private static func decodeDictionary(
        for key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> (value: [String: AnyCodable], wasProvided: Bool) {
        guard let value = try? container.decode([String: AnyCodable].self, forKey: key) else {
            return ([:], false)
        }
        return (value, true)
    }

    init(from decoder: Decoder) throws {
        try self.init(from: decoder, fallbackIdentity: .fingerprint(messageId: nil))
    }

    /// The one block decoder: every decode path (message rows, delta
    /// entities, `agent.getMessageBlock` hydration, `JSONDecoder`) ends here,
    /// differing only in the identity an id-less block falls back to.
    init(from decoder: Decoder, fallbackIdentity: FallbackIdentity) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let wireId = try? container.decode(String.self, forKey: .id)
        type = (try? container.decode(ContentBlockType.self, forKey: .type)) ?? .text

        // Text with fallback to content
        text = try? container.decode(String.self, forKey: .text)
        content = try? container.decode(String.self, forKey: .content)

        language = try? container.decode(String.self, forKey: .language)

        // Name with fallback to toolName
        name = try? container.decode(String.self, forKey: .name)
        toolName = try? container.decode(String.self, forKey: .toolName)

        let decodedInput = Self.decodeDictionary(for: .input, from: container)
        input = decodedInput.value
        inputWasProvided = decodedInput.wasProvided
        toolCallId = try? container.decode(String.self, forKey: .toolCallId)

        // toolUseId with fallback to tool_use_id
        toolUseId = try? container.decode(String.self, forKey: .toolUseId)
        tool_use_id = try? container.decode(String.self, forKey: .tool_use_id)

        output = try? container.decode(AnyCodable.self, forKey: .output)

        // isError with fallback to is_error
        errorOutcome = (try? container.decode(Bool.self, forKey: .isError))
            .map(ToolExecutionOutcome.init(reportedIsError:)) ?? .unreported
        legacyErrorOutcome = (try? container.decode(Bool.self, forKey: .is_error))
            .map(ToolExecutionOutcome.init(reportedIsError:)) ?? .unreported

        data = try? container.decode(String.self, forKey: .data)
        mimeType = try? container.decode(String.self, forKey: .mimeType)
        fileName = try? container.decode(String.self, forKey: .fileName)
        attachmentId = try? container.decode(String.self, forKey: .attachmentId)
        size = try? container.decode(Int.self, forKey: .size)
        resource = try? container.decode(ResourceContents.self, forKey: .resource)
        let decodedMetadata = Self.decodeDictionary(for: .metadata, from: container)
        metadata = decodedMetadata.value
        metadataWasProvided = decodedMetadata.wasProvided
        let decodedLegacyMetadata = Self.decodeDictionary(for: .meta, from: container)
        legacyMetadata = decodedLegacyMetadata.value
        legacyMetadataWasProvided = decodedLegacyMetadata.wasProvided
        let decodedMessageMetadata = Self.decodeDictionary(for: .messageMetadata, from: container)
        messageMetadata = decodedMessageMetadata.value
        messageMetadataWasProvided = decodedMessageMetadata.wasProvided

        inputTruncation = (try? container.decode(Bool.self, forKey: .inputTruncated))
            .map(ProjectionTruncation.init(reportedTruncated:)) ?? .unreported
        inputBytes = try? container.decode(Int.self, forKey: .inputBytes)
        outputTruncation = (try? container.decode(Bool.self, forKey: .outputTruncated))
            .map(ProjectionTruncation.init(reportedTruncated:)) ?? .unreported
        outputBytes = try? container.decode(Int.self, forKey: .outputBytes)
        dataTruncation = (try? container.decode(Bool.self, forKey: .dataTruncated))
            .map(ProjectionTruncation.init(reportedTruncated:)) ?? .unreported
        dataRepresentation = (try? container.decode(Bool.self, forKey: .dataIsThumbnail))
            .map(ImageDataRepresentation.init(reportedThumbnail:)) ?? .unreported
        dataBytes = try? container.decode(Int.self, forKey: .dataBytes)

        id = wireId ?? Self.fallbackId(for: fallbackIdentity, fingerprintParts: [
            type.rawValue, text, content, language, name, toolName, toolCallId, toolUseId, tool_use_id,
            data, mimeType, fileName, attachmentId, size.map { String($0) },
            resource?.uri, resource?.mimeType, resource?.text
        ])
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
    var resolvedErrorOutcome: ToolExecutionOutcome {
        errorOutcome == .unreported ? legacyErrorOutcome : errorOutcome
    }

    /// Resolved metadata, falling back to the wire `meta` alias used by
    /// daemon-persisted notice rows (e.g. `meta.kind = "discussion-request"`).
    var resolvedMetadata: [String: AnyCodable] {
        metadataWasProvided ? metadata : legacyMetadata
    }

    var hasReportedInput: Bool { inputWasProvided }
    var hasReportedMetadata: Bool { metadataWasProvided }
    var hasReportedMessageMetadata: Bool { messageMetadataWasProvided }

    mutating func inheritInput(from block: Self) {
        input = block.input
        inputWasProvided = block.inputWasProvided
    }

    /// True when the daemon served this block slim-truncated (PROTOCOL §5.5):
    /// a `tool_use`/`tool_result` body reduced to a bounded preview, or an
    /// `image` reduced to a thumbnail/placeholder. Such a block can be
    /// hydrated to its full body on demand via `agent.getMessageBlock`.
    var isSlimTruncated: Bool {
        inputTruncation.isTruncated || outputTruncation.isTruncated || dataTruncation.isTruncated
    }

    // MARK: - Convenience initializer for programmatic creation

    init(
        id: String,
        type: ContentBlockType,
        text: String? = nil,
        language: String? = nil,
        name: String? = nil,
        input: [String: AnyCodable] = [:],
        toolUseId: String? = nil,
        output: AnyCodable? = nil,
        errorOutcome: ToolExecutionOutcome = .unreported,
        data: String? = nil,
        mimeType: String? = nil,
        fileName: String? = nil,
        attachmentId: String? = nil,
        size: Int? = nil,
        resource: ResourceContents? = nil,
        metadata: [String: AnyCodable] = [:],
        messageMetadata: [String: AnyCodable] = [:],
        inputWasProvided: Bool = false,
        metadataWasProvided: Bool = false,
        messageMetadataWasProvided: Bool = false,
        inputTruncation: ProjectionTruncation = .unreported,
        inputBytes: Int? = nil,
        outputTruncation: ProjectionTruncation = .unreported,
        outputBytes: Int? = nil,
        dataTruncation: ProjectionTruncation = .unreported,
        dataRepresentation: ImageDataRepresentation = .unreported,
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
        self.inputWasProvided = inputWasProvided || !input.isEmpty
        self.toolCallId = nil
        self.toolUseId = toolUseId
        self.tool_use_id = nil
        self.output = output
        self.errorOutcome = errorOutcome
        self.legacyErrorOutcome = .unreported
        self.data = data
        self.mimeType = mimeType
        self.fileName = fileName
        self.attachmentId = attachmentId
        self.size = size
        self.resource = resource
        self.metadata = metadata
        self.metadataWasProvided = metadataWasProvided || !metadata.isEmpty
        self.legacyMetadata = [:]
        self.legacyMetadataWasProvided = false
        self.messageMetadata = messageMetadata
        self.messageMetadataWasProvided = messageMetadataWasProvided || !messageMetadata.isEmpty
        self.inputTruncation = inputTruncation
        self.inputBytes = inputBytes
        self.outputTruncation = outputTruncation
        self.outputBytes = outputBytes
        self.dataTruncation = dataTruncation
        self.dataRepresentation = dataRepresentation
        self.dataBytes = dataBytes
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(toolName, forKey: .toolName)
        if inputWasProvided { try container.encode(input, forKey: .input) }
        try container.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try container.encodeIfPresent(toolUseId, forKey: .toolUseId)
        try container.encodeIfPresent(tool_use_id, forKey: .tool_use_id)
        try container.encodeIfPresent(output, forKey: .output)
        try encode(errorOutcome, to: &container, forKey: .isError)
        try encode(legacyErrorOutcome, to: &container, forKey: .is_error)
        try container.encodeIfPresent(data, forKey: .data)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(fileName, forKey: .fileName)
        try container.encodeIfPresent(attachmentId, forKey: .attachmentId)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(resource, forKey: .resource)
        if metadataWasProvided { try container.encode(metadata, forKey: .metadata) }
        if legacyMetadataWasProvided { try container.encode(legacyMetadata, forKey: .meta) }
        if messageMetadataWasProvided { try container.encode(messageMetadata, forKey: .messageMetadata) }
        try encode(inputTruncation, to: &container, forKey: .inputTruncated)
        try container.encodeIfPresent(inputBytes, forKey: .inputBytes)
        try encode(outputTruncation, to: &container, forKey: .outputTruncated)
        try container.encodeIfPresent(outputBytes, forKey: .outputBytes)
        try encode(dataTruncation, to: &container, forKey: .dataTruncated)
        try encode(dataRepresentation, to: &container, forKey: .dataIsThumbnail)
        try container.encodeIfPresent(dataBytes, forKey: .dataBytes)
    }

    private func encode(
        _ outcome: ToolExecutionOutcome,
        to container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        switch outcome {
        case .failed: try container.encode(true, forKey: key)
        case .succeeded: try container.encode(false, forKey: key)
        case .unreported: break
        }
    }

    private func encode(
        _ truncation: ProjectionTruncation,
        to container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        switch truncation {
        case .full: try container.encode(false, forKey: key)
        case .truncated: try container.encode(true, forKey: key)
        case .unreported: break
        }
    }

    private func encode(
        _ representation: ImageDataRepresentation,
        to container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        switch representation {
        case .full: try container.encode(false, forKey: key)
        case .thumbnail: try container.encode(true, forKey: key)
        case .unreported: break
        }
    }
}
