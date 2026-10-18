import SwiftUI

/// Capsule shared by the status pills above the workspace composer. Pills hug
/// their content so several can share one row.
struct WorkspaceStatusPill<Trailing: View>: View {
    let icon: ImageResource
    let text: Text
    var truncates = false
    @ViewBuilder var trailing: Trailing
    @Environment(\.colorScheme) private var colorScheme

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        HStack(spacing: Design.Status.iconSpacing) {
            Image(icon)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: Design.smallIconSize, height: Design.smallIconSize)
                .accessibilityHidden(true)
            if truncates {
                text
                    .interFont(Design.Typography.status)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                text
                    .interFont(Design.Typography.status)
                    .fixedSize(horizontal: false, vertical: true)
            }
            trailing
        }
        .foregroundStyle(Design.Palette.foreground(for: colorScheme))
        .padding(.leading, Design.Status.leadingPadding)
        .padding(.trailing, Design.Status.trailingPadding)
        .frame(minHeight: Design.Status.minimumHeight)
        .background(Design.Palette.surface(for: colorScheme), in: Capsule())
        .frame(minHeight: Design.minimumTapTarget)
        .contentShape(Rectangle())
    }
}

extension WorkspaceStatusPill where Trailing == EmptyView {
    init(icon: ImageResource, text: Text, truncates: Bool = false) {
        self.init(icon: icon, text: text, truncates: truncates) { EmptyView() }
    }
}

/// One row above the workspace composer: PR monitors first, then script watches.
struct WorkspaceStatusPillsRow: View {
    let viewModel: ConversationViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Design.Status.composerSpacing))
            : AnyLayout(HStackLayout(spacing: Design.Status.composerSpacing))
        layout {
            if viewModel.showsPrMonitorStatus {
                MonitoredPrsRow(viewModel: viewModel, monitoredPrStore: viewModel.monitoredPrStore, usesWorkspaceDesign: true)
                    .layoutPriority(1)
            }
            if viewModel.showsScriptMonitorStatus {
                ScriptWatchPills(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ConversationViewModel {
    var showsPrMonitorStatus: Bool {
        !activeAgentMonitors.isEmpty || monitoredPrStore.error != nil
    }

    var showsWorkspaceStatusPills: Bool {
        showsPrMonitorStatus || showsScriptMonitorStatus
    }
}
