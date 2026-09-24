import Foundation

nonisolated struct DiagnosticPreview: Sendable {
    struct PreviewRow: Identifiable, Sendable {
        let id: String
        let record: DiagnosticRecord
        let json: String
    }

    let snapshot: DiagnosticSnapshot
    let rows: [PreviewRow]
    let metadata: String

    /// Decode and format the bounded snapshot away from the UI actor. Raw
    /// console logs/errors are never inputs; these bytes came from the store's
    /// closed schema. The full JSON remains reviewable, not just a summary.
    @concurrent
    static func make(_ snapshot: DiagnosticSnapshot) async throws -> Self {
        let decoder = DiagnosticEncoding.decoder()
        let rows = try snapshot.jsonLines.split(separator: DiagnosticEncoding.newline).map { line in
            try Task.checkCancellation()
            let record = try decoder.decode(DiagnosticRecord.self, from: Data(line))
            return PreviewRow(
                id: "\(record.session.uuidString)-\(record.sequence)",
                record: record,
                json: String(decoding: line, as: UTF8.self)
            )
        }
        let encoder = DiagnosticEncoding.encoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        let metadata = String(decoding: try encoder.encode(snapshot.metadata), as: UTF8.self)
        return Self(snapshot: snapshot, rows: rows, metadata: metadata)
    }
}