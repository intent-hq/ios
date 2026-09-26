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

private struct DiagnosticExportActions: View {
    let model: DiagnosticExportModel
    @Binding var confirmsClear: Bool

    var body: some View {
        Section {
            preparationStatus
            Button { model.shareZIP() } label: {
                Label {
                    Text("Share ZIP").interFont(Constants.Typography.bodyS)
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
                .disabled(model.isWorking || model.preview == nil || model.share != nil)
                .accessibilityIdentifier("diagnosticShareZIP")
            Button { model.refresh() } label: {
                Label {
                    Text("Refresh").interFont(Constants.Typography.bodyS)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
                .disabled(model.isWorking || model.share != nil)
            Button(role: .destructive) { confirmsClear = true } label: {
                Label {
                    Text("Clear").interFont(Constants.Typography.bodyS)
                } icon: {
                    Image(systemName: "trash")
                }
            }
                .disabled(model.isWorking || model.share != nil)
                .accessibilityIdentifier("diagnosticClear")
        }
    }

    @ViewBuilder private var preparationStatus: some View {
        if model.isWorking {
            ProgressView { Text("Preparing logs…").interFont(Constants.Typography.bodyS) }
        }
        if let notice = model.notice {
            Text(notice).interFont(Constants.Typography.bodyS).accessibilityIdentifier("diagnosticNotice")
        }
    }
}
