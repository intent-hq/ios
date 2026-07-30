import SwiftUI

struct AgentWaitingView: View {
    @ObservedObject var viewModel: ConversationViewModel
    var onNavigateToAgent: ((String, String, String) -> Void)?
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        if viewModel.store.isWaitingForAgents {
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)

                    Text(headerText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                // Agent rows
                if !viewModel.store.watchedAgents.isEmpty {
                    Divider()
                        .padding(.horizontal, 16)

                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(viewModel.store.watchedAgents) { agent in
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
                    .frame(maxHeight: min(CGFloat(viewModel.store.watchedAgents.count) * 44, 132))
                } else if !viewModel.store.watchedAgentIds.isEmpty {
                    // Fallback: show agent IDs if details haven't loaded yet
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(viewModel.store.watchedAgentIds, id: \.self) { agentId in
                                HStack(spacing: 10) {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                    Text(agentId.prefix(12) + "...")
                                        .font(.caption)
                                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                            }
                        }
                    }
                    .frame(maxHeight: min(CGFloat(viewModel.store.watchedAgentIds.count) * 40, 120))
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
                AuggieAvatarView(seed: agent.id, size: 22, specialist: agent.specialist, isActive: agent.isActive)

                if agent.isErrored {
                    // Red X for errored agents
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.red)
                        .background(Circle().fill(Theme.card(for: colorScheme)).frame(width: 10, height: 10))
                        .offset(x: 2, y: -2)
                } else if let attention = agent.pendingAttentionRequest {
                    // Kind-flavored badge for pending attention requests
                    Image(systemName: attention.kind.systemImage)
                        .font(.system(size: 8))
                        .foregroundStyle(attention.kind.color)
                        .background(Circle().fill(Theme.card(for: colorScheme)).frame(width: 10, height: 10))
                        .offset(x: 2, y: -2)
                } else if !agent.isActive && agent.digest != nil {
                    // Green checkmark for completed agents with digest
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.green)
                        .background(Circle().fill(Theme.card(for: colorScheme)).frame(width: 10, height: 10))
                        .offset(x: 2, y: -2)
                } else if agent.isActive {
                    // Green dot for active agents
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                        .offset(x: 1, y: -1)
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
        let count = viewModel.store.watchedAgentIds.count
        if let status = viewModel.store.delegationGroupStatus {
            return "Waiting for all (\(status.completed)/\(status.total))"
        }
        return "Waiting for \(count) agent\(count == 1 ? "" : "s")"
    }
}

