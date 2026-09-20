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
    @State private var selectedTab = 0  // 0 = Agents, 1 = Context
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
                selectedTab = savedTab
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
            selectedTab = PersistenceManager.shared.loadWorkspaceTab(workspaceId: newId) ?? 0
        }
        .onChange(of: selectedTab) { _, newTab in
            PersistenceManager.shared.saveWorkspaceTab(workspaceId: workspaceId, tab: newTab)
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
        .navigationTitle(workspaceTitle)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            #if os(visionOS)
            // The Agents/Context switcher lives in the detail's top toolbar
            // on visionOS instead of the in-window segmented control, so it
            // visibly belongs to the workspace rather than the sidebar.
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Workspace Content", selection: $selectedTab) {
                    Label("Agents", systemImage: "person.2").tag(0)
                    Label("Context", systemImage: "doc.text").tag(1)
                }
                .pickerStyle(.segmented)
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showSpecialistPicker = true
                    } label: {
                        Label("Create New Agent", systemImage: "plus.circle")
                    }
                    Divider()
                    Button { showArchiveConfirmation = true } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Workspace actions")
            }
        }
    }
}

private extension WorkspaceDetailView {
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
            Text("\(owner)/\(repo)")
                .font(.caption)
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
            Text("Agents").tag(0)
            Text("Context").tag(1)
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
        if selectedTab == 0 {
            if agentStore.isLoading || !agentStore.hasLoaded, viewModel.agents.isEmpty {
                Spacer()
                ProgressView("Loading agents...")
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                Spacer()
            } else if viewModel.agents.isEmpty {
                ContentUnavailableView(
                    "No Agents",
                    systemImage: "person.2",
                    description: Text("Agents will appear here when active.")
                )
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
            }
            .padding(.horizontal, Constants.WorkspaceDetail.horizontalPadding)
        }
        .refreshable { await agentStore.fetchAgents(workspaceId: workspaceId) }
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
        .contentShape(Rectangle())
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

#if os(visionOS)
/// Deliberate confirmation sheet for destructive/irreversible workspace
/// actions: title, consequence copy, one primary action, and a plain
/// cancel — replacing inline alerts per the visionOS HIG.
struct WorkspaceActionConfirmationSheet: View {
    let title: String
    let message: String
    let actionLabel: String
    let isDestructive: Bool
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: Constants.WorkspaceDetail.confirmationSheetSpacing) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Button(role: isDestructive ? .destructive : nil) {
                dismiss()
                onConfirm()
            } label: {
                Text(actionLabel)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(Constants.WorkspaceDetail.confirmationSheetPadding)
        .frame(width: Constants.WorkspaceDetail.confirmationSheetWidth)
    }
}
#endif
