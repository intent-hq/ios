import SwiftUI
import UIKit

struct ConversationView: View {
    @State private var viewModel: ConversationViewModel
    @State private var proposals: ProposalActionStore
    let navigationRequestId: Int
    var onBack: (() -> Void)?
    var onAgentUnavailable: (() -> Void)?
    var assistantStore: AssistantStore?
    var onShowAssistantHistory: (() -> Void)?

    init(
        agentId: String,
        workspaceId: String,
        agentName: String,
        session: BackendSession,
        assistantStore: AssistantStore? = nil,
        onShowAssistantHistory: (() -> Void)? = nil,
        navigationRequestId: Int = 0,
        onBack: (() -> Void)? = nil,
        onAgentUnavailable: (() -> Void)? = nil
    ) {
        self.navigationRequestId = navigationRequestId
        self.onBack = onBack
        self.onAgentUnavailable = onAgentUnavailable
        self.assistantStore = assistantStore
        self.onShowAssistantHistory = onShowAssistantHistory
        _proposals = State(initialValue: ProposalActionStore(connection: session.connection, agentId: agentId, workspaceId: workspaceId, details: session.agentDetails, workspaceStore: session.workspaceStore))
        _viewModel = State(initialValue: ConversationViewModel(
            agentId: agentId,
            workspaceId: workspaceId,
            agentName: agentName,
            connection: session.connection,
            uploadService: session.attachmentUploadService,
            optionsStore: session.creationOptionsStore,
            agentDetails: session.agentDetails,
            conversations: session.conversations,
            hooks: session.hooksStore,
            monitors: session.prMonitorsStore,
            scriptMonitors: session.scriptMonitorsStore,
            backendID: session.backendID
        ))
    }

    var body: some View {
        ConversationViewContent(
            viewModel: viewModel,
            navigationRequestId: navigationRequestId,
            onBack: onBack,
            onAgentUnavailable: onAgentUnavailable,
            assistantStore: assistantStore,
            onShowAssistantHistory: onShowAssistantHistory
        )
        .environment(proposals)
        .task(id: viewModel.store.sessionMetadataGeneration) {
            await proposals.loadIfPresent(in: viewModel.store.messages)
        }
    }
}

private struct ConversationViewContent: View {
    let viewModel: ConversationViewModel
    let navigationRequestId: Int
    var onBack: (() -> Void)?
    var onAgentUnavailable: (() -> Void)?
    var assistantStore: AssistantStore?
    var onShowAssistantHistory: (() -> Void)?
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(BackendSession.self) private var session
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.conversationPresentation) private var presentation
    @Environment(\.isIPadPaneVisible) private var isIPadPaneVisible
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar
    @State private var isInNavigation = false
    @State private var hasVisibleConversation = false
    /// Sheets, alerts and the demo cover, plus a Delete confirmed here.
    @State private var agentPresentation = AgentConversationPresentation()
    @State private var childAgent: AgentDestination?
    @State private var answeringWorkspaceQuestions = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    // Layered opaque expressions keep Release type-checking tractable (intent-hq/monorepo#2352).
    // Preserve modifier order: column → chrome → presentation → lifecycle.
    var body: some View {
        conversationLifecycle
    }

    /// Outermost layer: navigation destination + load/lifecycle handlers.
    private var conversationLifecycle: some View {
        conversationPresentation
            .navigationDestination(isPresented: $agentPresentation.presenting(.demoCover)) {
                Button("Return to conversation") { agentPresentation.dismiss(.demoCover) }
                    .buttonStyle(IntentButtonStyle(variant: .secondary))
                    .accessibilityIdentifier("demo.conversation.return")
                    .navigationTitle("Conversation cover")
                    .intentNavigationBackButton()
            }
            .navigationDestination(item: $childAgent) { dest in
                ConversationView(
                    agentId: dest.agentId,
                    workspaceId: dest.workspaceId,
                    agentName: dest.agentName,
                    session: session
                )
                .id(dest.agentId)
            }
            .onChange(of: navigationRequestId) { childAgent = nil }
            .task {
                await viewModel.load()
                handleAgentNotFoundIfNeeded()
                #if DEBUG
                await DemoFixtures.streamAssistantPromptsIfRequested(in: viewModel.store)
                #endif
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
                isInNavigation = true
                updateConversationVisibility(isPaneVisible)
            }
            .onChange(of: isPaneVisible) { _, visible in
                if isInNavigation { updateConversationVisibility(visible) }
            }
            .onDisappear {
                isInNavigation = false
                updateConversationVisibility(false, retainingLiveStores: false)
            }
            .onChange(of: scenePhase) { _, phase in
                viewModel.scenePhaseChanged(isActive: phase == .active && hasVisibleConversation)
            }
    }

    /// Sheets and alerts; the delete confirmation is anchored to its menu.
    private var conversationPresentation: some View {
        conversationChrome
            .sheet(isPresented: $agentPresentation.presenting(.modelPicker)) {
                ModelPickerView(viewModel: viewModel)
                    .coversConversationComposers()
            }
            .sheet(item: $agentPresentation.presentedNote) { noteInfo in
                noteSheet(for: noteInfo).coversConversationComposers()
            }
            .alert("Rename Agent", isPresented: $agentPresentation.presentingRename) {
                TextField("Agent name", text: $agentPresentation.renameDraft)
                Button("Rename", action: renameAgent)
                    .disabledWhileReadOnly()
                Button("Cancel", role: .cancel) {}
            }
            // Keep the failure detail stable while the wizard restores its pending marker
            // (intent-hq/monorepo#1800).
            .alert(
                "Couldn't Dismiss Questions",
                isPresented: dismissQuestionsErrorPresented,
                presenting: viewModel.dismissQuestionsError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { detail in
                Text("The questions were not dismissed and are still pending. " + detail)
            }
            // Failed image placement restores the draft and images (monorepo#3338).
            .alert(
                "Couldn't Send Images",
                isPresented: imagePlacementErrorPresented,
                presenting: viewModel.imagePlacementError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { detail in
                Text("The message was not sent. " + detail)
            }
            // Failed file placement restores the draft and retains pending attachments.
            .alert(
                "Couldn't Send Files",
                isPresented: filePlacementErrorPresented,
                presenting: viewModel.filePlacementError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { detail in
                Text("The message was not sent. " + detail)
            }
            .attachmentImportAlert(viewModel.attachmentPipeline)
    }
}

private extension ConversationViewContent {
    private var isPaneVisible: Bool {
        presentation != .iPad || isIPadPaneVisible
    }

    private func updateConversationVisibility(_ visible: Bool, retainingLiveStores: Bool = true) {
        guard visible != hasVisibleConversation else {
            if !retainingLiveStores { viewModel.teardownLiveStores() }
            return
        }
        hasVisibleConversation = visible
        if visible {
            if let connectionId = session.backendID?.connectionID {
                NotificationManager.shared.conversationOpened(agentId: viewModel.agentId, connectionId: connectionId)
            }
            // Entry never marks seen: preserve the unread divider until leaving or finishing.
            viewModel.conversationAppeared()
        } else {
            if let connectionId = session.backendID?.connectionID {
                NotificationManager.shared.conversationClosed(agentId: viewModel.agentId, connectionId: connectionId)
            }
            if retainingLiveStores {
                viewModel.conversationCovered()
            } else {
                viewModel.conversationDisappeared()
            }
        }
        viewModel.scenePhaseChanged(isActive: visible && scenePhase == .active)
    }

    private var isNamedBySidebar: Bool { assistantStore == nil && WorkspaceSidebarContent.namesAgent(viewModel.agentId, coordinator: coordinator) }

    private var usesVerticalNavigation: Bool {
        usesVerticalBar && assistantStore == nil
    }

    private var usesWorkspaceDesign: Bool {
        #if os(iOS)
        presentation == .iPad || horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    private var usesPhoneQuestionPresentation: Bool {
        usesWorkspaceDesign && presentation != .iPad
    }

    /// Keep the column's identity (including its scroll state) across width changes.
    private var conversationChrome: some View {
        legacyConversationChrome
            .conversationReadableColumn()
            .navigationBarBackButtonHidden(assistantStore == nil)
            .toolbarBackground(usesVerticalNavigation || viewModel.showsLoadingState ? .hidden : .automatic, for: .navigationBar)
            .nativeNavigationBackGesture(isEnabled: !usesPhoneQuestionPresentation || !answeringWorkspaceQuestions)
            #if os(iOS)
            // In the Duo shell the rail replaces the vertical toolbar, so no bar sits over the transcript top.
            .toolbar(usesWorkspaceDesign && (!usesVerticalNavigation || presentation == .iPad) ? .hidden : .automatic, for: .navigationBar)
            .toolbar(usesWorkspaceDesign && assistantStore == nil ? .hidden : .automatic, for: .tabBar)
            .modifier(ConversationFocusHeaderInset(isEnabled: usesWorkspaceDesign, floats: isNamedBySidebar && !usesVerticalNavigation) { usesMiniHeader in
                if usesVerticalNavigation, presentation != .iPad {
                    WorkspaceVerticalConversationHeader(title: viewModel.agentName, workspaceId: viewModel.workspaceId)
                } else {
                    WorkspaceConversationHeader(
                        title: viewModel.agentName,
                        showsBackground: !viewModel.showsLoadingState && (!isNamedBySidebar || usesMiniHeader),
                        bottomPadding: usesMiniHeader ? Constants.Conversation.Design.IPad.miniHeaderBottomInset : nil,
                        showsContextualActions: !usesVerticalNavigation,
                        showsTitle: !isNamedBySidebar,
                        assistantStore: assistantStore,
                        onBack: navigateBack
                    ) { agentMenu }
                    .animation(.easeInOut(duration: Constants.Conversation.Column.Loading.fadeDuration), value: viewModel.showsLoadingState)
                }
            })
            .modifier(WorkspaceQuestionPresentation(
                viewModel: viewModel,
                isPresented: $answeringWorkspaceQuestions,
                isEnabled: usesPhoneQuestionPresentation
            ))
            #endif
            .background {
                ConversationBackground(isLoading: viewModel.showsLoadingState, usesWorkspaceDesign: usesWorkspaceDesign)
            }
    }

    private var legacyConversationChrome: some View {
        conversationColumn
            .navigationTitle(usesVerticalNavigation ? "" : viewModel.agentName)
            .toolbarTitleDisplayMode(.inline)
            .workspaceNavigationSubtitle(
                title: viewModel.agentName,
                workspaceId: usesVerticalNavigation ? "" : viewModel.workspaceId
            )
            .toolbar {
                if usesVerticalNavigation, presentation != .iPad {
                    WorkspaceVerticalNavigationToolbar(
                        isEnabled: true,
                        backIdentifier: "conversation.back",
                        onBack: navigateBack
                    ) { agentMenu }
                } else if !usesWorkspaceDesign {
                    if assistantStore == nil {
                        ToolbarItem(placement: .topBarLeading) {
                            IntentIconButton(icon: .arrowLeft, label: "Back", action: navigateBack)
                        }
                        .intentToolbarSurface()
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        agentMenu
                    }
                    .intentToolbarSurface()
                }
            }
    }

    /// Innermost layer: the column itself plus geometry/animation modifiers.
    private var conversationColumn: some View {
        ConversationColumnView(
            viewModel: viewModel,
            onNavigateToNote: navigateToNote,
            onNavigateToAgent: navigateToAgent,
            usesWorkspaceDesign: usesWorkspaceDesign,
            answeringWorkspaceQuestions: $answeringWorkspaceQuestions
        ) { agentPresentation.present(.demoCover) }
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

    private var imagePlacementErrorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.imagePlacementError != nil },
            set: { if !$0 { viewModel.imagePlacementError = nil } }
        )
    }

    private var filePlacementErrorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.filePlacementError != nil },
            set: { if !$0 { viewModel.filePlacementError = nil } }
        )
    }

    /// The native menu owns its container shape and dismissal on every device.
    private var agentMenu: some View {
        WorkspaceResourceActions(workspaceId: viewModel.workspaceId, isEnabled: assistantStore == nil) {
            nativeAgentMenu
            .confirmationDialog(
                "Delete Agent?",
                isPresented: $agentPresentation.presenting(.deleteConfirmation),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive, action: deleteAgent)
                    .disabledWhileReadOnly()
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete this agent and its conversation history.")
            }
        }
    }

    private enum AgentAction {
        case changeModel
        case delete
        case rename
    }

    private func handleAgentAction(_ action: AgentAction) {
        switch action {
        case .changeModel:
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            agentPresentation.present(.modelPicker)
        case .delete:
            agentPresentation.present(.deleteConfirmation)
        case .rename:
            agentPresentation.present(.rename(draft: viewModel.agentName))
        }
    }

    /// Ellipsis toolbar menu (model selection, rename, delete).
    private var nativeAgentMenu: some View {
        Menu {
            if let assistantStore {
                AssistantHistoryMenu(store: assistantStore, coordinator: coordinator, onOpenHistory: onShowAssistantHistory)
                Divider()
            }
            Button { handleAgentAction(.changeModel) } label: {
                Label { Text(viewModel.currentModelDisplayName ?? "Select Model") } icon: { Image(.settings2) }
            }
            .disabledWhileReadOnly()
            .accessibilityIdentifier("conversation.actions.model")
            .accessibilityHint("Change model")
            Button { handleAgentAction(.rename) } label: {
                Label { Text("Rename") } icon: { Image(.edit) }
            }
            .disabledWhileReadOnly()
            .accessibilityIdentifier("conversation.actions.rename")
            Divider()
            Button(role: .destructive) {
                handleAgentAction(.delete)
            } label: {
                Label { Text("Delete Agent") } icon: { Image(.delete) }
            }
            .disabledWhileReadOnly()
            .accessibilityIdentifier("conversation.actions.delete")
        } label: {
            ToolbarOverflowLabel()
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel(assistantStore == nil ? "Agent actions" : "Assistant actions")
        .accessibilityIdentifier(assistantStore == nil ? "conversation.actions.open" : "assistant.actions")
    }

    /// Note detail sheet content for a tapped note reference.
    private func noteSheet(for noteInfo: NoteSheetInfo) -> some View {
        ConversationNoteSheet(noteInfo: noteInfo, session: session) {
            agentPresentation.dismissNote()
        }
    }

    private func navigateBack() {
        if let onBack {
            onBack()
        } else {
            dismiss()
        }
    }

    /// Delete-confirmation action: deletes the agent then dismisses this view.
    private func deleteAgent() {
        HapticManager.notification(.warning)
        agentPresentation.beginDeletion()
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
                    navigateBack()
                }
            } catch {
                agentPresentation.deletionFailed()
                AppLog.userInterface.error("[ConversationView] Failed to delete agent: \(error)")
            }
        }
    }

    /// Rename-alert action: applies the trimmed name if non-empty.
    private func renameAgent() {
        let newName = agentPresentation.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard viewModel.agentNotFound, !agentPresentation.suppressesMissingAgentFallback else { return }
        if let onAgentUnavailable {
            onAgentUnavailable()
            return
        }
        coordinator.handleMissingAgent(agentId: viewModel.agentId, workspaceId: viewModel.workspaceId)
    }

    private func navigateToNote(noteId: String, workspaceId: String, title: String) {
        agentPresentation.present(.note(NoteSheetInfo(noteId: noteId, workspaceId: workspaceId, noteTitle: title)))
    }

    private func navigateToAgent(agentId: String, workspaceId: String, name: String) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        childAgent = AgentDestination(
            agentId: agentId,
            workspaceId: workspaceId,
            agentName: name
        )
    }
}
