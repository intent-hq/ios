import SwiftUI

struct AssistantHistorySheet: View {
    let store: AssistantStore
    let coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var pendingDeletion: AgentSession?
    @State private var showsDeleteConfirmation = false

    private var selectedID: String? { coordinator.assistantAgentId ?? store.threads.first?.id }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = store.errorMessage {
                    AssistantErrorBanner(error: error) { Task { await store.refresh() } }
                }
                if store.threads.isEmpty {
                    AssistantStateContent(
                        isLoading: store.isLoading || (!store.hasLoaded && store.errorMessage == nil),
                        canCreateConversation: !store.isCreating && store.hasLoaded,
                        onCreateConversation: createThread
                    )
                } else {
                    threadList
                }
            }
            .background(Constants.Pairing.background(for: colorScheme))
            .navigationTitle("Conversations")
            .toolbarTitleDisplayMode(.inline)
            .toolbar { historyToolbar }
            .alert("Delete Conversation?", isPresented: $showsDeleteConfirmation, presenting: pendingDeletion) { thread in
                Button("Delete", role: .destructive) { deleteThread(thread.id) }
                Button("Cancel", role: .cancel) {}
            } message: { thread in
                Text("This will permanently delete “\(thread.name)” and its conversation history.")
            }
        }
        .presentationBackground(Constants.Pairing.background(for: colorScheme))
    }

    @ToolbarContentBuilder private var historyToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            IntentIconButton(icon: .close, label: "Close") { dismiss() }
                .accessibilityIdentifier("assistant.history.close")
        }
        .intentToolbarSurface()
        ToolbarItem(placement: .primaryAction) {
            IntentIconButton(icon: .addIcon, label: "New conversation", action: createThread)
                .disabled(store.isCreating || !store.hasLoaded)
                .accessibilityIdentifier("assistant.history.newConversation")
        }
        .intentToolbarSurface()
    }

    private var threadList: some View {
        let rows = store.threads.map { thread in
            (id: thread.id, content: threadRow(thread))
        }
        return List {
            ForEach(rows, id: \.id) { @Sendable row in row.content }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await store.refresh() }
        .accessibilityIdentifier("assistant.history.list")
    }

    private func threadRow(_ thread: AgentSession) -> some View {
        let selected = selectedID == thread.id
        let timestamp = ISO8601DateFormatter.lenientDate(from: thread.bestTimestamp)?.relativeFormatted ?? ""
        return Button { selectThread(thread.id) } label: {
            threadLabel(thread.name, timestamp: timestamp, selected: selected)
        }
        .buttonStyle(IntentContentButtonStyle())
        .disabled(store.deletingThreadIDs.contains(thread.id))
        .accessibilityLabel(thread.name)
        .accessibilityValue(timestamp)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("assistant.history.thread.\(thread.id)")
        .listRowBackground(Constants.Pairing.background(for: colorScheme))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { confirmDeletion(thread) } label: {
                Label { Text("Delete") } icon: { Image(.delete) }
            }
            .tint(Theme.destructive(for: colorScheme))
            .disabled(store.deletingThreadIDs.contains(thread.id))
            .accessibilityIdentifier("assistant.history.delete.\(thread.id)")
        }
        .accessibilityAction(named: "Delete conversation") { confirmDeletion(thread) }
    }

    private func threadLabel(_ name: String, timestamp: String, selected: Bool) -> some View {
        HStack(spacing: ConnectionSwitcherStyle.rowInset) {
            VStack(alignment: .leading, spacing: ConnectionSwitcherStyle.rowTextSpacing) {
                Text(name)
                    .interFont(Constants.Typography.bodySEmphasized)
                    .fixedSize(horizontal: false, vertical: true)
                Text(timestamp)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Constants.Connections.sectionForeground(for: colorScheme, contrast: contrast))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if selected {
                Image(.check).accessibilityHidden(true)
            }
        }
        .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
        .frame(minHeight: Constants.Accessibility.minimumTapTarget)
        .contentShape(.rect)
    }

    private func confirmDeletion(_ thread: AgentSession) {
        pendingDeletion = thread
        showsDeleteConfirmation = true
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
        Task {
            if let id = await store.createThread() { selectThread(id) }
        }
    }

    private func selectThread(_ id: String) {
        coordinator.assistantAgentId = id
        dismiss()
    }
}
