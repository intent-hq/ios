import SwiftUI

struct AgentWaitingView: View {
    let viewModel: ConversationViewModel
    private let store: ConversationStore
    let onNavigateToAgent: ((String, String, String) -> Void)?
    @Environment(\.colorScheme) var colorScheme
    @ScaledMetric(relativeTo: .caption2) private var disclosureIconSide: CGFloat = 11
    @State private var visibilityConsumer = UUID()
    @State private var selectionTask: Task<Void, Never>?

    private let visibleFraction = 0.01

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
                .onDisappear {
                    store.watchedAgentCoordinator.releaseVisibility(consumer: visibilityConsumer)
                    selectionTask?.cancel()
                }
        }
    }

    private var waitingContent: some View {
        VStack(spacing: 0) {
            waitingHeader
            waitingList
        }
        .background(Theme.card(for: colorScheme).opacity(viewModel.showsLoadingState ? 0 : 1))
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

    private var waitingList: some View {
        // Snapshot errors and prepare views before SwiftUI requests rows off-main.
        let coordinator = store.watchedAgentCoordinator
        let rows = coordinator.rows.map { row in
            let content = watchedAgentRow(row, hasError: coordinator.errors[row.id] != nil)
                .onScrollVisibilityChange(threshold: visibleFraction) { visible in
                    coordinator.setVisible(row.id, visible: visible, consumer: visibilityConsumer)
                }
                .onDisappear {
                    coordinator.setVisible(row.id, visible: false, consumer: visibilityConsumer)
                }
            return (id: row.id, content: content)
        }
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.id) { @Sendable row in
                    row.content
                }
            }
        }
        .frame(maxHeight: min(CGFloat(store.watchedAgentIds.count) * Layout.rowHeight, Layout.maximumListHeight))
        .accessibilityIdentifier("watched-agent-list")
    }

    private func watchedAgentRow(_ row: WatchedAgentRow, hasError: Bool) -> some View {
        Group {
            if onNavigateToAgent != nil, !row.isDeleted {
                Button {
                    selectionTask?.cancel()
                    selectionTask = Task {
                        guard let selected = await store.watchedAgentCoordinator.selectedAgent(row.id),
                              let workspace = selected.workspaceId, !Task.isCancelled else { return }
                        onNavigateToAgent?(selected.id, workspace, selected.agent.name)
                    }
                } label: { agentRow(row, hasError: hasError) }
                    .buttonStyle(IntentContentButtonStyle())
            } else {
                agentRow(row, hasError: hasError)
            }
        }
        .accessibilityIdentifier("watched-agent-" + row.id)
        .contextMenu {
            if !row.isDeleted { agentContextMenu(row.agent) }
            if hasError {
                Button("Retry Loading") { store.watchedAgentCoordinator.retry(row.id) }
            }
        }
    }

    private func agentRow(_ row: WatchedAgentRow, hasError: Bool) -> some View {
        HStack(spacing: Layout.agentRowSpacing) {
            agentAvatar(row)
            agentDescription(row, hasError: hasError)
            Spacer()
            if onNavigateToAgent != nil, !row.isDeleted {
                Image(.chevronRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: disclosureIconSide, height: disclosureIconSide)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.rowVerticalPadding)
        .contentShape(Rectangle())
    }

    private func agentAvatar(_ row: WatchedAgentRow) -> some View {
        ZStack(alignment: .topTrailing) {
            AgentAvatarView(
                agentId: row.id,
                size: Constants.Conversation.AgentWaiting.avatarSize,
                specialist: row.agent.specialist,
                isActive: row.agent.isActive && !row.isDeleted
            )
            agentStatusBadge(row)
        }
    }

    @ViewBuilder
    private func agentStatusBadge(_ row: WatchedAgentRow) -> some View {
        let agent = row.agent
        if row.isDeleted {
            statusBadge(Image(systemName: "minus.circle.fill"), color: .gray)
        } else if agent.isErrored {
            statusBadge(Image(.closeCircle), color: .red)
        } else if let attention = agent.pendingAttentionRequest {
            statusBadge(Image(attention.kind.iconName), color: attention.kind.color)
        } else if row.isCompleted || agent.status == "completed" {
            statusBadge(Image(.checkCircle), color: .green)
        } else if agent.isActive {
            activeStatusDot
        }
    }

    private func statusBadge(_ image: Image, color: Color) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(width: Layout.badgeFontSize, height: Layout.badgeFontSize)
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

    private func agentDescription(_ row: WatchedAgentRow, hasError: Bool) -> some View {
        let agent = row.agent
        return VStack(alignment: .leading, spacing: Layout.descriptionSpacing) {
            Text(agent.name)
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .lineLimit(1)
            if row.isDeleted || row.isCompleted {
                Text(row.statusText)
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            } else if hasError {
                Text("Couldn’t load agent. Tap to retry.")
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            } else if let attention = agent.pendingAttentionRequest {
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
                Text(row.statusText)
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
            Label("Stop Agent", image: "StopFill")
        }

        Button {
            Task { await viewModel.cancelWait() }
        } label: {
            Label("Cancel Wait", image: "Close")
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
