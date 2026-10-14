import Foundation

// How a block gets its `id`: the wire `id`, a `FallbackIdentity` when the
// wire omits one (per-item and batched decodes), or a fresh UUID for
// programmatic creation.
nonisolated extension ContentBlock: DecodableWithConfiguration {
    /// Identity for a block served without a wire `id` (ios#257). A block
    /// decoded as part of a message takes the daemon's own synthetic
    /// `{messageId}:{index}` (PROTOCOL §7.1), so an id-less row keys exactly
    /// like a stamped one; a block decoded on its own is keyed by a
    /// deterministic fingerprint of its content, scoped to its message when
    /// known. Never a fresh UUID: re-decoding the same payload always yields
    /// the same id, so SwiftUI rows survive re-decodes.
    enum FallbackIdentity {
        case indexed(messageId: String, index: Int)
        case fingerprint(messageId: String?)
        case fixed(String)
    }

    init(from decoder: Decoder, configuration: FallbackIdentity) throws {
        try self.init(from: decoder, fallbackIdentity: configuration)
    }

    /// The id an id-less block takes under `identity`; `fingerprintParts` are
    /// the block's identifying fields, used only for `.fingerprint`.
    static func fallbackId(for identity: FallbackIdentity, fingerprintParts: [String?]) -> String {
        switch identity {
        case let .indexed(messageId, index):
            return "\(messageId):\(index)"
        case let .fixed(fixedId):
            return fixedId
        case let .fingerprint(messageId):
            return "\(messageId ?? "block"):\(contentFingerprint(fingerprintParts))"
        }
    }

    static func decode(
        _ dictionary: [String: Any],
        fallbackIdentity: FallbackIdentity = .fingerprint(messageId: nil)
    ) -> Self? {
        guard JSONSerialization.isValidJSONObject(dictionary),
              let data = try? JSONSerialization.data(withJSONObject: dictionary) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data, configuration: fallbackIdentity)
    }

    /// `decode` for a whole batch (ios#258): one serialization and one
    /// `JSONDecoder` for every dictionary instead of one pair per element.
    /// Element `i` decodes with `fallbackIdentities[i]`; the result keeps one
    /// slot per input, nil where that element does not decode. When the batch
    /// as a whole cannot be serialized (a non-finite number in one element)
    /// every element is decoded on its own, so the outcome per element is the
    /// same either way.
    static func decodeBatch(
        _ dictionaries: [[String: Any]],
        fallbackIdentities: [FallbackIdentity]
    ) -> [Self?] {
        precondition(dictionaries.count == fallbackIdentities.count)
        guard !dictionaries.isEmpty else { return [] }
        guard JSONSerialization.isValidJSONObject(dictionaries),
              let data = try? JSONSerialization.data(withJSONObject: dictionaries) else {
            return zip(dictionaries, fallbackIdentities).map { decode($0, fallbackIdentity: $1) }
        }
        guard let batch = try? JSONDecoder().decode(Batch.self, from: data, configuration: fallbackIdentities),
              batch.blocks.count == dictionaries.count else {
            return zip(dictionaries, fallbackIdentities).map { decode($0, fallbackIdentity: $1) }
        }
        return batch.blocks
    }

    /// Lenient array decoder for `decodeBatch`: each element decodes with its
    /// own positional `FallbackIdentity`; a failing element yields nil.
    private struct Batch: DecodableWithConfiguration {
        let blocks: [ContentBlock?]

        init(from decoder: Decoder, configuration identities: [FallbackIdentity]) throws {
            var container = try decoder.unkeyedContainer()
            var blocks: [ContentBlock?] = []
            blocks.reserveCapacity(container.count ?? identities.count)
            while !container.isAtEnd {
                let index = container.currentIndex
                let elementDecoder = try container.superDecoder()
                let identity = index < identities.count ? identities[index] : .fingerprint(messageId: nil)
                blocks.append(try? ContentBlock(from: elementDecoder, fallbackIdentity: identity))
            }
            self.blocks = blocks
        }
    }

    private static let fnvOffsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3
    private static let fingerprintPresentTag: UInt8 = 0x01
    private static let fingerprintAbsentTag: UInt8 = 0x00
    private static let fingerprintFieldSeparator: UInt8 = 0x1f
    private static let fingerprintRadix = 16

    /// FNV-1a over the block's identifying fields (nil kept distinct from
    /// empty); process-independent, unlike `Hasher`.
    private static func contentFingerprint(_ parts: [String?]) -> String {
        var hash = fnvOffsetBasis
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash = hash &* fnvPrime
        }
        for part in parts {
            if let part {
                mix(fingerprintPresentTag)
                for byte in part.utf8 { mix(byte) }
            } else {
                mix(fingerprintAbsentTag)
            }
            mix(fingerprintFieldSeparator)
        }
        return String(hash, radix: fingerprintRadix)
    }
}

nonisolated extension ContentBlock {
    init(
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
        self.init(
            id: UUID().uuidString,
            type: type,
            text: text,
            language: language,
            name: name,
            input: input,
            toolUseId: toolUseId,
            output: output,
            errorOutcome: errorOutcome,
            data: data,
            mimeType: mimeType,
            fileName: fileName,
            attachmentId: attachmentId,
            size: size,
            resource: resource,
            metadata: metadata,
            messageMetadata: messageMetadata,
            inputWasProvided: inputWasProvided,
            metadataWasProvided: metadataWasProvided,
            messageMetadataWasProvided: messageMetadataWasProvided,
            inputTruncation: inputTruncation,
            inputBytes: inputBytes,
            outputTruncation: outputTruncation,
            outputBytes: outputBytes,
            dataTruncation: dataTruncation,
            dataRepresentation: dataRepresentation,
            dataBytes: dataBytes
        )
    }
}
