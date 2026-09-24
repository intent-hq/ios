import SwiftUI

/// No backend/session environment dependency: every entry point works offline.
struct DiagnosticExportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = DiagnosticExportModel()
    @State private var confirmsClear = false

    var body: some View {
        NavigationStack {
            List {
                DiagnosticExportActions(model: model, confirmsClear: $confirmsClear)
                DiagnosticPrivacySection()
                if let preview = model.preview {
                    DiagnosticPreviewSection(preview: preview)
                }
            }
            .navigationTitle("Export logs")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.cancelPreparation(); dismiss() }
                }
            }
            .confirmationDialog("Clear local diagnostic logs?", isPresented: $confirmsClear, titleVisibility: .visible) {
                Button("Clear logs", role: .destructive) { model.clearHistory() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("""
                    This removes local diagnostic history, not your saved connections or conversations. New events can still be recorded.
                    Files in an open share sheet are kept until sharing ends. Copies already shared cannot be recalled.
                    """)
            }
            .sheet(item: $model.share) { lease in
                DiagnosticShareSheet(lease: lease) { id, failed, cleaned in
                    model.sharingFinished(id: id, failed: failed, cleaned: cleaned)
                }
            }
            .task { model.refresh() }
            .task(id: model.preview?.snapshot.expiresAt) { await model.refreshWhenExpired() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.refresh() }
            }
            .onChange(of: model.share?.id) { _, value in
                if value == nil { model.refreshIfExpired() }
            }
            .onDisappear { model.cancelPreparation() }
        }
    }
}

private struct DiagnosticPrivacySection: View {
    var body: some View {
        Section("About these logs") {
            Text("Intent records selected diagnostic events on this device for up to 48 hours, with a 5 MiB history limit. Older events may rotate out sooner.")
            Text("The ZIP contains only events.jsonl and metadata.json: typed events and app, build, and OS versions.")
            Text("No conversation text, attachments, server addresses, credentials, or raw error messages are included.")
            Text("Coverage is partial: connection and lifecycle diagnostics are available, but some feature failures are not yet recorded. The metadata lists unfinished categories and exclusions.")
            Text("This is not crash capture. Abrupt termination can lose recent events.")
            Text("Nothing is uploaded automatically. Review the snapshot below, then choose Share ZIP and a destination. Newer events are included when the preview refreshes.")
        }
    }
}

private struct DiagnosticExportActions: View {
    let model: DiagnosticExportModel
    @Binding var confirmsClear: Bool

    var body: some View {
        Section {
            if model.isWorking { ProgressView("Preparing logs…") }
            if let notice = model.notice { Text(notice).accessibilityIdentifier("diagnosticNotice") }
            Button("Share ZIP", systemImage: "square.and.arrow.up") { model.shareZIP() }
                .disabled(model.isWorking || model.preview == nil || model.share != nil)
                .accessibilityIdentifier("diagnosticShareZIP")
            Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                .disabled(model.isWorking || model.share != nil)
            Button("Clear", systemImage: "trash", role: .destructive) { confirmsClear = true }
                .disabled(model.isWorking || model.share != nil)
                .accessibilityIdentifier("diagnosticClear")
        }
    }
}