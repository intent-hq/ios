import SwiftUI

/// The iPad routes directly within a stable pane; no split-view or size-class
/// dependent push/re-push is needed to replace the selected conversation.
struct IPadWorkspaceDetailView: View {
    let session: BackendSession
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @State private var notePath = NavigationPath()
    @State private var firstAgent: WorkspaceFirstAgent?
    @State private var isSwiping = false

    var body: some View {
        NavigationStack(path: $notePath) {
            content
                .paneSwipe(isSwiping: $isSwiping, onBack: swipeBack, onForward: swipeForward)
                .onPreferenceChange(WorkspaceFirstAgentPreference.self) { firstAgent = $0 }
                .navigationDestination(for: NoteDestination.self) { destination in
                    note(destination, showsBackButton: true)
                }
                .modifier(IPadNavigationVisibility())
        }
        .onChange(of: coordinator.currentScreenDescription) {
            if !notePath.isEmpty { notePath = NavigationPath() }
        }
        .onChange(of: coordinator.conversationRequestId) {
            if !notePath.isEmpty { notePath = NavigationPath() }
        }
        .task { await DemoFixtures.reselectConversationIfRequested(coordinator: coordinator) }
    }

    @ViewBuilder private var content: some View {
        switch coordinator.currentScreen {
        case let .agentConversation(agentId, workspaceId, agentName):
            ConversationView(
                agentId: agentId,
                workspaceId: workspaceId,
                agentName: agentName,
                session: session,
                navigationRequestId: coordinator.conversationRequestId,
                onBack: coordinator.onBackToWorkspaceDetail
            )
            .id(agentId)
            .transition(pageTransition(isOverview: false))
        case let .noteDetail(noteId, workspaceId, noteTitle):
            note(NoteDestination(noteId: noteId, workspaceId: workspaceId, noteTitle: noteTitle), showsBackButton: false)
                .id(noteId)
                .transition(pageTransition(isOverview: false))
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        IntentIconButton(icon: .arrowLeft, label: "Back to workspace", action: coordinator.onBackFromNote)
                    }
                    .intentToolbarSurface()
                }
        case let .workspaceDetail(workspaceId):
            WorkspaceDetailView(workspaceId: workspaceId, session: session)
                .transition(pageTransition(isOverview: true))
        default:
            IPadShellStyle.panel(for: colorScheme)
        }
    }

    /// A swipe shifts the overview toward the leading edge and its pages toward the trailing edge
    /// while they fade; other navigation keeps the plain crossfade.
    private func pageTransition(isOverview: Bool) -> AnyTransition {
        guard isSwiping else { return .opacity }
        return .opacity.combined(with: .offset(x: isOverview ? -IPadShellView.pageParallax : IPadShellView.pageParallax))
    }

    private var canSwipe: Bool { coordinator.iPadNavigation.focusPresentation == .normal && notePath.isEmpty }

    private var swipeBack: (() -> Void)? {
        guard canSwipe else { return nil }
        switch coordinator.currentScreen {
        case .agentConversation: return coordinator.onBackToWorkspaceDetail
        case .noteDetail: return coordinator.onBackFromNote
        default: return nil
        }
    }

    private var swipeForward: (() -> Void)? {
        guard canSwipe, case let .workspaceDetail(workspaceId) = coordinator.currentScreen,
              let firstAgent, firstAgent.workspaceId == workspaceId else { return nil }
        return { coordinator.onSelectAgent(firstAgent.id, workspaceId: workspaceId, agentName: firstAgent.name) }
    }

    private func note(_ destination: NoteDestination, showsBackButton: Bool) -> some View {
        NoteDetailView(
            noteId: destination.noteId,
            workspaceId: destination.workspaceId,
            noteTitle: destination.noteTitle,
            session: session,
            showsBackButton: showsBackButton
        ) { noteId, workspaceId, title in
            notePath.append(NoteDestination(noteId: noteId, workspaceId: workspaceId, noteTitle: title))
        }
    }
}

/// The overview's top agent, which a forward swipe opens.
nonisolated struct WorkspaceFirstAgent: Equatable, Sendable {
    let id: String
    let workspaceId: String
    let name: String
}

struct WorkspaceFirstAgentPreference: PreferenceKey {
    nonisolated static var defaultValue: WorkspaceFirstAgent? { nil }

    nonisolated static func reduce(value: inout WorkspaceFirstAgent?, nextValue: () -> WorkspaceFirstAgent?) {
        value = value ?? nextValue()
    }
}
