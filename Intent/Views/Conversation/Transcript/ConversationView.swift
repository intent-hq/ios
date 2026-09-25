import SwiftUI
import UIKit

struct ConversationView: View {
    @State private var viewModel: ConversationViewModel
    var onAgentUnavailable: (() -> Void)?
    var assistantStore: AssistantStore?

    init(
        agentId: String,
        workspaceId: String,
        agentName: String,
        session: BackendSession,
        assistantStore: AssistantStore? = nil,
        onAgentUnavailable: (() -> Void)? = nil
    ) {
        self.onAgentUnavailable = onAgentUnavailable
        self.assistantStore = assistantStore
        _viewModel = State(initialValue: ConversationViewModel(
            agentId: agentId,
            workspaceId: workspaceId,
            agentName: agentName,
            connection: session.connection,
            uploadService: session.attachmentUploadService,
            optionsStore: session.creationOptionsStore
        ))
    }

    var body: some View {
        ConversationViewContent(
            viewModel: viewModel,
            onAgentUnavailable: onAgentUnavailable,
            assistantStore: assistantStore
        )
    }
}

private struct ConversationViewContent: View {
    let viewModel: ConversationViewModel
    var onAgentUnavailable: (() -> Void)?
    var assistantStore: AssistantStore?
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(BackendSession.self) private var session
    @Environment(\.colorScheme) var colorScheme
    @State private var showModelPicker = false
    @State private var showDeleteConfirmation = false
    /// True while a deletion initiated from this view's own Delete button is in
    /// flight — the `agent:deleted` fallback must not double-navigate on top of
    /// the explicit dismiss().
    @State private var selfInitiatedDelete = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var presentedNote: NoteSheetInfo?
    @State private var childAgent: AgentDestination?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    // `body` is decomposed into layered `some View` properties
    // (intent-hq/monorepo#2352): the Xcode Cloud Release build could not
    // type-check the former single-expression modifier chain in reasonable
    // time (Debug builds passed). Each layer is an opaque sub-expression the
    // type checker solves independently; modifier ORDER is unchanged — the
    // layers chain bottom-up: column → chrome → presentation → lifecycle.
    var body: some View {
        conversationLifecycle
    }

    /// Outermost layer: navigation destination + load/lifecycle handlers.
    private var conversationLifecycle: some View {
        conversationPresentation
            .navigationDestination(item: $childAgent) { dest in
                ConversationView(
                    agentId: dest.agentId,
                    workspaceId: dest.workspaceId,
                    agentName: dest.agentName,
                    session: session
                )
                .id(dest.agentId)
            }
            .task {
                await viewModel.load()
                handleAgentNotFoundIfNeeded()
                await DemoFixtures.streamAssistantPromptsIfRequested(in: viewModel.store)
            }
            .task(id: viewModel.modelCatalogKey) {
                await viewModel.loadModelCatalogIfNeeded()
            }
            .onChange(of: viewModel.agentNotFound) { _, notFound in
                if notFound {
                    handleAgentNotFoundIfNeeded()
                }
            }
            .onAppear {
                if let connectionId = session.backendID?.connectionID {
                    NotificationManager.shared.conversationOpened(
                        agentId: viewModel.agentId,
                        connectionId: connectionId
                    )
                }
                // Entry itself never marks seen (the divider anchor must survive
                // until the user leaves or the turn finishes).
                viewModel.conversationAppeared()
            }
            .onDisappear {
                if let connectionId = session.backendID?.connectionID {
                    NotificationManager.shared.conversationClosed(
                        agentId: viewModel.agentId,
                        connectionId: connectionId
                    )
                }
                Task { await viewModel.teardownLiveStores() }
                // Stop-looking boundary — fires markSeen immediately.
                viewModel.conversationDisappeared()
            }
            .onChange(of: scenePhase) { _, phase in
                viewModel.scenePhaseChanged(isActive: phase == .active)
            }
    }

    /// Sheets, confirmation dialog, and alerts.
    private var conversationPresentation: some View {
        conversationChrome
            .sheet(isPresented: $showModelPicker) {
                ModelPickerView(viewModel: viewModel)
            }
            .sheet(item: $presentedNote) { noteInfo in
                noteSheet(for: noteInfo)
            }
            .confirmationDialog(
                "Delete Agent?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive, action: deleteAgent)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete this agent and its conversation history.")
            }
            .alert("Rename Agent", isPresented: $showRenameAlert) {
                TextField("Agent name", text: $renameText)
                Button("Rename", action: renameAgent)
                Button("Cancel", role: .cancel) {}
            }
            // Non-destructive dismiss-failure surface (intent-hq/monorepo#1800):
            // nothing was dismissed — the wizard re-pends via the store's marker
            // rollback; this alert just makes the failure explicit. `presenting:`
            // hands the closures a captured non-optional detail so the message
            // doesn't degrade mid-dismissal (same shape as ConnectionsView).
            .alert(
                "Couldn't Dismiss Questions",
                isPresented: dismissQuestionsErrorPresented,
                presenting: viewModel.dismissQuestionsError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { detail in
                Text("The questions were not dismissed and are still pending. " + detail)
            }
            // Image placement failure (monorepo#3338): the message was NOT
            // sent — the draft text and captured images are restored to the
            // composer; this alert makes the failure explicit (same shape as
            // the dismiss-failure alert above).
            .alert(
                "Couldn't Send Images",
                isPresented: imagePlacementErrorPresented,
                presenting: viewModel.imagePlacementError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { detail in
                Text("The message was not sent. " + detail)
            }
            // File placement failure: the message was NOT sent — the draft
            // text is restored and the pending files stay attached (same
            // fail-closed shape as the image alert above).
            .alert(
                "Couldn't Send Files",
                isPresented: filePlacementErrorPresented,
                presenting: viewModel.filePlacementError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { detail in
                Text("The message was not sent. " + detail)
            }
    }

    /// Navigation bar title and toolbar; the bar background is the system default.
    private var conversationChrome: some View {
        conversationColumn
            .navigationTitle(viewModel.agentName)
            .toolbarTitleDisplayMode(.inline)
            .workspaceNavigationSubtitle(
                title: viewModel.agentName,
                workspaceId: viewModel.workspaceId
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    agentMenu
                }
            }
    }

    /// Innermost layer: the column itself plus geometry/animation modifiers.
    private var conversationColumn: some View {
        ConversationColumnView(
            viewModel: viewModel,
            onNavigateToNote: navigateToNote,
            onNavigateToAgent: navigateToAgent
        )
    }

    /// Presented-or-not binding for the dismiss-failure alert, hoisted out of
    /// the `body` expression so the type checker doesn't solve the `Binding`
    /// construction inline.
    private var dismissQuestionsErrorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.dismissQuestionsError != nil },
            set: { if !$0 { viewModel.dismissQuestionsError = nil } }
        )
    }

    /// Presented-or-not binding for the image-placement-failure alert, hoisted
    /// like `dismissQuestionsErrorPresented`.
    private var imagePlacementErrorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.imagePlacementError != nil },
            set: { if !$0 { viewModel.imagePlacementError = nil } }
        )
    }

    /// Presented-or-not binding for the file-placement-failure alert, hoisted
    /// like `imagePlacementErrorPresented`.
    private var filePlacementErrorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.filePlacementError != nil },
            set: { if !$0 { viewModel.filePlacementError = nil } }
        )
    }

    /// Ellipsis toolbar menu (model info, rename, delete).
    private var agentMenu: some View {
        Menu {
            if let assistantStore {
                AssistantHistoryMenu(store: assistantStore)
                Divider()
            }
            if let displayName = viewModel.currentModelDisplayName {
                Text("Model: \(displayName)")
            }
            if viewModel.filteredMessages.isEmpty {
                Button {
                    showModelPicker = true
                } label: {
                    Label("Change Model", systemImage: "cpu")
                }
            }
            Button {
                renameText = viewModel.agentName
                showRenameAlert = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete Agent", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(Theme.foreground(for: colorScheme))
        }
        .accessibilityLabel(assistantStore == nil ? "Agent actions" : "Assistant actions")
        .accessibilityIdentifier(assistantStore == nil ? "agent.actions" : "assistant.actions")
    }

    /// Note detail sheet content for a tapped note reference.
    private func noteSheet(for noteInfo: NoteSheetInfo) -> some View {
        ConversationNoteSheet(noteInfo: noteInfo, session: session) {
            presentedNote = nil
        }
    }

    /// Delete-confirmation action: deletes the agent then dismisses this view.
    private func deleteAgent() {
        HapticManager.notification(.warning)
        selfInitiatedDelete = true
        Task {
            do {
                _ = try await session.connection.request(
                    "agent.delete",
                    params: [
                        "agentId": viewModel.agentId,
                        "workspaceId": viewModel.workspaceId
                    ]
                )
                if let onAgentUnavailable {
                    onAgentUnavailable()
                } else {
                    dismiss()
                }
            } catch {
                selfInitiatedDelete = false
                AppLog.userInterface.error("[ConversationView] Failed to delete agent: \(error)")
            }
        }
    }

    /// Rename-alert action: applies the trimmed name if non-empty.
    private func renameAgent() {
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        Task {
            do {
                try await viewModel.renameAgent(newName)
            } catch {
                AppLog.userInterface.error("[ConversationView] Failed to rename agent: \(error)")
            }
        }
    }

    /// Coordinator-driven fallback when the agent no longer exists (not-found at
    /// load or deleted while open): navigate back to the workspace's agent list.
    /// Skipped for a self-initiated delete (the Delete button already dismisses).
    private func handleAgentNotFoundIfNeeded() {
        guard viewModel.agentNotFound, !selfInitiatedDelete else { return }
        if let onAgentUnavailable {
            onAgentUnavailable()
            return
        }
        coordinator.handleMissingAgent(agentId: viewModel.agentId, workspaceId: viewModel.workspaceId)
    }

    private func navigateToNote(noteId: String, workspaceId: String, title: String) {
        presentedNote = NoteSheetInfo(
            noteId: noteId,
            workspaceId: workspaceId,
            noteTitle: title
        )
    }

    private func navigateToAgent(agentId: String, workspaceId: String, name: String) {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        childAgent = AgentDestination(
            agentId: agentId,
            workspaceId: workspaceId,
            agentName: name
        )
    }
}

/// Note sheet opened from a transcript note reference. Note-to-note links that
/// target the hidden global Assistant workspace push inside the sheet: that
/// workspace has no place in the Workspaces tab, so the coordinator route would
/// replace the user's open workspace screen with it. Other links keep the
/// coordinator route.
private struct ConversationNoteSheet: View {
    let noteInfo: NoteSheetInfo
    let session: BackendSession
    let onDone: () -> Void
    @Environment(AppCoordinator.self) private var coordinator
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            noteDetail(noteId: noteInfo.noteId, workspaceId: noteInfo.workspaceId, noteTitle: noteInfo.noteTitle)
                .navigationDestination(for: NoteDestination.self) { destination in
                    noteDetail(
                        noteId: destination.noteId,
                        workspaceId: destination.workspaceId,
                        noteTitle: destination.noteTitle
                    )
                }
        }
    }

    private func noteDetail(noteId: String, workspaceId: String, noteTitle: String) -> some View {
        NoteDetailView(
            noteId: noteId,
            workspaceId: workspaceId,
            noteTitle: noteTitle,
            session: session,
            onNavigateToNote: navigate
        )
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done", action: onDone)
            }
        }
    }

    private func navigate(noteId: String, workspaceId: String, noteTitle: String) {
        if workspaceId == Workspace.chiefWorkspaceId {
            path.append(NoteDestination(noteId: noteId, workspaceId: workspaceId, noteTitle: noteTitle))
        } else {
            coordinator.onSelectNote(noteId, workspaceId: workspaceId, noteTitle: noteTitle)
        }
    }
}
