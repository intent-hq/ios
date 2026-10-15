import SwiftUI

struct AssistantView: View {
    let session: BackendSession
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.conversationPresentation) private var presentation

    private var store: AssistantStore { session.assistantStore }

    private var selectedThread: AgentSession? {
        store.threads.first { $0.id == coordinator.assistantAgentId } ?? store.threads.first
    }

    private var usesWorkspaceDesign: Bool {
        #if os(iOS)
        presentation == .iPad || horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        NavigationStack {
            content
            .navigationTitle("Assistant")
            .toolbar {
                if !usesWorkspaceDesign { assistantToolbar }
            }
            .toolbar(usesWorkspaceDesign ? .hidden : .automatic, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                if usesWorkspaceDesign, selectedThread == nil {
                    VStack(spacing: 0) {
                        emptyHeader
                        errorBanner.conversationReadableColumn()
                    }
                } else {
                    errorBanner.conversationReadableColumn()
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

    private var emptyHeader: some View {
        AssistantConversationHeader(
            title: "Assistant",
            canCreateConversation: !store.isCreating && store.hasLoaded,
            onNewConversation: createThread
        ) {
            Menu {
                AssistantHistoryMenu(store: store, coordinator: coordinator)
            } label: {
                ToolbarOverflowLabel()
            }
            .accessibilityLabel("Assistant actions")
            .accessibilityIdentifier("assistant.actions")
        }
    }

    @ViewBuilder private var errorBanner: some View {
        if let error = store.errorMessage {
            if usesWorkspaceDesign {
                AssistantErrorBanner(error: error) { Task { await store.refresh() } }
            } else {
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

    @ToolbarContentBuilder private var assistantToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            newConversationButton
                .accessibilityIdentifier("assistant.newConversation")
        }
        .intentToolbarSurface()
        if selectedThread == nil {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    AssistantHistoryMenu(store: store, coordinator: coordinator)
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
        } else if usesWorkspaceDesign {
            AssistantStateContent(
                isLoading: store.isLoading || (!store.hasLoaded && store.errorMessage == nil),
                canCreateConversation: !store.isCreating && store.hasLoaded,
                onCreateConversation: createThread
            )
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
                if presentation == .iPad {
                    coordinator.onSelectAssistant(agentId: id)
                } else {
                    coordinator.assistantAgentId = id
                }
            }
        }
    }
}

struct AssistantHistoryMenu: View {
    let store: AssistantStore
    // Explicit input survives native toolbar hosting without environment inheritance (#745).
    let coordinator: AppCoordinator

    var body: some View {
        let threads = store.threads
        let selectedThreadId = coordinator.assistantAgentId ?? threads.first?.id
        let rows = threads.map { thread in
            (id: thread.id, content: threadButton(thread, isSelected: selectedThreadId == thread.id))
        }
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
            // SwiftUI may request menu rows off-main; return only prepared values.
            ForEach(rows, id: \.id) { @Sendable row in
                row.content
            }
        } label: {
            Label {
                Text("Assistant conversations").interFont(Constants.Typography.bodyS)
            } icon: {
                Image(.messageList)
            }
        }
        .accessibilityIdentifier("assistant.conversations")
    }

    private func threadButton(_ thread: AgentSession, isSelected: Bool) -> some View {
        Button {
            coordinator.assistantAgentId = thread.id
        } label: {
            if isSelected {
                Label(thread.name, image: "Check")
            } else {
                Text(thread.name)
            }
        }
    }
}
