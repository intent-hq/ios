import SwiftUI

struct AgentWaitingView: View {
    let viewModel: ConversationViewModel
    private let store: ConversationStore
    let onNavigateToAgent: ((String, String, String) -> Void)?
    @Environment(\.colorScheme) var colorScheme

    private static let headerSpacing: CGFloat = 8
    private static let horizontalPadding: CGFloat = 16
    private static let headerVerticalPadding: CGFloat = 8
    private static let fallbackRowSpacing: CGFloat = 10
    private static let rowVerticalPadding: CGFloat = 6
    private static let agentRowSpacing: CGFloat = 8

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
                HStack(spacing: Self.headerSpacing) {
                    ProgressView()
                        .scaleEffect(Constants.Conversation.AgentWaiting.progressScale)

                    Text(headerText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))

                    Spacer()
                }
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, Self.headerVerticalPadding)

                // Agent rows
                if !store.watchedAgents.isEmpty {
                    Divider()
                        .padding(.horizontal, Self.horizontalPadding)

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
                        Constants.Conversation.AgentWaiting.maximumListHeight
                    ))
                } else if !store.watchedAgentIds.isEmpty {
                    // Fallback: show agent IDs if details haven't loaded yet
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(store.watchedAgentIds, id: \.self) { agentId in
                                HStack(spacing: Self.fallbackRowSpacing) {
                                    ProgressView()
                                        .scaleEffect(Constants.Conversation.AgentWaiting.fallbackProgressScale)
                                    Text(agentId.prefix(
                                        Constants.Conversation.AgentWaiting.fallbackAgentIdMaximumLength
                                    ) + "...")
                                        .font(.caption)
                                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                    Spacer()
                                }
                                .padding(.horizontal, Self.horizontalPadding)
                                .padding(.vertical, Self.rowVerticalPadding)
                            }
                        }
                    }
                    .frame(maxHeight: min(
                        CGFloat(store.watchedAgentIds.count) * Constants.Conversation.AgentWaiting.fallbackRowHeight,
                        Constants.Conversation.AgentWaiting.fallbackMaximumListHeight
                    ))
                }
            }
            .background(Theme.card(for: colorScheme))
        }
    }

    @ViewBuilder
    private func agentRow(_ agent: AgentSession, showChevron: Bool = false) -> some View {
        HStack(spacing: Self.agentRowSpacing) {
            // Avatar with status indicator
            ZStack(alignment: .topTrailing) {
                AgentAvatarView(
                    agentId: agent.id,
                    size: Constants.Conversation.AgentWaiting.avatarSize,
                    specialist: agent.specialist,
                    isActive: agent.isActive
                )

                if agent.isErrored {
                    // Red X for errored agents
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Constants.Conversation.AgentWaiting.badgeFontSize))
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                        .background(Circle().fill(Theme.card(for: colorScheme)).frame(
                            width: Constants.Conversation.AgentWaiting.badgeSize,
                            height: Constants.Conversation.AgentWaiting.badgeSize
                        ))
                        .offset(
                            x: Constants.Conversation.AgentWaiting.badgeOffset,
                            y: -Constants.Conversation.AgentWaiting.badgeOffset
                        )
                } else if let attention = agent.pendingAttentionRequest {
                    // Kind-flavored badge for pending attention requests
                    Image(systemName: attention.kind.systemImage)
                        .font(.system(size: Constants.Conversation.AgentWaiting.badgeFontSize))
                        .foregroundStyle(attention.kind.color)
                        .accessibilityHidden(true)
                        .background(Circle().fill(Theme.card(for: colorScheme)).frame(
                            width: Constants.Conversation.AgentWaiting.badgeSize,
                            height: Constants.Conversation.AgentWaiting.badgeSize
                        ))
                        .offset(
                            x: Constants.Conversation.AgentWaiting.badgeOffset,
                            y: -Constants.Conversation.AgentWaiting.badgeOffset
                        )
                } else if !agent.isActive, agent.digest != nil {
                    // Green checkmark for completed agents with digest
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: Constants.Conversation.AgentWaiting.badgeFontSize))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                        .background(Circle().fill(Theme.card(for: colorScheme)).frame(
                            width: Constants.Conversation.AgentWaiting.badgeSize,
                            height: Constants.Conversation.AgentWaiting.badgeSize
                        ))
                        .offset(
                            x: Constants.Conversation.AgentWaiting.badgeOffset,
                            y: -Constants.Conversation.AgentWaiting.badgeOffset
                        )
                } else if agent.isActive {
                    // Green dot for active agents
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
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.rowVerticalPadding)
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
