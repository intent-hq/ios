import Foundation

nonisolated struct DiagnosticRecord: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let session: UUID
    let sequence: UInt64
    let scope: UInt64?
    let event: DiagnosticEvent
    var count: UInt64 = 1
    let firstTimestamp: Date
    var lastTimestamp: Date

    var isValid: Bool {
        schemaVersion == 1 && sequence > 0 && count >= 1 && scope != 0
            && firstTimestamp.timeIntervalSince1970.isFinite
            && lastTimestamp.timeIntervalSince1970.isFinite
            && firstTimestamp <= lastTimestamp
    }

    func canMerge(_ next: Self) -> Bool {
        event.canSummarize && event == next.event && session == next.session && scope == next.scope
            && sequence <= UInt64.max - count && sequence + count == next.sequence
            && lastTimestamp <= next.firstTimestamp && count <= UInt64.max - next.count
    }
}

nonisolated struct DiagnosticSnapshot: Sendable {
    let jsonLines: Data
    let metadata: Metadata

    nonisolated struct Metadata: Encodable, Sendable {
        let schemaVersion = 1
        let coverageVersion = DiagnosticCoverage.version
        let pendingFamilies = DiagnosticCoverage.pendingFamilies
        let exclusions = DiagnosticCoverage.Exclusion.allCases
        let appVersion: String
        let appBuild: String
        let osVersion: String
        let generatedAt: Date
        let retainedRecords: Int
        let retentionHours = 48
        let maximumHistoryBytes = DiagnosticLimits.maximumHistoryBytes
        let loss: DiagnosticLoss

        init(generatedAt: Date, retainedRecords: Int, loss: DiagnosticLoss) {
            // App metadata is read internally and restricted to numeric version
            // strings. No device name, locale, path or stable device identifier.
            appVersion = Self.version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString"))
            appBuild = Self.version(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion"))
            let version = ProcessInfo.processInfo.operatingSystemVersion
            osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            self.generatedAt = generatedAt
            self.retainedRecords = retainedRecords
            self.loss = loss
        }

        private static func version(_ value: Any?) -> String {
            let maximumVersionLength = 32
            let digits: ClosedRange<UInt8> = 48...57
            let dot: UInt8 = 46
            guard let value = value as? String, !value.isEmpty,
                  value.count <= maximumVersionLength,
                  value.utf8.allSatisfy({ digits.contains($0) || $0 == dot }) else { return "unknown" }
            return value
        }
    }

    func metadataJSON() throws -> Data { try DiagnosticEncoding.encoder().encode(metadata) }
}

/// Best-effort current-process indicators, deliberately not a promise of
/// lossless capture. Abrupt termination can also lose the indicators themselves.
nonisolated struct DiagnosticLoss: Codable, Sendable {
    var queueOverflow: UInt64 = 0
    var invalidScope: UInt64 = 0
    var malformedRecords: UInt64 = 0
    var expiredRecords: UInt64 = 0
    var rotatedRecords: UInt64 = 0
    var storageUnavailable = false
    var historyReset = false
    var possibleUnflushedLoss = true
}

nonisolated enum DiagnosticEncoding {
    static let newline: UInt8 = 10

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

nonisolated struct DiagnosticLimits: Sendable {
    static let maximumHistoryBytes = 5_242_880
    static let maximumAge: TimeInterval = 172_800
    static let maximumPending = 256
    static let maximumRecordBytes = 2048
    let historyBytes: Int
    let age: TimeInterval
    let pending: Int

    init(
        historyBytes: Int = Self.maximumHistoryBytes,
        age: TimeInterval = Self.maximumAge,
        pending: Int = Self.maximumPending
    ) {
        self.historyBytes = min(max(Self.maximumRecordBytes, historyBytes), Self.maximumHistoryBytes)
        self.age = age.isFinite ? min(max(1, age), Self.maximumAge) : Self.maximumAge
        self.pending = min(max(1, pending), Self.maximumPending)
    }
}
