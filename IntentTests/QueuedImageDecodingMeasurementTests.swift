import Foundation
@testable import Intent
import Testing

/// Informational same-binary A/B benchmark for the queued-image resilience fix.
/// `LegacyQueuedMessage` faithfully copies the pre-fix decoder at ffe8eaf; the
/// production `QueuedMessage` is the current path. Synthetic `Data` is prepared
/// before timing, both paths use a fresh `JSONDecoder` per message, and paired
/// sample order alternates to reduce first-run/order bias. Simulator Debug
/// timings are not CI thresholds or device/Release/UX/memory evidence.
@Suite(.serialized)
struct QueuedImageDecodingMeasurementTests {
    private static let sampleCount = 21
    private static let targetBytesPerSample = 512 * 1024
    private static let minimumBatchCount = 4
    private static let maximumBatchCount = 1000
    private static let inlineDataBytes = 4 * 1024

    private enum ImageArm: String {
        case reference
        case inlineData = "inline-data"
    }

    private enum Malformation: String {
        case none
        case firstObject = "first-object"
        case middlePrimitive = "middle-primitive"
        case lastNull = "last-null"
        case allMixed = "all-object-primitive-null"
    }

    private struct Fixture {
        let label: String
        let arm: ImageArm
        let malformation: Malformation
        let data: Data
        let arrayCount: Int
        let expectedIdentities: [String]

        var batchCount: Int {
            min(maximumBatchCount, max(minimumBatchCount, targetBytesPerSample / max(data.count, 1)))
        }

        var shape: String {
            "\(arm.rawValue)/\(malformation.rawValue)/\(arrayCount) entries"
        }

        var outputsAreEquivalent: Bool {
            malformation == .none
        }
    }

    private struct Samples {
        var legacy: [Double] = []
        var current: [Double] = []
        var legacyChecksums: [Int] = []
        var currentChecksums: [Int] = []
    }

    private struct Statistics {
        let median: Double
        let medianAbsoluteDeviation: Double
        let minimum: Double
        let maximum: Double
    }

    // MARK: - Fixtures

    private static func validImage(arm: ImageArm, index: Int) -> [String: Any] {
        switch arm {
        case .reference:
            return [
                "type": "image",
                "attachmentId": "attachment-\(String(format: "%04d", index))",
                "mimeType": "image/png"
            ]
        case .inlineData:
            let prefix = "inline-\(String(format: "%04d", index))-"
            return [
                "type": "image",
                "data": prefix + String(repeating: "A", count: inlineDataBytes - prefix.utf8.count),
                "mimeType": "image/png"
            ]
        }
    }

    private static func identity(of object: [String: Any]) -> String {
        (object["attachmentId"] as? String) ?? (object["data"] as? String) ?? ""
    }

    private static func fixture(
        label: String,
        arm: ImageArm,
        validCount: Int,
        malformation: Malformation = .none
    ) throws -> Fixture {
        let valid = (0..<validCount).map { validImage(arm: arm, index: $0) }
        var entries: [Any] = valid
        switch malformation {
        case .none:
            break
        case .firstObject:
            entries.insert(["type": 42], at: 0)
        case .middlePrimitive:
            entries.insert("malformed-primitive", at: entries.count / 2)
        case .lastNull:
            entries.append(NSNull())
        case .allMixed:
            let armSpecificObject: [String: Any] = arm == .reference
                ? ["type": "image", "attachmentId": 9]
                : ["type": "image", "data": 9]
            entries = [armSpecificObject, "primitive", NSNull(), [:], ["type": false], 7, NSNull(), ["data": 9]]
        }
        let payload: [String: Any] = [
            "id": "benchmark-queued-message",
            "content": "Synthetic queued-image decoder benchmark payload",
            "queuedAt": "2026-09-17T18:00:00Z",
            "position": 17,
            "imageBlocks": entries,
            "messageMetadata": [
                "type": "question_answers",
                "source": "synthetic-benchmark",
                "nested": ["attempt": 7, "flags": [true, false]],
                "nullable": NSNull()
            ]
        ]
        return try Fixture(
            label: label,
            arm: arm,
            malformation: malformation,
            data: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            arrayCount: entries.count,
            expectedIdentities: malformation == .allMixed ? [] : valid.map(identity)
        )
    }

    private static func fixtures() throws -> [Fixture] {
        var result: [Fixture] = []
        for arm in [ImageArm.reference, .inlineData] {
            for count in [1, 8, 64] {
                let scale = count == 64 ? "stress" : "small"
                result.append(try fixture(label: "valid-\(arm.rawValue)-\(count)-\(scale)", arm: arm, validCount: count))
            }
            result.append(try fixture(label: "malformed-\(arm.rawValue)-first", arm: arm, validCount: 8, malformation: .firstObject))
            result.append(try fixture(label: "malformed-\(arm.rawValue)-middle", arm: arm, validCount: 8, malformation: .middlePrimitive))
            result.append(try fixture(label: "malformed-\(arm.rawValue)-last", arm: arm, validCount: 8, malformation: .lastNull))
            result.append(try fixture(label: "malformed-\(arm.rawValue)-all", arm: arm, validCount: 0, malformation: .allMixed))
        }
        return result
    }

    // MARK: - Output verification and consumption

    private static func identity(of image: ImageBlock) -> String {
        image.attachmentId ?? image.data ?? ""
    }

    private static func verifyOutputs(for fixture: Fixture) throws {
        let current = try JSONDecoder().decode(QueuedMessage.self, from: fixture.data)
        let legacy = try JSONDecoder().decode(LegacyQueuedMessage.self, from: fixture.data)
        #expect(current.imageBlocks.map(identity) == fixture.expectedIdentities, "\(fixture.label) current identities")
        #expect(current.hasReportedImageBlocks, "\(fixture.label) current reporting state")
        #expect(current.hasReportedMessageMetadata)
        #expect(legacy.hasReportedMessageMetadata)
        #expect(current.messageMetadata.keys.sorted() == legacy.messageMetadata.keys.sorted())
        #expect(current.id == legacy.id)
        #expect(current.content == legacy.content)
        #expect(current.queuedAt == legacy.queuedAt)
        #expect(current.position == legacy.position)
        if fixture.outputsAreEquivalent {
            #expect(legacy.imageBlocks.map(identity) == fixture.expectedIdentities)
            #expect(legacy.hasReportedImageBlocks)
        } else {
            #expect(legacy.imageBlocks.isEmpty, "\(fixture.label) legacy whole-array loss")
            #expect(!legacy.hasReportedImageBlocks, "\(fixture.label) legacy early-abort reporting state")
        }
    }

    private static func imageBytes(_ images: [ImageBlock]) -> Int {
        var total = 0
        for image in images {
            let typeBytes: Int = image.type.utf8.count
            let dataBytes: Int = image.data?.utf8.count ?? 0
            let attachmentBytes: Int = image.attachmentId?.utf8.count ?? 0
            let mimeTypeBytes: Int = image.mimeType?.utf8.count ?? 0
            total += typeBytes
            total += dataBytes
            total += attachmentBytes
            total += mimeTypeBytes
        }
        return total
    }

    private static func checksum(_ message: QueuedMessage) -> Int {
        message.id.utf8.count + message.content.utf8.count + message.queuedAt.utf8.count + message.position
            + imageBytes(message.imageBlocks) + message.imageBlocks.count + message.messageMetadata.count
            + (message.hasReportedImageBlocks ? 1 : 0) + (message.hasReportedMessageMetadata ? 1 : 0)
    }

    private static func checksum(_ message: LegacyQueuedMessage) -> Int {
        message.id.utf8.count + message.content.utf8.count + message.queuedAt.utf8.count + message.position
            + imageBytes(message.imageBlocks) + message.imageBlocks.count + message.messageMetadata.count
            + (message.hasReportedImageBlocks ? 1 : 0) + (message.hasReportedMessageMetadata ? 1 : 0)
    }

    private static func decodeCurrent(_ data: Data, count: Int) throws -> Int {
        var total = 0
        for _ in 0..<count {
            let message = try JSONDecoder().decode(QueuedMessage.self, from: data)
            total += checksum(message)
        }
        return total
    }

    private static func decodeLegacy(_ data: Data, count: Int) throws -> Int {
        var total = 0
        for _ in 0..<count {
            let message = try JSONDecoder().decode(LegacyQueuedMessage.self, from: data)
            total += checksum(message)
        }
        return total
    }

    // MARK: - Timing and reporting

    private static func nanoseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000_000_000
            + Double(duration.components.attoseconds) / 1_000_000_000
    }

    private static func timed(_ body: () throws -> Int) rethrows -> (nanoseconds: Double, checksum: Int) {
        let clock = ContinuousClock()
        var result = 0
        let elapsed = try clock.measure { result = try body() }
        return (nanoseconds(elapsed), result)
    }

    private static func measure(_ fixture: Fixture) throws -> Samples {
        let batchCount = fixture.batchCount
        let warmLegacy = try decodeLegacy(fixture.data, count: batchCount)
        let warmCurrent = try decodeCurrent(fixture.data, count: batchCount)
        #expect(warmLegacy > 0)
        #expect(warmCurrent > 0)

        var samples = Samples()
        for sampleIndex in 0..<sampleCount {
            let legacy = { try timed { try decodeLegacy(fixture.data, count: batchCount) } }
            let current = { try timed { try decodeCurrent(fixture.data, count: batchCount) } }
            let pair = sampleIndex.isMultiple(of: 2)
                ? (try legacy(), try current())
                : (try current(), try legacy())
            let legacyResult = sampleIndex.isMultiple(of: 2) ? pair.0 : pair.1
            let currentResult = sampleIndex.isMultiple(of: 2) ? pair.1 : pair.0
            samples.legacy.append(legacyResult.nanoseconds / Double(batchCount))
            samples.current.append(currentResult.nanoseconds / Double(batchCount))
            samples.legacyChecksums.append(legacyResult.checksum)
            samples.currentChecksums.append(currentResult.checksum)
        }
        #expect(samples.legacyChecksums.allSatisfy { $0 == warmLegacy })
        #expect(samples.currentChecksums.allSatisfy { $0 == warmCurrent })
        return samples
    }

    private static func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    private static func statistics(_ values: [Double]) -> Statistics {
        let sampleMedian = median(values)
        return Statistics(
            median: sampleMedian,
            medianAbsoluteDeviation: median(values.map { abs($0 - sampleMedian) }),
            minimum: values.min() ?? 0,
            maximum: values.max() ?? 0
        )
    }

    private static func microseconds(_ nanoseconds: Double) -> String {
        String(format: "%.3f µs", nanoseconds / 1000.0)
    }

    private static func rawMicroseconds(_ values: [Double]) -> String {
        values.map { String(format: "%.3f", $0 / 1000.0) }.joined(separator: ",")
    }

    private static func report(fixture: Fixture, samples: Samples) {
        let legacy = statistics(samples.legacy)
        let current = statistics(samples.current)
        let difference = current.median - legacy.median
        let ratio = current.median / legacy.median
        let percent = difference / legacy.median * 100
        let currentCount = fixture.expectedIdentities.count
        let legacyCount = fixture.outputsAreEquivalent ? currentCount : 0
        let equivalence = fixture.outputsAreEquivalent ? "equivalent" : "non-equivalent correctness work"
        print(
            "[queued-image-benchmark] | \(fixture.label) | \(fixture.data.count) | \(fixture.shape) "
                + "| \(fixture.batchCount)×\(sampleCount) | \(legacyCount) | \(currentCount) "
                + "| \(microseconds(legacy.median)) ± \(microseconds(legacy.medianAbsoluteDeviation)) MAD "
                + "| \(microseconds(current.median)) ± \(microseconds(current.medianAbsoluteDeviation)) MAD "
                + "| \(microseconds(difference)) | \(String(format: "%.3fx", ratio)) "
                + "| \(String(format: "%+.1f%%", percent)) | \(equivalence) |"
        )
        print(
            "[queued-image-benchmark-raw] \(fixture.label) batch-normalized-us "
                + "legacy=[\(rawMicroseconds(samples.legacy))] current=[\(rawMicroseconds(samples.current))] "
                + "legacy-range=[\(microseconds(legacy.minimum)),\(microseconds(legacy.maximum))] "
                + "current-range=[\(microseconds(current.minimum)),\(microseconds(current.maximum))]"
        )
    }

    @Test func compareCurrentDecoderWithPreFixFullArrayDecoder() throws {
        print("[queued-image-benchmark] median batch-normalized per-decode time; dispersion is MAD, not request latency")
        print("[queued-image-benchmark] | fixture | bytes | array shape | batch×paired samples | legacy images | current images | legacy median ± MAD | current median ± MAD | current−legacy | ratio | delta | output work |")
        for fixture in try Self.fixtures() {
            try Self.verifyOutputs(for: fixture)
            Self.report(fixture: fixture, samples: try Self.measure(fixture))
        }
    }

    @Test func imageByteChecksumCountsUTF8AndIgnoresAbsentFields() {
        let images = [
            ImageBlock(type: "图像", data: "🙂", mimeType: "image/π"),
            ImageBlock(type: "image", attachmentId: "附件-β")
        ]

        #expect(Self.imageBytes([]) == 0)
        #expect(Self.imageBytes(images) == 32)
    }
}

/// Test-only copy of the complete `QueuedMessage` stored layout and decoder at
/// ffe8eaf3a8c9fe0d9e8d31a299b47c72053c185e. The unavoidable differences are
/// its distinct type name and omission of unused initializer/encoder/predicate
/// code; decoded fields, `ImageBlock`/`AnyCodable` work and reporting flags are
/// identical. It is never selected by production code.
nonisolated private struct LegacyQueuedMessage: Decodable {
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

    private enum CodingKeys: String, CodingKey {
        case id, content, queuedAt, position, imageBlocks, messageMetadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        queuedAt = try container.decode(String.self, forKey: .queuedAt)
        position = try container.decode(Int.self, forKey: .position)
        if let decodedImageBlocks = try? container.decode([ImageBlock].self, forKey: .imageBlocks) {
            imageBlocks = decodedImageBlocks
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

    var hasReportedImageBlocks: Bool { imageBlocksWereProvided }
    var hasReportedMessageMetadata: Bool { messageMetadataWasProvided }
}
