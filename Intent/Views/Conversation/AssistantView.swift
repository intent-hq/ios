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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    conversationMenu
                }
            }
            .safeAreaInset(edge: .top) {
                if let error = store.errorMessage {
                    VStack {
                        Text(error).font(.callout)
                        Button("Retry") { Task { await store.refresh() } }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
                }
            }
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

    @ViewBuilder private var content: some View {
        if let thread = selectedThread {
            ConversationView(
                agentId: thread.id,
                workspaceId: Workspace.chiefWorkspaceId,
                agentName: thread.name,
                session: session
            ) {
                store.removeThread(thread.id)
                coordinator.assistantAgentId = store.threads.first?.id
            }
            .id(thread.id)
        } else if store.isLoading || (!store.hasLoaded && store.errorMessage == nil) {
            ProgressView("Loading Assistant…")
        } else {
            ContentUnavailableView {
                Label("Assistant", systemImage: "sparkles")
            } description: {
                Text("Plan your work and get help across all your workspaces.")
            } actions: {
                Button("Start a Conversation", action: createThread)
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isCreating || !store.hasLoaded)
            }
        }
    }

    private var conversationMenu: some View {
        Menu {
            ForEach(store.threads) { thread in
                Button {
                    coordinator.assistantAgentId = thread.id
                } label: {
                    if selectedThread?.id == thread.id {
                        Label(thread.name, systemImage: "checkmark")
                    } else {
                        Text(thread.name)
                    }
                }
            }
            Divider()
            Button("New Conversation", systemImage: "square.and.pencil", action: createThread)
                .disabled(store.isCreating || !store.hasLoaded)
        } label: {
            Label("Assistant conversations", systemImage: "bubble.left.and.bubble.right")
        }
        .accessibilityIdentifier("assistant.conversations")
    }

    private func createThread() {
        Task {
            if let id = await store.createThread() {
                coordinator.assistantAgentId = id
            }
        }
    }
}
