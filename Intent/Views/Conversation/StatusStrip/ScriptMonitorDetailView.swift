import SwiftUI

/// Read-only watch details in the app's shared sheet chrome.
struct ScriptMonitorDetailView: View {
    let viewModel: ConversationViewModel
    let selection: ScriptMonitorSelection
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias Style = CreateWorkspaceFormStyle

    private enum Layout {
        static let initialHeight: CGFloat = 560
        static let sectionSpacing: CGFloat = 24
        static let headingSpacing: CGFloat = 8
        static let rowSpacing: CGFloat = 16
        static let fieldSpacing: CGFloat = 4
    }

    var body: some View {
        ConnectionSheet(
            initialHeight: Layout.initialHeight,
            backgroundColor: Style.background(for: colorScheme),
            closeForeground: Style.foreground(for: colorScheme),
            scrollIdentifier: "script-monitor-details"
        ) {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                heading
                detailContent
            }
            .foregroundStyle(Style.foreground(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: selection.id) {
            await viewModel.scriptMonitorsStore.loadDetail(selection: selection.id)
        }
    }

    private var store: WorkspaceScriptMonitorsStore { viewModel.scriptMonitorsStore }
    private var secondary: Color { Style.secondary(for: colorScheme, contrast: contrast) }

    private var summary: ScriptMonitorSummary? {
        guard store.isSupported else { return nil }
        switch store.detailState(selection: selection.id) {
        case let .loaded(detail): return detail.summary
        case .loading, .failed: return store.detailSummary(selection: selection.id)
        case .unavailable: return nil
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: Layout.headingSpacing) {
            Text("Script watch")
                .interFont(Constants.Typography.heading2)
                .accessibilityAddTraits(.isHeader)
            if let summary {
                Text(verbatim: summary.scriptName)
                    .interFont(Constants.Typography.bodySEmphasized)
                    .textSelection(.enabled)
                ScriptMonitorClock { now in
                    Text(ScriptMonitorPresentation.expiry(summary.expiresAt, now: now))
                        .interFont(Constants.Typography.bodyXS)
                        .foregroundStyle(secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var detailContent: some View {
        if !store.isSupported {
            message("Script watch details are unavailable")
        } else {
            switch store.detailState(selection: selection.id) {
            case .loading:
                summaryContent
                Text("Loading full watch details…")
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(secondary)
            case let .loaded(detail):
                metadata(summary: detail.summary, detail: detail)
            case .unavailable:
                message("This watch is no longer available")
            case .failed:
                message("Script watch details are unavailable")
                Button("Retry details") {
                    Task { await store.loadDetail(selection: selection.id, retry: true) }
                }
                .buttonStyle(IntentButtonStyle(variant: .secondary))
                .frame(minHeight: Constants.Accessibility.minimumTapTarget)
                .accessibilityIdentifier("script-monitor-details-retry")
                summaryContent
            }
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        if let summary = store.detailSummary(selection: selection.id) {
            metadata(summary: summary, detail: nil)
        }
    }

    @ViewBuilder
    private func metadata(summary: ScriptMonitorSummary, detail: ScriptMonitorDetail?) -> some View {
        card {
            field("Owner", value: viewModel.scriptMonitorOwnerName)
            field("Mode", value: summary.mode == .command ? "Command" : "Service")
            field("Script ID", value: summary.scriptId)
            field("Watched run ID", value: summary.runId)
            field("Created", value: ScriptMonitorPresentation.absoluteDate(summary.createdAt) ?? "Creation time unavailable")
            field("Watch expires", value: ScriptMonitorPresentation.absoluteDate(summary.expiresAt) ?? "Expiry unavailable")
        }
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            message(ScriptMonitorPresentation.notificationExplanation)
            if let pattern = ScriptMonitorPresentation.pattern(summary: summary, detail: detail) {
                VStack(alignment: .leading, spacing: Layout.headingSpacing) {
                    Text(pattern.label)
                        .interFont(Constants.Typography.bodyXS)
                        .foregroundStyle(secondary)
                    card {
                        Text(verbatim: pattern.value)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if let lineCount = summary.lineCount {
                message(ScriptMonitorPresentation.lineTrigger(lineCount))
            }
        }
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Style.controlPadding)
            .background(Style.card(for: colorScheme), in: .rect(cornerRadius: Style.cornerRadius))
    }

    private func field(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Layout.fieldSpacing) {
            Text(label)
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(secondary)
            Text(verbatim: value)
                .interFont(Constants.Typography.bodyS)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .interFont(Constants.Typography.bodyS)
            .fixedSize(horizontal: false, vertical: true)
    }
}
