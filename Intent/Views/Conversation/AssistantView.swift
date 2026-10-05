import SwiftUI

struct AssistantView: View {
    let session: BackendSession
    @Environment(AppCoordinator.self) private var coordinator

    private var store: AssistantStore { session.assistantStore }

    private var selectedThread: AgentSession? {
        store.threads.first { $0.id == coordinator.assistantAgentId } ?? store.threads.first
    }

    var body: some View {
        NavigationStack {
            content
            .navigationTitle("Assistant")
            .toolbar { assistantToolbar }
            .safeAreaInset(edge: .top) {
                if let error = store.errorMessage {
                    VStack {
                        Text(error).font(.callout)
                        Button("Retry") { Task { await store.refresh() } }
                            .buttonStyle(IntentButtonStyle(variant: .secondary))
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
                }
            }
        }
        .accessibilityAction(.escape) {
            coordinator.selectedSection = .workspaces
        }
        .task {
            await store.refresh()
            if coordinator.assistantAgentId == nil {
                coordinator.assistantAgentId = store.threads.first?.id
            }
        }
        .onChange(of: coordinator.assistantAgentId) { _, agentId in
            if let agentId, !store.threads.contains(where: { $0.id == agentId }) {
                Task { await store.refresh() }
            }
        }
    }

    @ToolbarContentBuilder private var assistantToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            newConversationButton
                .accessibilityIdentifier("assistant.newConversation")
        }
        .intentToolbarSurface()
        if selectedThread == nil {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    AssistantHistoryMenu(store: store)
                } label: {
                    ToolbarOverflowLabel()
                }
                .buttonStyle(IntentContentButtonStyle())
                .accessibilityLabel("Assistant actions")
                .accessibilityIdentifier("assistant.actions")
            }
            .intentToolbarSurface()
        }
    }

    @ViewBuilder private var content: some View {
        if let thread = selectedThread {
            ConversationView(
                agentId: thread.id,
                workspaceId: Workspace.chiefWorkspaceId,
                agentName: thread.name,
                session: session,
                assistantStore: store
            ) {
                store.removeThread(thread.id)
                coordinator.assistantAgentId = store.threads.first?.id
            }
            .id(thread.id)
        } else if store.isLoading || (!store.hasLoaded && store.errorMessage == nil) {
            ProgressView("Loading Assistant…")
        } else {
            ContentUnavailableView {
                Label("Assistant", image: "IntentDandelion")
            } description: {
                Text("Plan your work and get help across all your workspaces.")
            } actions: {
                Button("Start a Conversation", action: createThread)
                    .buttonStyle(IntentButtonStyle())
                    .disabled(store.isCreating || !store.hasLoaded)
            }
        }
    }

    private var newConversationButton: some View {
        IntentIconButton(icon: .displayEdit, label: "New Conversation", action: createThread)
            .disabled(store.isCreating || !store.hasLoaded)
    }

    private func createThread() {
        Task {
            if let id = await store.createThread() {
                coordinator.assistantAgentId = id
            }
        }
    }
}

struct AssistantHistoryMenu: View {
    let store: AssistantStore
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        Menu {
            Button {
                Task {
                    if let id = await store.createThread() {
                        coordinator.assistantAgentId = id
                    }
                }
            } label: {
                Label("New Conversation", image: "DisplayEdit")
            }
            .disabled(store.isCreating || !store.hasLoaded)
            .accessibilityIdentifier("assistant.history.newConversation")
            Divider()
            ForEach(store.threads) { thread in
                Button {
                    coordinator.assistantAgentId = thread.id
                } label: {
                    if (coordinator.assistantAgentId ?? store.threads.first?.id) == thread.id {
                        Label(thread.name, image: "Check")
                    } else {
                        Text(thread.name)
                    }
                }
            }
        } label: {
            Label("Assistant conversations", systemImage: "bubble.left.and.bubble.right")
        }
        .accessibilityIdentifier("assistant.conversations")
    }
}
