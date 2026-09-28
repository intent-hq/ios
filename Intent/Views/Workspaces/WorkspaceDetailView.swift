import SwiftUI

struct WorkspaceDetailView: View {
    let workspaceId: String
    @Environment(AppCoordinator.self) var coordinator
    @State private var agentStore: AgentStore
    @State private var viewModel = AgentListViewModel()
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showBackgroundAgents = false
    @State private var expandedDelegates: Set<String> = []
    @State private var showDeleteConfirmation = false
    @State private var showArchiveConfirmation = false
    @State private var showSpecialistPicker = false
    @State private var selectedTerminal: MobileTerminal?
    @State private var selectedBrowser: WorkspaceBrowser?
    @State private var createdBrowser: WorkspaceBrowser?
    @State private var showNewBrowser = false
    @State private var terminalCreationRequest: UUID?
    @State private var selectedTab = WorkspaceTab.agents
    @State private var noteStore: NoteStore
    @State private var scriptStore: WorkspaceScriptStore
    @State private var changesStore: WorkspaceChangesStore
    @Environment(BackendSession.self) private var session

    init(workspaceId: String, session: BackendSession) {
        self.workspaceId = workspaceId
        _agentStore = State(initialValue: AgentStore(connectionManager: session.connection, summaries: session.agentSummaries))
        _noteStore = State(initialValue: NoteStore(connectionManager: session.connection))
        _scriptStore = State(initialValue: WorkspaceScriptStore(connection: session.connection))
        _changesStore = State(initialValue: WorkspaceChangesStore(connectionManager: session.connection))
    }

    var agentStoreConnectionID: ObjectIdentifier { ObjectIdentifier(agentStore.connectionManager) }

    var noteStoreConnectionID: ObjectIdentifier { ObjectIdentifier(noteStore.connectionManager) }

    var changesStoreConnectionID: ObjectIdentifier {
        ObjectIdentifier(changesStore.connectionManager)
    }

    private var workspaceStore: WorkspaceStore { session.workspaceStore }
    private var terminalStore: MobileTerminalStore { session.mobileTerminalStore }
    private var browserStore: WorkspaceBrowserStore { session.browserStore }

    private var workspace: Workspace? { workspaceStore.workspaces.first { $0.id == workspaceId } }

    private var workspaceTitle: String {
        guard let title = workspace?.title,
              !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "<Untitled>"
        }
        return title
    }

    private var lifecycleContent: some View {
        ZStack {
            WorkspaceDetailStyle.background(for: colorScheme).ignoresSafeArea()
            detailContent
        }
        .onAppear {
            if let connectionId = session.backendID?.connectionID {
                NotificationManager.shared.workspaceOpened(
                    workspaceId: workspaceId,
                    connectionId: connectionId
                )
            }
            // AgentStore retains rows while returning from a conversation.
            agentStore.startObservingEvents()
            noteStore.startObservingEvents()
            Task { await agentStore.fetchAgents(workspaceId: workspaceId) }
            Task { await noteStore.fetchNotes(workspaceId: workspaceId) }
            if let savedTab = PersistenceManager.shared.loadWorkspaceTab(workspaceId: workspaceId) {
                selectedTab = WorkspaceTab(persistedValue: savedTab)
            }
        }
        .onDisappear {
            scriptStore.cancelPendingLaunch(workspaceId: workspaceId)
            // Remove only this workspace/connection pair, preserving other windows.
            if let connectionId = session.backendID?.connectionID {
                NotificationManager.shared.workspaceClosed(
                    workspaceId: workspaceId,
                    connectionId: connectionId
                )
            }
        }
        .onChange(of: workspaceId) { oldId, newId in
            scriptStore.cancelPendingLaunch(workspaceId: oldId)
            terminalCreationRequest = nil
            selectedTerminal = nil
            selectedBrowser = nil
            createdBrowser = nil
            showNewBrowser = false
            if let connectionId = session.backendID?.connectionID {
                NotificationManager.shared.workspaceClosed(
                    workspaceId: oldId,
                    connectionId: connectionId
                )
                NotificationManager.shared.workspaceOpened(
                    workspaceId: newId,
                    connectionId: connectionId
                )
            }
            viewModel.agents = []
            agentStore.prepareForWorkspaceChange(to: newId)
            noteStore.prepareForWorkspaceChange(to: newId)
            showBackgroundAgents = false
            expandedDelegates = []
            agentStore.startObservingEvents()  // Re-register with new workspaceId context
            noteStore.startObservingEvents()
            Task { await agentStore.fetchAgents(workspaceId: newId) }
            Task { await noteStore.fetchNotes(workspaceId: newId) }
            selectedTab = WorkspaceTab.restored(
                persistedValue: PersistenceManager.shared.loadWorkspaceTab(workspaceId: newId),
                fallback: .agents
            )
        }
        .onChange(of: selectedTab) { _, newTab in
            PersistenceManager.shared.saveWorkspaceTab(
                workspaceId: workspaceId,
                tab: newTab.persistedValue
            )
        }
        .onChange(of: agentStore.agents) { _, newAgents in
            viewModel.agents = newAgents
        }
        .onChange(of: workspaceStore.workspaces) { _, newWorkspaces in
            // After workspaces load, if ours is missing it was deleted/archived externally
            if workspaceStore.lastUpdated != nil, !newWorkspaces.contains(where: { $0.id == workspaceId }) {
                coordinator.handleMissingWorkspace()
            }
        }
        .task(id: workspaceId) { await terminalStore.refresh(workspaceId: workspaceId) }
        .task(id: workspaceId) { await browserStore.refresh(workspaceId: workspaceId) }
        .task(id: workspaceId) { await scriptStore.refresh(workspaceId: workspaceId) }
        .onChange(of: scriptStore.browserToOpen(workspaceId: workspaceId)) { _, _ in presentScriptBrowser() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { scriptStore.cancelPendingLaunch(workspaceId: workspaceId) }
        }
    }

    var body: some View {
        lifecycleContent
        #if os(visionOS)
        // Deliberate confirmation sheets (HIG): destructive/irreversible
        // workspace actions get a focused sheet with one primary action.
        .sheet(isPresented: $showDeleteConfirmation) {
            WorkspaceActionConfirmationSheet(
                title: "Delete Workspace",
                message: "Are you sure you want to delete this workspace? This cannot be undone.",
                actionLabel: "Delete",
                isDestructive: true,
                onConfirm: deleteWorkspace
            )
        }
        .sheet(isPresented: $showArchiveConfirmation) {
            WorkspaceActionConfirmationSheet(
                title: "Archive Workspace",
                message: "Archive this workspace? You can unarchive it later.",
                actionLabel: "Archive",
                isDestructive: false,
                onConfirm: archiveWorkspace
            )
        }
        #else
        .alert("Delete Workspace", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: deleteWorkspace)
        } message: {
            Text("Are you sure you want to delete this workspace? This cannot be undone.")
        }
        .alert("Archive Workspace", isPresented: $showArchiveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Archive", action: archiveWorkspace)
        } message: {
            Text("Archive this workspace? You can unarchive it later.")
        }
        #endif
        .sheet(isPresented: $showSpecialistPicker) {
            SpecialistPickerView(
                workspaceId: workspaceId,
                agentStore: agentStore,
                optionsStore: session.creationOptionsStore
            )
                .environment(coordinator)
        }
        .sheet(
            isPresented: $showNewBrowser,
            onDismiss: {
                selectedBrowser = createdBrowser
                createdBrowser = nil
            },
            content: {
                NewWorkspaceBrowserView(workspaceId: workspaceId, store: browserStore) { browser in
                    selectedTab = .agents
                    createdBrowser = browser
                }
            }
        )
        .fullScreenCover(item: $selectedBrowser) { browser in
            WorkspaceBrowserView(browser: browser, connection: session.connection)
        }
        .fullScreenCover(
            item: $selectedTerminal,
            onDismiss: {
                // The terminal already showed any error inline; don't replay it as an alert.
                terminalStore.clearError(workspaceId: workspaceId)
            },
            content: { terminal in
                MobileTerminalView(terminal: terminal, workspaceName: workspaceTitle, store: terminalStore)
            }
        )
        .alert("Terminal unavailable", isPresented: Binding(
            get: { terminalStore.errorMessage(workspaceId: workspaceId) != nil && selectedTerminal == nil },
            set: { if !$0 { terminalStore.clearError(workspaceId: workspaceId) } }
        )) {
            Button("OK") { terminalStore.clearError(workspaceId: workspaceId) }
        } message: {
            Text(terminalStore.errorMessage(workspaceId: workspaceId) ?? "")
        }
        .navigationTitle(workspaceTitle)
        .toolbarTitleDisplayMode(.inline)
        #if !os(visionOS)
        .navigationBarBackButtonHidden()
        .nativeNavigationBackGesture()
        .toolbarBackground(WorkspaceDetailStyle.background(for: colorScheme), for: .navigationBar)
        #endif
        .toolbar {
            #if os(visionOS)
            // The workspace picker lives in the top toolbar on visionOS.
            ToolbarItem(placement: .topBarTrailing) {
                toolbarWorkspacePicker
            }
            #else
            ToolbarItem(placement: .topBarLeading) {
                Button(action: coordinator.onBackToWorkspaceList) {
                    Image(.arrowLeft)
                        .resizable()
                        .scaledToFit()
                        .frame(width: WorkspaceDetailStyle.iconSize, height: WorkspaceDetailStyle.iconSize)
                        .frame(minWidth: Constants.Accessibility.minimumTapTarget, minHeight: Constants.Accessibility.minimumTapTarget)
                        .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
                }
                .accessibilityLabel("Back to workspaces")
            }
            #endif
            ToolbarItem(placement: .principal) {
                toolbarTitle
            }
            ToolbarItem(placement: .primaryAction) {
                workspaceActions
            }
        }
    }
}

private extension WorkspaceDetailView {
    var toolbarTitle: some View {
        VStack(spacing: WorkspaceDetailStyle.tabInset) {
            Text(workspaceTitle)
                .interFont(Constants.Typography.bodyXSEmphasized)
                .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
            Text("Workspace")
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme))
        }
        .lineLimit(1)
    }

    var workspaceActions: some View {
        WorkspaceActionsMenu(
            workspaceId: workspaceId,
            scriptStore: scriptStore,
            isTerminalDisabled: !terminalStore.isConnected || terminalStore.creatingWorkspaces.contains(workspaceId),
            onCreateAgent: { showSpecialistPicker = true },
            onCreateTerminal: createTerminal,
            onCreateBrowser: { showNewBrowser = true },
            onArchive: { showArchiveConfirmation = true },
            onDelete: { showDeleteConfirmation = true }
        )
    }

    func createTerminal() {
        let requestedWorkspace = workspaceId
        let request = UUID()
        terminalCreationRequest = request
        Task {
            let terminal = await terminalStore.create(workspaceId: requestedWorkspace)
            if terminalCreationRequest == request { selectedTerminal = terminal }
        }
    }

    func presentScriptBrowser() {
        guard scenePhase == .active, selectedBrowser == nil, selectedTerminal == nil, !showNewBrowser else {
            scriptStore.cancelPendingLaunch(workspaceId: workspaceId)
            return
        }
        guard let browser = scriptStore.takeBrowserToOpen(workspaceId: workspaceId) else { return }
        selectedTab = .agents
        selectedBrowser = try? browserStore.open(workspaceId: workspaceId, url: browser.url)
    }

    var detailContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                WorkspaceDetailHeader(
                    workspaceId: workspaceId,
                    workspace: workspace,
                    title: workspaceTitle,
                    selection: $selectedTab
                )
                tabContent
            }
        }
        .refreshable {
            if selectedTab == .agents {
                await agentStore.fetchAgents(workspaceId: workspaceId)
                await terminalStore.refresh(workspaceId: workspaceId)
                await browserStore.refresh(workspaceId: workspaceId)
                await scriptStore.refresh(workspaceId: workspaceId)
            } else if selectedTab == .changes {
                await changesStore.refresh(workspaceId: workspaceId)
            } else {
                await noteStore.fetchNotes(workspaceId: workspaceId)
            }
        }
    }

    var hasWorkspaceResources: Bool {
        !terminalStore.activeTerminals(workspaceId: workspaceId).isEmpty
            || !browserStore.browsers(workspaceId: workspaceId).isEmpty
            || browserStore.errorMessage(workspaceId: workspaceId) != nil
            || !scriptStore.scriptsWithRuns(workspaceId: workspaceId).isEmpty
            || scriptStore.errorMessage(workspaceId: workspaceId) != nil
    }

    var toolbarWorkspacePicker: some View {
        Picker("Workspace Content", selection: $selectedTab) {
            Label { Text("Agents").interFont(Constants.Typography.bodyXS) } icon: { Image(systemName: "person.2") }
            .tag(WorkspaceTab.agents)
            Label { Text("Context").interFont(Constants.Typography.bodyXS) } icon: { Image(systemName: "doc.text") }
            .tag(WorkspaceTab.context)
            Label { Text("Changes").interFont(Constants.Typography.bodyXS) } icon: { Image(systemName: "plus.forwardslash.minus") }
            .tag(WorkspaceTab.changes)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    var tabContent: some View {
        if selectedTab == .agents {
            if agentStore.isLoading || !agentStore.hasLoaded, viewModel.agents.isEmpty, !hasWorkspaceResources {
                ProgressView { Text("Loading agents...").interFont(Constants.Typography.bodyS) }
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .frame(maxWidth: .infinity, minHeight: Constants.WorkspaceList.emptyStateHeight)
            } else if viewModel.agents.isEmpty, !hasWorkspaceResources {
                ContentUnavailableView {
                    Label { Text("No Agents").interFont(Constants.Typography.bodyM.withFace(.semibold)) } icon: { Image(systemName: "person.2") }
                } description: {
                    Text("Agents will appear here when active.").interFont(Constants.Typography.bodyS)
                }
                .frame(maxWidth: .infinity, minHeight: Constants.WorkspaceList.emptyStateHeight)
            } else {
                agentListContent
            }
        } else if selectedTab == .changes {
            WorkspaceChangesView(workspaceId: workspaceId, store: changesStore)
        } else {
            NoteListView(workspaceId: workspaceId, noteStore: noteStore)
        }
    }

    var agentListContent: some View {
        LazyVStack(spacing: WorkspaceDetailStyle.rowSpacing) {
            foregroundAgents
            backgroundAgents
            WorkspaceMobileTerminalsView(workspaceId: workspaceId, store: terminalStore) { terminal in
                selectedTerminal = terminal
            }
            WorkspaceBrowsersView(workspaceId: workspaceId, store: browserStore) { browser in
                selectedBrowser = browser
            }
            WorkspaceScriptsView(workspaceId: workspaceId, store: scriptStore)
        }
        .padding(.horizontal, WorkspaceDetailStyle.pageInset)
        .padding(.bottom, WorkspaceDetailStyle.pageInset)
    }

    var foregroundAgents: some View {
        ForEach(viewModel.foregroundAgents) { agent in
            foregroundAgent(agent)
        }
    }

    @ViewBuilder
    func foregroundAgent(_ agent: AgentSession) -> some View {
        VStack(spacing: WorkspaceDetailStyle.stackTopSpacing) {
            agentButton(agent)
            let delegates = viewModel.delegatedAgents(for: agent.id)
            if !delegates.isEmpty {
                DelegatedAgentsRow(
                    agents: delegates,
                    isExpanded: expandedDelegates.contains(agent.id),
                    colorScheme: colorScheme
                ) { toggleDelegates(agent.id) }
                if expandedDelegates.contains(agent.id) {
                    ForEach(delegates) { delegate in
                        agentButton(delegate, indented: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    var backgroundAgents: some View {
        if !viewModel.standaloneBackgroundAgents.isEmpty {
            BackgroundAgentsHeader(
                agents: viewModel.standaloneBackgroundAgents,
                isExpanded: showBackgroundAgents,
                colorScheme: colorScheme
            ) { showBackgroundAgents.toggle() }
            if showBackgroundAgents {
                ForEach(viewModel.standaloneBackgroundAgents) { agent in
                    agentButton(agent)
                }
            }
        }
    }

    func agentButton(_ agent: AgentSession, indented: Bool = false) -> some View {
        Button {
            coordinator.onSelectAgent(agent.id, workspaceId: workspaceId, agentName: agent.name)
        } label: {
            AgentRowView(agent: agent, colorScheme: colorScheme, indented: indented)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workspace.agent.\(agent.id)")
        .visionListRowHitTarget()
        .contextMenu {
            AgentNotificationsMuteButton(agent: agent) { toggleNotificationsMuted(agent) }
        }
    }

    private func toggleNotificationsMuted(_ agent: AgentSession) {
        Task {
            do {
                try await agentStore.setNotificationsMuted(
                    agentId: agent.id,
                    workspaceId: workspaceId,
                    muted: !agent.notificationsMuted
                )
            } catch {
                AppLog.workspace.error("[WorkspaceDetail] Notification mute toggle failed: \(error)")
            }
        }
    }

    private func toggleDelegates(_ agentId: String) {
        if expandedDelegates.contains(agentId) {
            expandedDelegates.remove(agentId)
        } else {
            expandedDelegates.insert(agentId)
        }
    }

    private func deleteWorkspace() {
        Task {
            do {
                _ = try await session.connection.request(
                    "workspace.delete",
                    params: ["workspaceId": workspaceId]
                )
                coordinator.onBackToWorkspaceList()
                await workspaceStore.fetchAll()
            } catch {
                AppLog.workspace.error("[WorkspaceDetail] Delete failed: \(error)")
            }
        }
    }

    private func archiveWorkspace() {
        Task {
            do {
                _ = try await session.connection.request(
                    "workspace.archive",
                    params: ["workspaceId": workspaceId]
                )
                coordinator.onBackToWorkspaceList()
                await workspaceStore.fetchAll()
            } catch {
                AppLog.workspace.error("[WorkspaceDetail] Archive failed: \(error)")
            }
        }
    }
}
