import SwiftUI

struct WorkspaceAgentGroupSnapshot {
    enum LoadStatus {
        case empty
        case failed(String)
        case loading
        case ready
    }

    let agents: [AgentSession]
    let totalCount: Int
    let runningCount: Int
    let isExpanded: Bool
    let identifier: String
    let status: LoadStatus
}

struct WorkspaceAgentTreeRow: View {
    let button: WorkspaceAgentButton
    let depth: Int
    let group: WorkspaceAgentGroupSnapshot?
    let colorScheme: ColorScheme
    let onLoadGroup: @MainActor () async -> Void
    let onToggle: @MainActor () -> Void
    let onRetry: @MainActor () -> Void

    var body: some View {
        VStack(spacing: WorkspaceDetailStyle.stackTopSpacing) {
            button
            if let group {
                DelegatedAgentsRow(
                    agents: group.agents,
                    totalCount: group.totalCount,
                    runningCount: group.runningCount,
                    isExpanded: group.isExpanded,
                    colorScheme: colorScheme,
                    onToggle: onToggle
                )
                .accessibilityIdentifier(group.identifier)
                .task(id: group.identifier) { await onLoadGroup() }
                if group.isExpanded {
                    WorkspaceAgentGroupStatus(status: group.status, identifier: group.identifier, onRetry: onRetry)
                }
            }
        }
        .padding(.leading, CGFloat(max(0, depth - 1)) * WorkspaceDetailStyle.avatarSpacing)
    }
}

struct WorkspaceAgentButton: View {
    let agent: AgentSession
    let colorScheme: ColorScheme
    let indented: Bool
    let onSelect: @MainActor () -> Void
    let onMute: @MainActor () -> Void

    var body: some View {
        Button(action: onSelect) {
            AgentRowView(agent: agent, colorScheme: colorScheme, indented: indented)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityIdentifier("workspace.agent.\(agent.id)")
        .visionListRowHitTarget()
        .contextMenu {
            AgentNotificationsMuteButton(agent: agent, action: onMute)
        }
    }
}

struct WorkspaceAgentGroupStatus: View {
    let status: WorkspaceAgentGroupSnapshot.LoadStatus
    let identifier: String
    let onRetry: @MainActor () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch status {
        case .loading:
            ProgressView("Loading agents…")
                .font(.caption)
                .accessibilityIdentifier(identifier + ".loading")
        case let .failed(error):
            VStack {
                Text(error).interFont(Constants.Typography.subtextXXS)
                Button("Retry", action: onRetry)
                    .buttonStyle(IntentButtonStyle(variant: .secondary))
                    .accessibilityIdentifier(identifier + ".retry")
            }
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        case .empty:
            Text("No agents in this group")
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        case .ready:
            EmptyView()
        }
    }
}
