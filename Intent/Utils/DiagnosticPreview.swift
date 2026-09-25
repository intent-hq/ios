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
            // JSONDecoder can skip malformed UTF-8 in unknown fields. Review
            // must show the original bytes, never replacement characters.
            guard let json = String(bytes: line, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            return PreviewRow(
                id: "\(record.session.uuidString)-\(record.sequence)",
                record: record,
                json: json
            )
        }
        let encoder = DiagnosticEncoding.encoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        guard let metadata = String(bytes: try encoder.encode(snapshot.metadata), encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return Self(snapshot: snapshot, rows: rows, metadata: metadata)
    }
}
