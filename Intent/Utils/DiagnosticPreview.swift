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

    @concurrent
    static func make(_ snapshot: DiagnosticSnapshot) async throws -> Self {
        let decoder = DiagnosticEncoding.decoder()
        let rows = try snapshot.jsonLines.split(separator: DiagnosticEncoding.newline).map { line in
            try Task.checkCancellation()
            let record = try decoder.decode(DiagnosticRecord.self, from: Data(line))
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
