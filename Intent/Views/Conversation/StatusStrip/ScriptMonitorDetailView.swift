import SwiftUI

struct ScriptMonitorDetailView: View {
    let viewModel: ConversationViewModel
    let selection: ScriptMonitorSelection
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading) {
                    detailContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .background(Theme.background(for: colorScheme))
            .accessibilityIdentifier("script-monitor-details")
            .navigationTitle("Script watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background(for: colorScheme), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { viewModel.closeScriptMonitor() }
                        .frame(minHeight: Constants.Accessibility.minimumTapTarget)
                        .accessibilityIdentifier("script-monitor-details-close")
                }
            }
        }
        .presentationBackground(Theme.background(for: colorScheme))
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: selection.id) {
            await viewModel.scriptMonitorsStore.loadDetail(selection: selection.id)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if !viewModel.scriptMonitorsStore.isSupported {
            Text("Script watch details are unavailable")
        } else {
            switch viewModel.scriptMonitorsStore.detailState(selection: selection.id) {
            case .loading:
                summaryMetadata
                Text("Loading full watch details…")
                    .font(.caption)
            case let .loaded(detail):
                metadata(summary: detail.summary, detail: detail)
            case .unavailable:
                Text("This watch is no longer available")
            case .failed:
                Text("Script watch details are unavailable")
                Button("Retry details") {
                    Task { await viewModel.scriptMonitorsStore.loadDetail(selection: selection.id, retry: true) }
                }
                .buttonStyle(IntentButtonStyle(variant: .secondary))
                .frame(minHeight: Constants.Accessibility.minimumTapTarget)
                .accessibilityIdentifier("script-monitor-details-retry")
                summaryMetadata
            }
        }
    }

    @ViewBuilder
    private var summaryMetadata: some View {
        if let summary = viewModel.scriptMonitorsStore.detailSummary(selection: selection.id) {
            metadata(summary: summary, detail: nil)
        }
    }

    private func metadata(summary: ScriptMonitorSummary, detail: ScriptMonitorDetail?) -> some View {
        VStack(alignment: .leading) {
            field("Script", value: summary.scriptName)
            field("Mode", value: summary.mode == .command ? "Command" : "Service")
            field("Owner", value: viewModel.scriptMonitorOwnerName)
            field("Script ID", value: summary.scriptId)
            field("Watched run ID", value: summary.runId)
            field("Created", value: ScriptMonitorPresentation.absoluteDate(summary.createdAt) ?? "Creation time unavailable")
            field("Watch expires", value: ScriptMonitorPresentation.absoluteDate(summary.expiresAt) ?? "Expiry unavailable")
            ScriptMonitorClock { now in
                Text(ScriptMonitorPresentation.expiry(summary.expiresAt, now: now))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text(ScriptMonitorPresentation.notificationExplanation)
                .fixedSize(horizontal: false, vertical: true)
            if let pattern = ScriptMonitorPresentation.pattern(summary: summary, detail: detail) {
                field(pattern.label, value: pattern.value, monospaced: true)
            }
            if let lineCount = summary.lineCount {
                Text(ScriptMonitorPresentation.lineTrigger(lineCount))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func field(_ label: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(monospaced ? .body.monospaced() : .body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom)
        .accessibilityElement(children: .combine)
    }
}
