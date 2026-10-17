import SwiftUI

struct IPadAssistantSidebar: View {
    let session: BackendSession
    let onCollapse: () -> Void
    let onSelectThread: (String) -> Void
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var scaledActionSize = Constants.WorkspaceList.swipeButtonSize
    @ScaledMetric(relativeTo: .body) private var actionIconSize = Constants.WorkspaceList.swipeButtonIconSize
    @State private var revealedTarget: WorkspaceSwipeTarget?
    @State private var pendingDeletion: AgentSession?
    @State private var showDeleteConfirmation = false

    private var store: AssistantStore { session.assistantStore }
    private var selectedID: String? { coordinator.assistantAgentId ?? store.threads.first?.id }
    private var actionSize: CGFloat { max(Constants.Accessibility.minimumTapTarget, scaledActionSize) }

    var body: some View {
        VStack(spacing: 0) {
            IPadSidebarHeader(onCollapse: onCollapse) {
                IPadSidebarTitle(title: "Assistant")
            } actions: {
                IntentIconButton(icon: .addIcon, label: "New conversation", showsBackground: false, action: createThread)
                    .disabled(store.isCreating || !store.hasLoaded)
                    .accessibilityIdentifier("assistant.sidebar.newConversation")
            }
            ScrollView {
                VStack(spacing: 0) {
                    if let error = store.errorMessage {
                        AssistantErrorBanner(error: error) { Task { await store.refresh() } }
                    }
                    if store.threads.isEmpty {
                        emptyState
                    } else {
                        threadRows
                    }
                }
                .padding(.horizontal, IPadSidebarStyle.inset)
                .padding(.bottom, IPadSidebarStyle.inset)
            }
            .refreshable { await store.refresh() }
        }
        .background(IPadSidebarStyle.background(for: colorScheme))
        .task { if !store.hasLoaded { await store.refresh() } }
        .onChange(of: selectedID) { _, _ in revealedTarget = nil }
        .alert("Delete Conversation?", isPresented: $showDeleteConfirmation, presenting: pendingDeletion) { thread in
            Button("Delete", role: .destructive) { deleteThread(thread.id) }
            Button("Cancel", role: .cancel) {}
        } message: { thread in
            Text("This will permanently delete “\(thread.name)” and its conversation history.")
        }
    }

    private var threadRows: some View {
        let rows = store.threads.indices.map { index in
            let thread = store.threads[index]
            let nextID = index + 1 < store.threads.count ? store.threads[index + 1].id : nil
            return (id: thread.id, content: threadRow(thread, isNextSelected: nextID != nil && nextID == selectedID))
        }
        return LazyVStack(spacing: 0) {
            ForEach(rows, id: \.id) { @Sendable row in row.content }
        }
    }

    private var emptyState: some View {
        AssistantStateContent(
            isLoading: store.isLoading || (!store.hasLoaded && store.errorMessage == nil),
            canCreateConversation: !store.isCreating && store.hasLoaded,
            onCreateConversation: createThread
        )
    }

    private func threadRow(_ thread: AgentSession, isNextSelected: Bool) -> some View {
        WorkspaceSwipeContainer(
            target: .assistant(thread.id),
            revealedTarget: $revealedTarget,
            actionCount: 1,
            actionWidth: actionSize,
            actionLeadingSpacing: Constants.WorkspaceList.swipeActionsLeadingSpacing,
            restingCornerRadius: IPadSidebarStyle.rowRadius,
            swipeBackground: Constants.WorkspaceList.controlSurface(for: colorScheme),
            isSwipeEnabled: !store.deletingThreadIDs.contains(thread.id)
        ) { progress in
            threadButton(thread, isNextSelected: isNextSelected, swipeProgress: progress)
        } actions: {
            Button(role: .destructive) { confirmDeletion(thread) } label: {
                Image(.delete)
                    .resizable()
                    .scaledToFit()
                    .frame(width: actionIconSize, height: actionIconSize)
                    .accessibilityHidden(true)
            }
            .buttonStyle(WorkspaceSwipeIconButtonStyle(size: actionSize))
            .disabled(store.deletingThreadIDs.contains(thread.id))
            .accessibilityLabel("Delete conversation")
            .accessibilityIdentifier("assistant.thread.delete.\(thread.id)")
        }
    }

    private func threadButton(_ thread: AgentSession, isNextSelected: Bool, swipeProgress: CGFloat) -> some View {
        let selected = selectedID == thread.id
        return Button {
            if revealedTarget != nil {
                revealedTarget = nil
            } else {
                onSelectThread(thread.id)
            }
        } label: {
            threadLabel(thread, swipeProgress: swipeProgress)
            .background(
                selected ? IPadSidebarStyle.selection(for: colorScheme) : .clear,
                in: .rect(cornerRadius: IPadSidebarStyle.rowRadius)
            )
            .overlay(alignment: .bottom) {
                if !selected, !isNextSelected {
                    Divider().padding(.horizontal, IPadSidebarStyle.rowInset)
                        .opacity(1 - Double(swipeProgress))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(IntentContentButtonStyle())
        .disabled(store.deletingThreadIDs.contains(thread.id))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("assistant.thread.\(thread.id)")
        .accessibilityAction(named: "Delete conversation") { confirmDeletion(thread) }
    }

    private func threadLabel(_ thread: AgentSession, swipeProgress: CGFloat) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Constants.WorkspaceRow.metadataSpacing))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Constants.WorkspaceRow.metadataSpacing))
        return layout {
            Text(thread.name)
                .interFont(Constants.Typography.bodySEmphasized)
                .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let date = ISO8601DateFormatter.lenientDate(from: thread.bestTimestamp) {
                Text(date.relativeFormatted)
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(Constants.WorkspaceList.secondaryText(for: colorScheme, contrast: contrast))
                    .fixedSize()
                    .opacity(1 - Double(swipeProgress))
            }
        }
        .padding(.horizontal, IPadSidebarStyle.rowInset)
        .padding(.vertical, IPadSidebarStyle.rowVerticalPadding)
        .frame(minHeight: IPadSidebarStyle.rowHeight)
    }

    private func confirmDeletion(_ thread: AgentSession) {
        revealedTarget = nil
        pendingDeletion = thread
        showDeleteConfirmation = true
    }

    private func deleteThread(_ id: String) {
        HapticManager.notification(.warning)
        Task {
            if await store.deleteThread(id), coordinator.assistantAgentId == id {
                coordinator.assistantAgentId = store.threads.first?.id
            }
        }
    }

    private func createThread() {
        revealedTarget = nil
        Task {
            if let id = await store.createThread() {
                onSelectThread(id)
            }
        }
    }
}
