import SwiftUI

struct AgentWaitingView: View {
    let viewModel: ConversationViewModel
    private let store: ConversationStore
    let onNavigateToAgent: ((String, String, String) -> Void)?
    @Environment(\.colorScheme) var colorScheme

    private typealias Layout = Constants.Conversation.AgentWaiting

    init(
        viewModel: ConversationViewModel,
        store: ConversationStore,
        onNavigateToAgent: ((String, String, String) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.store = store
        self.onNavigateToAgent = onNavigateToAgent
    }

    var body: some View {
        if store.isWaitingForAgents {
            waitingContent
        }
    }

    private var waitingContent: some View {
        VStack(spacing: 0) {
            waitingHeader
            waitingList
        }
        .background(Theme.card(for: colorScheme))
    }

    private var waitingHeader: some View {
        HStack(spacing: Layout.headerSpacing) {
            ProgressView()
                .scaleEffect(Constants.Conversation.AgentWaiting.progressScale)
            Text(headerText)
                .interFont(Constants.Typography.bodyXSEmphasized)
                .foregroundStyle(Theme.foreground(for: colorScheme))
            Spacer()
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.headerVerticalPadding)
    }

    @ViewBuilder
    private var waitingList: some View {
        if !store.watchedAgents.isEmpty {
            Divider()
                .padding(.horizontal, Layout.horizontalPadding)
            watchedAgentsList
        } else if !store.watchedAgentIds.isEmpty {
            watchedAgentIdsList
        }
    }

    private var watchedAgentsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(store.watchedAgents) { agent in
                    watchedAgentRow(agent)
                }
            }
        }
        .frame(maxHeight: min(
            CGFloat(store.watchedAgents.count) * Constants.Conversation.AgentWaiting.rowHeight,
            Constants.Conversation.AgentWaiting.maximumListHeight
        ))
    }

    @ViewBuilder
    private func watchedAgentRow(_ agent: AgentSession) -> some View {
        if let onNavigateToAgent {
            Button {
                onNavigateToAgent(agent.id, viewModel.workspaceId, agent.name)
            } label: {
                agentRow(agent, showChevron: true)
            }
            .buttonStyle(.plain)
            .contextMenu { agentContextMenu(agent) }
        } else {
            agentRow(agent)
                .contextMenu { agentContextMenu(agent) }
        }
    }

    private var watchedAgentIdsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(store.watchedAgentIds, id: \.self) { agentId in
                    fallbackRow(agentId)
                }
            }
        }
        .frame(maxHeight: min(
            CGFloat(store.watchedAgentIds.count) * Constants.Conversation.AgentWaiting.fallbackRowHeight,
            Constants.Conversation.AgentWaiting.fallbackMaximumListHeight
        ))
    }

    private func fallbackRow(_ agentId: String) -> some View {
        HStack(spacing: Layout.fallbackRowSpacing) {
            ProgressView()
                .scaleEffect(Constants.Conversation.AgentWaiting.fallbackProgressScale)
            Text(agentId.prefix(Constants.Conversation.AgentWaiting.fallbackAgentIdMaximumLength) + "...")
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Spacer()
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.rowVerticalPadding)
    }

    @ViewBuilder
    private func agentRow(_ agent: AgentSession, showChevron: Bool = false) -> some View {
        HStack(spacing: Layout.agentRowSpacing) {
            agentAvatar(agent)
            agentDescription(agent)
            Spacer()
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.rowVerticalPadding)
        .contentShape(Rectangle())
    }

    private func agentAvatar(_ agent: AgentSession) -> some View {
        ZStack(alignment: .topTrailing) {
            AgentAvatarView(
                agentId: agent.id,
                size: Constants.Conversation.AgentWaiting.avatarSize,
                specialist: agent.specialist,
                isActive: agent.isActive
            )
            agentStatusBadge(agent)
        }
    }

    @ViewBuilder
    private func agentStatusBadge(_ agent: AgentSession) -> some View {
        if agent.isErrored {
            statusBadge(systemName: "xmark.circle.fill", color: .red)
        } else if let attention = agent.pendingAttentionRequest {
            statusBadge(systemName: attention.kind.systemImage, color: attention.kind.color)
        } else if !agent.isActive, agent.digest != nil {
            statusBadge(systemName: "checkmark.circle.fill", color: .green)
        } else if agent.isActive {
            activeStatusDot
        }
    }

    private func statusBadge(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: Constants.Conversation.AgentWaiting.badgeFontSize))
            .foregroundStyle(color)
            .accessibilityHidden(true)
            .background(Circle().fill(Theme.card(for: colorScheme)).frame(
                width: Constants.Conversation.AgentWaiting.badgeSize,
                height: Constants.Conversation.AgentWaiting.badgeSize
            ))
            .offset(
                x: Constants.Conversation.AgentWaiting.badgeOffset,
                y: -Constants.Conversation.AgentWaiting.badgeOffset
            )
    }

    private var activeStatusDot: some View {
        Circle()
            .fill(Color.green)
            .frame(
                width: Constants.Conversation.AgentWaiting.activeDotSize,
                height: Constants.Conversation.AgentWaiting.activeDotSize
            )
            .offset(
                x: Constants.Conversation.AgentWaiting.activeDotOffset,
                y: -Constants.Conversation.AgentWaiting.activeDotOffset
            )
    }

    private func agentDescription(_ agent: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: Layout.descriptionSpacing) {
            Text(agent.name)
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .lineLimit(1)
            if let attention = agent.pendingAttentionRequest {
                Text(attention.reason.map { "\(attention.kind.label) — \($0)" } ?? attention.kind.label)
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(attention.kind.color)
                    .lineLimit(1)
            } else if let message = agent.displayMessage {
                Text(message)
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .lineLimit(1)
            } else {
                Text(agent.isActive ? "Working..." : (agent.isErrored ? "Error" : "Idle"))
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(agent.isErrored ? .red : Theme.mutedForeground(for: colorScheme))
            }
        }
    }

    @ViewBuilder
    private func agentContextMenu(_ agent: AgentSession) -> some View {
        Button(role: .destructive) {
            Task { await viewModel.stopAgent(agentId: agent.id) }
        } label: {
            Label("Stop Agent", systemImage: "stop.fill")
        }

        Button {
            Task { await viewModel.cancelWait() }
        } label: {
            Label("Cancel Wait", systemImage: "xmark")
        }
    }

    private var headerText: String {
        let count = store.watchedAgentIds.count
        if let status = store.delegationGroupStatus {
            return "Waiting for all (\(status.completed)/\(status.total))"
        }
        return "Waiting for \(count) agent\(count == 1 ? "" : "s")"
    }
}
