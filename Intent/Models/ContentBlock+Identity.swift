import Foundation

nonisolated extension ContentBlock: DecodableWithConfiguration {
    enum FallbackIdentity {
        case indexed(messageId: String, index: Int)
        case fingerprint(messageId: String?)
        case fixed(String)
    }

    init(from decoder: Decoder, configuration: FallbackIdentity) throws {
        try self.init(from: decoder, fallbackIdentity: configuration)
    }

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
