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
            // Preserve native diagnostic list actions; only navigation uses Intent button chrome.
            // swiftlint:disable:next generic_button_style
            .buttonStyle(.automatic)
            .navigationTitle("Export logs")
            .toolbar { exportToolbar }
            .confirmationDialog("Clear local diagnostic logs?", isPresented: $confirmsClear, titleVisibility: .visible) {
                Button("Clear logs", role: .destructive) { model.clearHistory() }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $model.share) { lease in
                DiagnosticShareSheet(lease: lease) { id, failed, cleaned in
                    model.sharingFinished(id: id, failed: failed, cleaned: cleaned)
                }
            }
            .task { model.refreshIfNeeded() }
            .task(id: model.preview?.snapshot.expiresAt) { await model.refreshWhenExpired() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.refreshIfNeeded() }
            }
            .onChange(of: model.share?.id) { _, value in
                if value == nil { model.refreshIfNeeded() }
            }
            .onDisappear { model.cancelPreparation() }
        }
    }

    @ToolbarContentBuilder
    private var exportToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            IntentIconButton(icon: .close, label: "Close", showsBackground: false) {
                model.cancelPreparation()
                dismiss()
            }
            .accessibilityIdentifier("diagnosticClose")
        }
        .intentToolbarSurface()
    }
}

private struct DiagnosticExportActions: View {
    @ScaledMetric private var iconSize: CGFloat = 17
    let model: DiagnosticExportModel
    @Binding var confirmsClear: Bool

    var body: some View {
        Section {
            preparationStatus
            Button { model.shareZIP() } label: {
                Label {
                    Text("Share ZIP").interFont(Constants.Typography.bodyS)
                } icon: {
                    icon(.upload)
                }
            }
                .disabled(model.isWorking || model.preview == nil || model.share != nil)
                .accessibilityIdentifier("diagnosticShareZIP")
            Button { model.refresh() } label: {
                Label {
                    Text("Refresh").interFont(Constants.Typography.bodyS)
                } icon: {
                    icon(.clockwiseArrow)
                }
            }
                .disabled(model.isWorking || model.share != nil)
            Button(role: .destructive) { confirmsClear = true } label: {
                Label {
                    Text("Clear").interFont(Constants.Typography.bodyS)
                } icon: {
                    icon(.delete)
                }
            }
                .disabled(model.isWorking || model.share != nil)
                .accessibilityIdentifier("diagnosticClear")
        }
    }

    private func icon(_ image: ImageResource) -> some View {
        Image(image)
            .resizable()
            .scaledToFit()
            .frame(width: iconSize, height: iconSize)
            .accessibilityHidden(true)
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
