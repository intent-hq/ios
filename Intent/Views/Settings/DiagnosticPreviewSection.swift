import SwiftUI

struct DiagnosticPreviewSection: View {
    let preview: DiagnosticPreview

    var body: some View {
        Section("Preview") {
            Text("Snapshot from \(preview.snapshot.metadata.generatedAt, format: .dateTime)")
            Text("\(preview.rows.count) retained records")
            if preview.snapshot.metadata.loss.storageUnavailable {
                Label("Some history could not be read or saved. This report may be incomplete.", systemImage: "exclamationmark.triangle")
            }
            if preview.rows.isEmpty { Text("No recent diagnostic events.") }
            DisclosureGroup("Metadata and coverage") {
                Text(verbatim: preview.metadata)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            ForEach(preview.rows) { row in
                DiagnosticRecordRow(row: row)
            }
        }
    }
}

private struct DiagnosticRecordRow: View {
    let row: DiagnosticPreview.PreviewRow

    var body: some View {
        VStack(alignment: .leading) {
            Text(verbatim: row.record.event.kind.rawValue).font(.headline)
            Text(verbatim: "\(row.record.event.operation.rawValue) · \(row.record.event.outcome.rawValue)")
            Text("Occurrences: \(row.record.count)")
            Text("First: \(row.record.firstTimestamp, format: .dateTime)")
            Text("Last: \(row.record.lastTimestamp, format: .dateTime)")
            DisclosureGroup("All recorded fields") {
                Text(verbatim: row.json)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}
