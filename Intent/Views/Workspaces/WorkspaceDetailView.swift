import SwiftUI

struct WorkspaceDetailView: View {
    let workspaceId: String
    private let persistence: PersistenceManager
    private let isSidebarVisible: Bool
    let sidebar: WorkspaceDetailSidebar?
    @Environment(AppCoordinator.self) var coordinator
    @State private var storedAgentStore: AgentStore
    @State private var storedViewModel: AgentListViewModel
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar
    @State private var showDeleteConfirmation = false
    @State private var showArchiveConfirmation = false
    @State private var showSpecialistPicker = false
    @State private var selectedTerminal: MobileTerminal?
    @State private var selectedBrowser: WorkspaceBrowser?
    @State private var createdBrowser: WorkspaceBrowser?
    @State private var showNewBrowser = false
    @State private var showTransferWorkspace = false
    @State private var terminalCreationRequest: UUID?
    @State private var selectedTab: WorkspaceTab
    @State private var revealedSwipeTarget: WorkspaceSwipeTarget?
    @State private var noteStore: NoteStore
    @State private var scriptStore: WorkspaceScriptStore
    @State private var changesStore: WorkspaceChangesStore
    @State private var filesStore: WorkspaceFilesStore
    @State private var notesExpanded = true
    @State private var filesExpanded = true
    @State private var titleEditor = WorkspaceTitleEditor()
    @FocusState private var titleFocused: Bool
    @Environment(BackendSession.self) private var session

    init(workspaceId: String, session: BackendSession, persistence: PersistenceManager = .shared, isSidebarVisible: Bool = false, sidebar: WorkspaceDetailSidebar? = nil) {
        self.workspaceId = workspaceId
        self.persistence = persistence
        self.isSidebarVisible = isSidebarVisible
        self.sidebar = sidebar
        _selectedTab = State(initialValue: WorkspaceTab.restored(
            persistedValue: persistence.loadWorkspaceTab(workspaceId: workspaceId),
            fallback: .agents
        ))
        let store = AgentStore(connectionManager: session.connection, summaries: session.agentSummaries, scopedLoading: true)
        _storedAgentStore = State(initialValue: store)
        _storedViewModel = State(initialValue: AgentListViewModel(list: store.list))
        _noteStore = State(initialValue: NoteStore(connectionManager: session.connection))
        _scriptStore = State(initialValue: WorkspaceScriptStore(connection: session.connection))
        _changesStore = State(initialValue: WorkspaceChangesStore(connectionManager: session.connection))
        _filesStore = State(initialValue: .init(connection: session.connection))
    }

    var agentStore: AgentStore { storedAgentStore }
    var viewModel: AgentListViewModel { storedViewModel }
    var currentTab: WorkspaceTab { selectedTab }
    var agentStoreConnectionID: ObjectIdentifier { ObjectIdentifier(agentStore.connectionManager) }
    var noteStoreConnectionID: ObjectIdentifier { ObjectIdentifier(noteStore.connectionManager) }
    var changesStoreConnectionID: ObjectIdentifier { ObjectIdentifier(changesStore.connectionManager) }

    private var workspaceStore: WorkspaceStore { session.workspaceStore }
    private var terminalStore: MobileTerminalStore { session.mobileTerminalStore }
    private var browserStore: WorkspaceBrowserStore { session.browserStore }

    private var workspace: Workspace? { workspaceStore.workspaces.first { $0.id == workspaceId } }

    private var workspaceTitle: String {
        guard let title = workspace?.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return title
    }

    private var workspaceName: String { workspaceTitle.isEmpty ? "New Workspace" : workspaceTitle }

    private var surface: Color {
        guard sidebar != nil else { return WorkspaceDetailStyle.background(for: colorScheme) }
        return coordinator.usesIPadShell ? IPadSidebarStyle.background(for: colorScheme) : Theme.sidebar(for: colorScheme)
    }

    /// Below the iPad pane header, the title's cap top meets the sidebar's filter control and the
    /// repository line starts at the control's bottom edge.
    private static let iPadHeadingTopSpacing = IPadSidebarStyle.sectionSpacing - Constants.Conversation.Design.IPad.headerBottomInset

    /// The persistent iPad sidebar already names the workspace above its list selection.
    private var isBesideIPadSidebar: Bool {
        coordinator.usesIPadShell && coordinator.iPadNavigation.isSidebarVisible && !coordinator.iPadNavigation.usesSidebarOverlay
    }

    private var showsBackButton: Bool { !coordinator.usesIPadShell || coordinator.iPadNavigation.usesCompactNavigation }
    private var lifecycleContent: some View {
        ZStack {
            surface.ignoresSafeArea()
            VStack(spacing: 0) {
                if let sidebar, let onCollapse = sidebar.onCollapse {
                    WorkspaceSidebarHeader(onCollapse: onCollapse) { workspaceActions }
                }
                detailContent
            }
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
        }
        .onDisappear {
            titleEditor.cancel()
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
            titleEditor.cancel()
            scriptStore.cancelPendingLaunch(workspaceId: oldId)
            terminalCreationRequest = nil
            selectedTerminal = nil
            selectedBrowser = nil
            createdBrowser = nil
            showNewBrowser = false
            showTransferWorkspace = false
            revealedSwipeTarget = nil
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
            resetAgentWorkspace(to: newId)
            noteStore.prepareForWorkspaceChange(to: newId)
            if filesStore.workspaceId != newId { filesStore.reset() }
            notesExpanded = true
            filesExpanded = true
            agentStore.startObservingEvents()  // Re-register with new workspaceId context
            noteStore.startObservingEvents()
            Task { await agentStore.fetchAgents(workspaceId: newId) }
            Task { await noteStore.fetchNotes(workspaceId: newId) }
            restoreSelectedTab(workspaceId: newId)
        }
        .onChange(of: selectedTab) { _, newTab in
            persistence.saveWorkspaceTab(
                workspaceId: workspaceId,
                tab: newTab.persistedValue
            )
        }
        .onChange(of: agentStore.agents) { _, newAgents in
            viewModel.agents = newAgents
        }
        .onChange(of: workspaceStore.workspaces) { _, newWorkspaces in
            // After workspaces load, if ours is missing it was deleted/archived externally
            if !showTransferWorkspace, workspaceStore.lastUpdated != nil, !newWorkspaces.contains(where: { $0.id == workspaceId }) {
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
        if let sidebar {
            presentedContent.workspaceSidebarNavigation(sidebar) { workspaceActions }
        } else {
            pageContent
        }
    }

    private var presentedContent: some View {
        lifecycleContent
        .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
            if titleEditor.isEditing {
                WorkspaceTitleEditingControls(editor: titleEditor, onSave: saveTitle)
            }
        }
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
            isPresented: $showTransferWorkspace,
            onDismiss: {
                if workspaceStore.lastUpdated != nil, workspace == nil { coordinator.handleMissingWorkspace() }
            },
            content: {
                WorkspaceTransferSheet(workspaceId: workspaceId, workspaceTitle: workspaceName, session: session)
                    .environment(coordinator)
                    .id(workspaceId)
            }
        )
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
                MobileTerminalView(terminal: terminal, workspaceName: workspaceName, store: terminalStore)
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
    }

    private var firstAgent: WorkspaceFirstAgent? {
        viewModel.foregroundAgents.first.map { WorkspaceFirstAgent(id: $0.id, workspaceId: workspaceId, name: $0.name) }
    }

    private var pageContent: some View {
        presentedContent
        .preference(key: WorkspaceFirstAgentPreference.self, value: firstAgent)
        .navigationTitle(workspaceName)
        .toolbar(removing: usesVerticalBar ? .title : nil)
        .toolbarTitleDisplayMode(.inline)
        #if !os(visionOS)
        .navigationBarBackButtonHidden()
        .nativeNavigationBackGesture()
        .toolbarBackground(WorkspaceDetailStyle.background(for: colorScheme), for: .navigationBar)
        #endif
        .toolbar {
            if usesVerticalBar {
                WorkspaceVerticalNavigationToolbar(
                    isEnabled: true,
                    showsBackButton: showsBackButton && !isSidebarVisible,
                    backLabel: "Back to workspaces",
                    backIdentifier: "workspaceDetail.back",
                    onBack: coordinator.onBackToWorkspaceList
                ) { workspaceActions }
            } else {
                #if os(visionOS)
                // The workspace picker lives in the top toolbar on visionOS.
                ToolbarItem(placement: .topBarTrailing) { toolbarWorkspacePicker }
                #else
                if showsBackButton {
                    ToolbarItem(placement: .topBarLeading) {
                        IntentIconButton(icon: .arrowLeft, label: "Back to workspaces", showsBackground: false, action: coordinator.onBackToWorkspaceList)
                            .accessibilityIdentifier("workspaceDetail.back")
                    }
                    .intentToolbarSurface()
                }
                #endif
                ToolbarItem(placement: .principal) { toolbarTitle }
                ToolbarItem(placement: .primaryAction) { workspaceActions }
                .intentToolbarSurface()
            }
        }
        #if !os(visionOS)
        .workspacePhoneNavigation(
            title: workspaceTitle,
            createdAt: workspace?.createdAt,
            showsBackButton: showsBackButton,
            showsTitle: !isBesideIPadSidebar,
            onBack: coordinator.onBackToWorkspaceList
        ) { workspaceActions }
        #endif
    }
}

private extension WorkspaceDetailView {
    func saveTitle() {
        Task { await titleEditor.save(connection: session.connection, store: workspaceStore) }
    }

    func restoreSelectedTab(workspaceId: String) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedTab = WorkspaceTab.restored(
                persistedValue: persistence.loadWorkspaceTab(workspaceId: workspaceId),
                fallback: .agents
            )
        }
    }

    var toolbarTitle: some View {
        VStack(spacing: WorkspaceDetailStyle.tabInset) {
            WorkspaceTitle(title: workspaceTitle, createdAt: workspace?.createdAt) { title in
                Text(title)
                    .interFont(Constants.Typography.bodyXSEmphasized)
            }
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
            onTransfer: session.connection.currentPrincipal?.isOwner == true
                && session.connection.connectionState == .connected ? { showTransferWorkspace = true } : nil,
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
        guard scenePhase == .active, selectedBrowser == nil, selectedTerminal == nil, !showNewBrowser, !showTransferWorkspace else {
            scriptStore.cancelPendingLaunch(workspaceId: workspaceId)
            return
        }
        guard let browser = scriptStore.takeBrowserToOpen(workspaceId: workspaceId) else { return }
        selectedTab = .agents
        selectedBrowser = try? browserStore.open(workspaceId: workspaceId, url: browser.url)
    }

    var detailContent: some View {
        ScrollView {
            if selectedTab == .agents {
                LazyVStack(spacing: 0) {
                    detailHeader
                    tabContent
                }
                .padding(.bottom, showsAgentList ? WorkspaceDetailStyle.pageInset : 0)
                .iPadDetailColumn(isEnabled: sidebar == nil)
            } else {
                VStack(spacing: 0) {
                    detailHeader
                    tabContent
                }
                .iPadDetailColumn(isEnabled: sidebar == nil)
            }
        }
        .accessibilityIdentifier("workspace.detail.scroll")
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
                await filesStore.refresh()
            }
        }
    }

    private var detailHeader: some View {
        VStack(spacing: 0) {
            WorkspaceDetailHeader(
                workspaceId: workspaceId,
                workspace: workspace,
                title: workspaceTitle,
                selection: $selectedTab,
                titleEditor: titleEditor,
                titleFocus: $titleFocused,
                headingTopSpacing: sidebar?.headingTopSpacing ?? (coordinator.usesIPadShell ? Self.iPadHeadingTopSpacing : nil),
                usesLargeTitle: sidebar == nil && coordinator.usesIPadShell,
                onSaveTitle: saveTitle
            )
        }
    }

    private var showsAgentLoading: Bool {
        (agentStore.isLoading || !agentStore.hasLoaded) && viewModel.agents.isEmpty && !hasWorkspaceResources
    }

    private var showsAgentList: Bool { !showsAgentLoading && (viewModel.hasAgentSections || hasWorkspaceResources) }

    var hasWorkspaceResources: Bool {
        !terminalStore.activeTerminals(workspaceId: workspaceId).isEmpty
            || !browserStore.browsers(workspaceId: workspaceId).isEmpty
            || browserStore.errorMessage(workspaceId: workspaceId) != nil
            || !scriptStore.scriptsWithRuns(workspaceId: workspaceId).isEmpty
            || scriptStore.errorMessage(workspaceId: workspaceId) != nil
    }

    var toolbarWorkspacePicker: some View {
        Picker("Workspace Content", selection: $selectedTab) {
            Label { Text("Agents").interFont(Constants.Typography.bodyXS) } icon: { Image(.agents) }
            .tag(WorkspaceTab.agents)
            Label { Text("Context").interFont(Constants.Typography.bodyXS) } icon: { Image(.file) }
            .tag(WorkspaceTab.context)
            Label { Text("Changes").interFont(Constants.Typography.bodyXS) } icon: { Image(.gitDiff) }
            .tag(WorkspaceTab.changes)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    var tabContent: some View {
        if selectedTab == .agents {
            if showsAgentLoading {
                ProgressView { Text("Loading agents...").interFont(Constants.Typography.bodyS) }
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .frame(maxWidth: .infinity, minHeight: Constants.WorkspaceList.emptyStateHeight)
            } else if !viewModel.hasAgentSections, !hasWorkspaceResources {
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
            WorkspaceContextView(workspaceId: workspaceId, noteStore: noteStore, filesStore: filesStore, notesExpanded: $notesExpanded, filesExpanded: $filesExpanded)
        }
    }

    @ViewBuilder
    var agentListContent: some View {
        let rows = agentListRows
        let entries = rows.enumerated().map { index, row in
            (id: row.id, content: WorkspaceAgentListEntry(row: row, isFirst: index == 0))
        }
        ForEach(snapshots: entries, id: \.id) { entry in entry.content }
        if hasWorkspaceResources {
            WorkspaceDetailResources(
                workspaceId: workspaceId,
                terminalStore: terminalStore,
                browserStore: browserStore,
                scriptStore: scriptStore,
                revealedTarget: $revealedSwipeTarget,
                followsAgents: !rows.isEmpty,
                onSelectTerminal: { selectedTerminal = $0 },
                onSelectBrowser: { selectedBrowser = $0 }
            )
        }
    }

    private func deleteWorkspace() { changeWorkspace("workspace.delete") }

    private func archiveWorkspace() { changeWorkspace("workspace.archive") }

    private func changeWorkspace(_ method: String) {
        Task {
            do {
                _ = try await session.connection.request(method, params: ["workspaceId": workspaceId])
                coordinator.onBackToWorkspaceList()
                await workspaceStore.fetchAll()
            } catch {
                AppLog.workspace.error("[WorkspaceDetail] \(method) failed: \(error)")
            }
        }
    }
}
