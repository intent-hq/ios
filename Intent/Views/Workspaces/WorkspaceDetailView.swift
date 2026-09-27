import SwiftUI

struct WorkspaceDetailView: View {
    let workspaceId: String
    @Environment(AppCoordinator.self) var coordinator
    @State private var agentStore: AgentStore
    @State private var viewModel = AgentListViewModel()
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
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
    @Environment(BackendSession.self) private var session

    init(workspaceId: String, session: BackendSession) {
        self.workspaceId = workspaceId
        _agentStore = State(initialValue: AgentStore(connectionManager: session.connection))
        _noteStore = State(initialValue: NoteStore(connectionManager: session.connection))
    }

    var agentStoreConnectionID: ObjectIdentifier {
        ObjectIdentifier(agentStore.connectionManager)
    }

    var noteStoreConnectionID: ObjectIdentifier {
        ObjectIdentifier(noteStore.connectionManager)
    }

    private var workspaceStore: WorkspaceStore { session.workspaceStore }
    private var terminalStore: MobileTerminalStore { session.mobileTerminalStore }
    private var browserStore: WorkspaceBrowserStore { session.browserStore }

    private var workspace: Workspace? {
        workspaceStore.workspaces.first { $0.id == workspaceId }
    }

    private var workspaceTitle: String {
        guard let title = workspace?.title,
              !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "<Untitled>"
        }
        return title
    }

    private var lifecycleContent: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()
            detailContent
        }
        .onAppear {
            if let connectionId = session.backendID?.connectionID {
                NotificationManager.shared.workspaceOpened(
                    workspaceId: workspaceId,
                    connectionId: connectionId
                )
            }
            // Don't clear viewModel.agents here — AgentStore handles that when workspaceId changes.
            // Clearing here causes an empty list flash when swiping back from conversation.
            agentStore.startObservingEvents()
            noteStore.startObservingEvents()
            Task { await agentStore.fetchAgents(workspaceId: workspaceId) }
            Task { await noteStore.fetchNotes(workspaceId: workspaceId) }
            if let savedTab = PersistenceManager.shared.loadWorkspaceTab(workspaceId: workspaceId) {
                selectedTab = WorkspaceTab(persistedValue: savedTab)
            }
        }
        .onDisappear {
            // Keyed by (workspace, connection): removing this pair never
            // clobbers another window's visibility.
            if let connectionId = session.backendID?.connectionID {
                NotificationManager.shared.workspaceClosed(
                    workspaceId: workspaceId,
                    connectionId: connectionId
                )
            }
        }
        .onChange(of: workspaceId) { oldId, newId in
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
        .sheet(isPresented: $showNewBrowser, onDismiss: {
            selectedBrowser = createdBrowser
            createdBrowser = nil
        }) {
            NewWorkspaceBrowserView(workspaceId: workspaceId, store: browserStore) { browser in
                selectedTab = .agents
                createdBrowser = browser
            }
        }
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
        .toolbar {
            #if os(visionOS)
            // The Agents/Context switcher lives in the detail's top toolbar
            // on visionOS instead of the in-window segmented control, so it
            // visibly belongs to the workspace rather than the sidebar.
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Workspace Content", selection: $selectedTab) {
                    Label { Text("Agents").interFont(Constants.Typography.bodyXS) } icon: { Image(systemName: "person.2") }
                    .tag(WorkspaceTab.agents)
                    Label { Text("Context").interFont(Constants.Typography.bodyXS) } icon: { Image(systemName: "doc.text") }
                    .tag(WorkspaceTab.context)
                }
                .pickerStyle(.segmented)
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                workspaceActions
            }
        }
    }
}

private extension WorkspaceDetailView {
    var workspaceActions: some View {
        Menu {
            Button { showSpecialistPicker = true } label: {
                Label { Text("Create New Agent").interFont(Constants.Typography.bodyS) } icon: { Image(.addCircle) }
            }
            Button(action: createTerminal) {
                Label { Text("New terminal").interFont(Constants.Typography.bodyS) } icon: { Image(systemName: "terminal") }
            }
            .disabled(!terminalStore.isConnected || terminalStore.creatingWorkspaces.contains(workspaceId))
            Button { showNewBrowser = true } label: {
                Label { Text("New browser").interFont(Constants.Typography.bodyS) } icon: { Image(systemName: "globe") }
            }
            Divider()
            Button { showArchiveConfirmation = true } label: {
                Label { Text("Archive").interFont(Constants.Typography.bodyS) } icon: { Image(systemName: "archivebox") }
            }
            Button(role: .destructive) { showDeleteConfirmation = true } label: {
                Label { Text("Delete").interFont(Constants.Typography.bodyS) } icon: { Image(systemName: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Workspace actions")
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

    var detailContent: some View {
        VStack(spacing: 0) {
            repositoryName
            statusImage
            taskProgress
            workspacePicker
            tabContent
        }
    }

    @ViewBuilder
    var statusImage: some View {
        if let statusImageAssetId = WorkspaceStatusImageLayout.assetId(for: workspace) {
            WorkspaceStatusImageView(
                workspaceId: workspaceId,
                assetId: statusImageAssetId,
                style: .detail
            )
            .padding(.horizontal, Constants.WorkspaceDetail.horizontalPadding)
            .padding(.bottom, Constants.WorkspaceDetail.statusImageBottomPadding)
        }
    }

    @ViewBuilder
    var repositoryName: some View {
        if let owner = workspace?.repositoryOwner, let repo = workspace?.repositoryName {
            Text("\(owner)/\(repo)").interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.mutedForeground(
                    for: colorScheme,
                    contrast: colorSchemeContrast
                ))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Constants.WorkspaceDetail.horizontalPadding)
                .padding(.bottom, Constants.WorkspaceDetail.titleBottomPadding)
        }
    }
    @ViewBuilder
    var taskProgress: some View {
        if let total = workspace?.taskStatsTotal,
           let progress = WorkspaceTaskProgressLayout(
               total: total,
               completed: workspace?.taskStatsCompleted ?? 0,
               inProgress: workspace?.taskStatsInProgress ?? 0
           ) {
            WorkspaceTaskProgressView(progress: progress)
        }
    }
    @ViewBuilder
    var workspacePicker: some View {
        #if !os(visionOS)
        Picker("Workspace Content", selection: $selectedTab) {
            Text("Agents").interFont(Constants.Typography.bodyXS).tag(WorkspaceTab.agents)
            Text("Context").interFont(Constants.Typography.bodyXS).tag(WorkspaceTab.context)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Constants.WorkspaceDetail.horizontalPadding)
        .padding(.top, WorkspaceDetailHeaderLayout.tabTopPadding(
            hasTaskProgress: (workspace?.taskStatsTotal ?? 0) > 0
        ))
        .padding(.bottom, Constants.WorkspaceDetail.tabVerticalPadding)
        #endif
    }

    @ViewBuilder
    var tabContent: some View {
        if selectedTab == .agents {
            if agentStore.isLoading || !agentStore.hasLoaded, viewModel.agents.isEmpty,
               terminalStore.activeTerminals(workspaceId: workspaceId).isEmpty,
               browserStore.browsers(workspaceId: workspaceId).isEmpty,
               browserStore.errorMessage(workspaceId: workspaceId) == nil {
                Spacer()
                ProgressView { Text("Loading agents...").interFont(Constants.Typography.bodyS) }
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                Spacer()
            } else if viewModel.agents.isEmpty, terminalStore.activeTerminals(workspaceId: workspaceId).isEmpty,
                      browserStore.browsers(workspaceId: workspaceId).isEmpty,
                      browserStore.errorMessage(workspaceId: workspaceId) == nil {
                ContentUnavailableView {
                    Label { Text("No Agents").interFont(Constants.Typography.bodyM.withFace(.semibold)) } icon: { Image(systemName: "person.2") }
                } description: {
                    Text("Agents will appear here when active.").interFont(Constants.Typography.bodyS)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                agentListContent
            }
        } else {
            NoteListView(workspaceId: workspaceId, noteStore: noteStore)
        }
    }

    var agentListContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                foregroundAgents
                backgroundAgents
                WorkspaceMobileTerminalsView(workspaceId: workspaceId, store: terminalStore) { terminal in
                    selectedTerminal = terminal
                }
                WorkspaceBrowsersView(workspaceId: workspaceId, store: browserStore) { browser in
                    selectedBrowser = browser
                }
            }
            .padding(.horizontal, Constants.WorkspaceDetail.horizontalPadding)
        }
        .refreshable {
            await agentStore.fetchAgents(workspaceId: workspaceId)
            await terminalStore.refresh(workspaceId: workspaceId)
            await browserStore.refresh(workspaceId: workspaceId)
        }
    }

    var foregroundAgents: some View {
        ForEach(viewModel.foregroundAgents) { agent in
            foregroundAgent(agent)
        }
    }

    @ViewBuilder
    func foregroundAgent(_ agent: AgentSession) -> some View {
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
