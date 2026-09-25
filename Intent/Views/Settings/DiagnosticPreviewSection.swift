import SwiftUI

struct DiagnosticPreviewSection: View {
    let preview: DiagnosticPreview

    var body: some View {
        Section {
            Text("Snapshot from \(preview.snapshot.metadata.generatedAt, format: .dateTime)")
                .interFont(Constants.Typography.bodyS)
            Text("\(preview.rows.count) retained records")
                .interFont(Constants.Typography.bodyS)
            if preview.snapshot.metadata.loss.storageUnavailable {
                Label {
                    Text("Some history could not be read or saved. This report may be incomplete.")
                        .interFont(Constants.Typography.bodyS)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            }
            if preview.rows.isEmpty {
                Text("No recent diagnostic events.").interFont(Constants.Typography.bodyS)
            }
            DisclosureGroup {
                Text(verbatim: preview.metadata)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } label: {
                Text("Metadata and coverage").interFont(Constants.Typography.bodyS)
            }
            ForEach(preview.rows) { row in
                DiagnosticRecordRow(row: row)
            }
        } header: {
            Text("Preview").interFont(Constants.Typography.eyebrow)
        }
    }
}

private struct DiagnosticRecordRow: View {
    let row: DiagnosticPreview.PreviewRow

    var body: some View {
        VStack(alignment: .leading) {
            Text(verbatim: row.record.event.kind.rawValue).interFont(Constants.Typography.bodyM)
            Text(verbatim: "\(row.record.event.operation.rawValue) · \(row.record.event.outcome.rawValue)")
                .interFont(Constants.Typography.bodyS)
            Text("Occurrences: \(row.record.count)")
                .interFont(Constants.Typography.bodyS)
            Text("First: \(row.record.firstTimestamp, format: .dateTime)")
                .interFont(Constants.Typography.bodyS)
            Text("Last: \(row.record.lastTimestamp, format: .dateTime)")
                .interFont(Constants.Typography.bodyS)
            DisclosureGroup {
                Text(verbatim: row.json)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } label: {
                Text("All recorded fields").interFont(Constants.Typography.bodyS)
            }
        }
    }
}
