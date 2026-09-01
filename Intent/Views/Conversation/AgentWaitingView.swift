import SwiftUI

struct AgentWaitingView: View {
    let viewModel: ConversationViewModel
    private let store: ConversationStore
    let onNavigateToAgent: ((String, String, String) -> Void)?
    @Environment(\.colorScheme) var colorScheme

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
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(Constants.Conversation.AgentWaiting.progressScale)

                    Text(headerText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                // Agent rows
                if !store.watchedAgents.isEmpty {
                    Divider()
                        .padding(.horizontal, 16)

                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(store.watchedAgents) { agent in
                                if let onNavigateToAgent {
                                    Button {
                                        onNavigateToAgent(agent.id, viewModel.workspaceId, agent.name)
                                    } label: {
                                        agentRow(agent, showChevron: true)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        agentContextMenu(agent)
                                    }
                                } else {
                                    agentRow(agent)
                                        .contextMenu {
                                            agentContextMenu(agent)
                                        }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: min(
                        CGFloat(store.watchedAgents.count) * Constants.Conversation.AgentWaiting.rowHeight,
                        Constants.Conversation.AgentWaiting.maximumListHeight))
                } else if !store.watchedAgentIds.isEmpty {
                    // Fallback: show agent IDs if details haven't loaded yet
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(store.watchedAgentIds, id: \.self) { agentId in
                                HStack(spacing: 10) {
                                    ProgressView()
                                        .scaleEffect(Constants.Conversation.AgentWaiting.fallbackProgressScale)
                                    Text(agentId.prefix(
                                        Constants.Conversation.AgentWaiting.fallbackAgentIdMaximumLength
                                    ) + "...")
                                        .font(.caption)
                                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                            }
                        }
                    }
                    .frame(maxHeight: min(
                        CGFloat(store.watchedAgentIds.count) * Constants.Conversation.AgentWaiting.fallbackRowHeight,
                        Constants.Conversation.AgentWaiting.fallbackMaximumListHeight))
                }
            }
            .background(Theme.card(for: colorScheme))
        }
    }

    @ViewBuilder
    private func agentRow(_ agent: AgentSession, showChevron: Bool = false) -> some View {
        HStack(spacing: 8) {
            // Avatar with status indicator
            ZStack(alignment: .topTrailing) {
                AgentAvatarView(
                    agentId: agent.id,
                    size: Constants.Conversation.AgentWaiting.avatarSize,
                    specialist: agent.specialist,
                    isActive: agent.isActive)

                if agent.isErrored {
                    // Red X for errored agents
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Constants.Conversation.AgentWaiting.badgeFontSize))
                        .foregroundStyle(.red)
                        .background(Circle().fill(Theme.card(for: colorScheme)).frame(
                            width: Constants.Conversation.AgentWaiting.badgeSize,
                            height: Constants.Conversation.AgentWaiting.badgeSize))
                        .offset(
                            x: Constants.Conversation.AgentWaiting.badgeOffset,
                            y: -Constants.Conversation.AgentWaiting.badgeOffset)
                } else if let attention = agent.pendingAttentionRequest {
                    // Kind-flavored badge for pending attention requests
                    Image(systemName: attention.kind.systemImage)
                        .font(.system(size: Constants.Conversation.AgentWaiting.badgeFontSize))
                        .foregroundStyle(attention.kind.color)
                        .background(Circle().fill(Theme.card(for: colorScheme)).frame(
                            width: Constants.Conversation.AgentWaiting.badgeSize,
                            height: Constants.Conversation.AgentWaiting.badgeSize))
                        .offset(
                            x: Constants.Conversation.AgentWaiting.badgeOffset,
                            y: -Constants.Conversation.AgentWaiting.badgeOffset)
                } else if !agent.isActive && agent.digest != nil {
                    // Green checkmark for completed agents with digest
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: Constants.Conversation.AgentWaiting.badgeFontSize))
                        .foregroundStyle(.green)
                        .background(Circle().fill(Theme.card(for: colorScheme)).frame(
                            width: Constants.Conversation.AgentWaiting.badgeSize,
                            height: Constants.Conversation.AgentWaiting.badgeSize))
                        .offset(
                            x: Constants.Conversation.AgentWaiting.badgeOffset,
                            y: -Constants.Conversation.AgentWaiting.badgeOffset)
                } else if agent.isActive {
                    // Green dot for active agents
                    Circle()
                        .fill(Color.green)
                        .frame(
                            width: Constants.Conversation.AgentWaiting.activeDotSize,
                            height: Constants.Conversation.AgentWaiting.activeDotSize)
                        .offset(
                            x: Constants.Conversation.AgentWaiting.activeDotOffset,
                            y: -Constants.Conversation.AgentWaiting.activeDotOffset)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.caption)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .lineLimit(1)

                if let attention = agent.pendingAttentionRequest {
                    Text(attention.reason.map { "\(attention.kind.label) — \($0)" } ?? attention.kind.label)
                        .font(.caption2)
                        .foregroundStyle(attention.kind.color)
                        .lineLimit(1)
                } else if let message = agent.displayMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .lineLimit(1)
                } else {
                    Text(agent.isActive ? "Working..." : (agent.isErrored ? "Error" : "Idle"))
                        .font(.caption2)
                        .foregroundStyle(agent.isErrored ? .red : Theme.mutedForeground(for: colorScheme))
                }
            }

            Spacer()

            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
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

