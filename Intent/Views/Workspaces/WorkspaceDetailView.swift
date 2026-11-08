import SwiftUI

struct WorkspaceDetailView: View {
    @ScaledMetric(relativeTo: .title) var emptyStateIconSize: CGFloat = 48
    let workspaceId: String
    private let persistence: PersistenceManager
    /// The window's retained workspace stores; a fresh cache when the caller has none.
    private let storesCache: WorkspaceDetailStoresCache
    private let storesSession: BackendSession
    let isSidebarVisible: Bool
    let sidebar: WorkspaceDetailSidebar?
    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.workspaceUsesVerticalBar) var usesVerticalBar
    @State private var storedPresentation: WorkspaceDetailPresentation
    @State private var selectedTab: WorkspaceTab
    @State private var revealedSwipeTarget: WorkspaceSwipeTarget?
    @State private var notesExpanded = true
    @State private var filesExpanded = true
    @State private var titleEditor = WorkspaceTitleEditor()
    @FocusState private var titleFocused: Bool
    @Environment(BackendSession.self) var session

    init(
        workspaceId: String,
        session: BackendSession,
        storesCache: WorkspaceDetailStoresCache = WorkspaceDetailStoresCache(),
        persistence: PersistenceManager = .shared,
        isSidebarVisible: Bool = false,
        sidebar: WorkspaceDetailSidebar? = nil
    ) {
        self.workspaceId = workspaceId
        self.storesCache = storesCache
        storesSession = session
        self.persistence = persistence
        self.isSidebarVisible = isSidebarVisible
        self.sidebar = sidebar
        _selectedTab = State(initialValue: WorkspaceTab.restored(
            persistedValue: persistence.loadWorkspaceTab(workspaceId: workspaceId),
            fallback: .agents
        ))
        _storedPresentation = State(initialValue: WorkspaceDetailPresentation())
    }

    /// Stores of the shown workspace, kept per window for the last few
    /// workspaces so a switch back (or a drop) shows them from memory.
    var stores: WorkspaceDetailStores {
        storesCache.stores(for: workspaceId) { WorkspaceDetailStores(session: storesSession) }
    }
    var agentStore: AgentStore { stores.agentStore }
    var viewModel: AgentListViewModel { stores.viewModel }
    var noteStore: NoteStore { stores.noteStore }
    var scriptStore: WorkspaceScriptStore { stores.scriptStore }
    var changesStore: WorkspaceChangesStore { stores.changesStore }
    var filesStore: WorkspaceFilesStore { stores.filesStore }
    var presentation: WorkspaceDetailPresentation { storedPresentation }
    var currentTab: WorkspaceTab { get { selectedTab } nonmutating set { selectedTab = newValue } }
    var tabSelection: Binding<WorkspaceTab> { $selectedTab }
    var swipeTarget: Binding<WorkspaceSwipeTarget?> { $revealedSwipeTarget }
    var notesExpansion: Binding<Bool> { $notesExpanded }
    var filesExpansion: Binding<Bool> { $filesExpanded }
    var agentStoreConnectionID: ObjectIdentifier { ObjectIdentifier(agentStore.connectionManager) }
    var noteStoreConnectionID: ObjectIdentifier { ObjectIdentifier(noteStore.connectionManager) }
    var changesStoreConnectionID: ObjectIdentifier { ObjectIdentifier(changesStore.connectionManager) }

    var workspaceStore: WorkspaceStore { session.workspaceStore }
    var terminalStore: MobileTerminalStore { session.mobileTerminalStore }
    var browserStore: WorkspaceBrowserStore { session.browserStore }
    var workspace: Workspace? { workspaceStore.workspaces.first { $0.id == workspaceId } }
    var workspaceTitle: String {
        guard let title = workspace?.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return title
    }
    var workspaceName: String { workspaceTitle.isEmpty ? "New Workspace" : workspaceTitle }
    var showsBackButton: Bool { !coordinator.usesIPadShell || coordinator.iPadNavigation.usesCompactNavigation }
    var showsNavigationTitle: Bool { !coordinator.usesIPadShell && !usesVerticalBar }
    private var lifecycleContent: some View {
        ZStack {
            surface.ignoresSafeArea()
            VStack(spacing: 0) {
                if sidebar != nil {
                    // The Duo sidebar has no collapse control and its rail carries the page actions.
                    if usesVerticalBar {
                        WorkspaceSidebarTitleHeader(title: workspaceName)
                    } else {
                        WorkspaceSidebarHeader {
                            WorkspaceSidebarEditableTitle(
                                workspaceId: workspaceId,
                                workspace: workspace,
                                titleEditor: titleEditor,
                                titleFocus: $titleFocused,
                                onSaveTitle: saveTitle
                            )
                        } actions: { workspaceActionsMenu }
                    }
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
            presentation.resetForWorkspaceChange()
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
            if !presentation.showTransferWorkspace, workspaceStore.lastUpdated != nil, !newWorkspaces.contains(where: { $0.id == workspaceId }) {
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
        if sidebar != nil {
            sidebarContent
        } else {
            pageContent
        }
    }

    var presentedContent: some View {
        lifecycleContent
        .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
            if titleEditor.isEditing {
                WorkspaceTitleEditingControls(editor: titleEditor, onSave: saveTitle)
            }
        }
        .modifier(WorkspaceDetailPresentations(
            presentation: presentation,
            workspaceId: workspaceId,
            workspaceName: workspaceName,
            onArchive: archiveWorkspace,
            onDelete: deleteWorkspace,
            onBrowserCreated: { selectedTab = .agents },
            agentStore: agentStore
        ))
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

    func presentScriptBrowser() {
        guard scenePhase == .active, presentation.selectedBrowser == nil, presentation.selectedTerminal == nil,
              !presentation.showNewBrowser, !presentation.showTransferWorkspace else {
            scriptStore.cancelPendingLaunch(workspaceId: workspaceId)
            return
        }
        guard let browser = scriptStore.takeBrowserToOpen(workspaceId: workspaceId) else { return }
        selectedTab = .agents
        presentation.selectedBrowser = try? browserStore.open(workspaceId: workspaceId, url: browser.url)
    }

    var detailContent: some View {
        ScrollView {
            // Keep the focused title mounted while the agent rows scroll lazily.
            VStack(spacing: 0) {
                detailHeader
                if selectedTab == .agents {
                    LazyVStack(spacing: 0) {
                        tabContent
                    }
                    .padding(.bottom, showsAgentList ? WorkspaceDetailStyle.pageInset : 0)
                } else {
                    tabContent
                }
            }
            .iPadDetailColumn(isEnabled: sidebar == nil)
            // Page children own the 24 pt page inset; on the Duo they line up with the list's 8 pt.
            .padding(.horizontal, isDuoSidebar ? IPadSidebarStyle.compactInset - WorkspaceDetailStyle.pageInset : 0)
        }
        .overlay(alignment: .top) { if sidebar == nil, usesIPadPaneTitle { WorkspaceHeaderFade() } }
        // The Duo pane has no top bar for content to fade under, as in conversations.
        .modifier(ConversationScrollEdgeEffect())
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

    var detailHeader: some View {
        WorkspaceDetailHeader(
            workspaceId: workspaceId,
            workspace: workspace,
            title: workspaceTitle,
            selection: $selectedTab,
            titleEditor: titleEditor,
            titleFocus: $titleFocused,
            headingTopSpacing: sidebarHeadingTopSpacing ?? pageHeadingTopSpacing,
            usesLargeTitle: sidebar == nil && usesIPadPaneTitle,
            showsTitle: sidebar == nil,
            onSaveTitle: saveTitle
        )
    }
}
