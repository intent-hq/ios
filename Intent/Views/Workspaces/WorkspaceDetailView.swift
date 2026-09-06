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
    @State private var progressWidth: CGFloat = 0
    @State private var noteStore: NoteStore
    @Environment(BackendSession.self) private var session

    init(workspaceId: String, session: BackendSession) {
        self.workspaceId = workspaceId
        _agentStore = State(initialValue: AgentStore(connectionManager: session.connection))
        _noteStore = State(initialValue: NoteStore(connectionManager: session.connection))
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

    var body: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()

            VStack(spacing: 0) {
                // Repo name
                if let owner = workspace?.repositoryOwner, let repo = workspace?.repositoryName {
                    Text("\(owner)/\(repo)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Constants.WorkspaceDetail.horizontalPadding)
                        .padding(.bottom, Constants.WorkspaceDetail.titleBottomPadding)
                }

                // Task progress bar
                if let total = workspace?.taskStatsTotal,
                   let progress = WorkspaceTaskProgressLayout(
                       total: total,
                       completed: workspace?.taskStatsCompleted ?? 0,
                       inProgress: workspace?.taskStatsInProgress ?? 0
                   ) {
                    let progressSummary = "\(progress.completed) of \(progress.total) tasks complete"
                        + (progress.inProgress > 0
                            ? ", \(progress.inProgress) in progress"
                            : "")

                    VStack(alignment: .leading,
                           spacing: Constants.WorkspaceDetail.progressSectionSpacing) {
                        Text(progressSummary)
                            .font(.caption)
                            .foregroundStyle(Theme.mutedForeground(
                                for: colorScheme, contrast: colorSchemeContrast))
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: Constants.WorkspaceDetail.progressSpacing) {
                            if progress.completed > 0 {
                                RoundedRectangle(cornerRadius: Constants.WorkspaceDetail.progressCornerRadius)
                                    .fill(Color.green)
                                    .frame(width: progressWidth > 0
                                        ? progress.segmentWidth(
                                            for: progress.completed,
                                            in: progressWidth,
                                            spacing: Constants.WorkspaceDetail.progressSpacing)
                                        : 0)
                            }
                            if progress.inProgress > 0 {
                                RoundedRectangle(cornerRadius: Constants.WorkspaceDetail.progressCornerRadius)
                                    .fill(Color.blue)
                                    .frame(width: progressWidth > 0
                                        ? progress.segmentWidth(
                                            for: progress.inProgress,
                                            in: progressWidth,
                                            spacing: Constants.WorkspaceDetail.progressSpacing)
                                        : 0)
                            }
                            if progress.remaining > 0 {
                                RoundedRectangle(cornerRadius: Constants.WorkspaceDetail.progressCornerRadius)
                                    .fill(Theme.mutedForeground(
                                        for: colorScheme, contrast: colorSchemeContrast).opacity(
                                            colorSchemeContrast == .increased
                                                ? 0.55
                                                : Constants.WorkspaceDetail.remainingProgressOpacity))
                                    .frame(width: progressWidth > 0
                                        ? progress.segmentWidth(
                                            for: progress.remaining,
                                            in: progressWidth,
                                            spacing: Constants.WorkspaceDetail.progressSpacing)
                                        : 0)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: Constants.WorkspaceDetail.progressHeight)
                        .clipShape(RoundedRectangle(
                            cornerRadius: Constants.WorkspaceDetail.progressCornerRadius))
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.width
                        } action: { width in
                            progressWidth = width
                        }
                        .overlay {
                            if colorSchemeContrast == .increased {
                                RoundedRectangle(
                                    cornerRadius: Constants.WorkspaceDetail.progressCornerRadius)
                                    .strokeBorder(Theme.border(
                                        for: colorScheme, contrast: colorSchemeContrast),
                                        lineWidth: 1.5)
                            }
                        }
                        .accessibilityHidden(true)
                    }
                    .padding(.horizontal, Constants.WorkspaceDetail.horizontalPadding)
                    .padding(.bottom, Constants.WorkspaceDetail.progressBottomPadding)
                }

                #if !os(visionOS)
                Picker("Workspace Content", selection: $selectedTab) {
                    Text("Agents").tag(0)
                    Text("Context").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Constants.WorkspaceDetail.horizontalPadding)
                .padding(.vertical, Constants.WorkspaceDetail.tabVerticalPadding)
                #endif

                // Tab content
                if selectedTab == 0 {
                    // Agent list
                    if (agentStore.isLoading || !agentStore.hasLoaded) && viewModel.agents.isEmpty {
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
                    // Notes list
                    NoteListView(workspaceId: workspaceId, noteStore: noteStore)
                }

            }
        }
        .onAppear {
            NotificationManager.shared.currentWorkspaceId = workspaceId
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
            // Only clear if we're still the active workspace
            if NotificationManager.shared.currentWorkspaceId == workspaceId {
                NotificationManager.shared.currentWorkspaceId = nil
            }
        }
        .onChange(of: workspaceId) { _, newId in
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
            if workspaceStore.lastUpdated != nil && !newWorkspaces.contains(where: { $0.id == workspaceId }) {
                coordinator.handleMissingWorkspace(workspaceId: workspaceId)
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
            SpecialistPickerView(workspaceId: workspaceId, agentStore: agentStore)
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

    @ViewBuilder
    private var agentListContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Foreground agents
                ForEach(viewModel.foregroundAgents) { agent in
                    Button {
                        coordinator.onSelectAgent(agent.id, workspaceId: workspaceId, agentName: agent.name)
                    } label: {
                        AgentRowView(agent: agent, colorScheme: colorScheme)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .visionListRowHitTarget()

                    let delegates = viewModel.delegatedAgents(for: agent.id)
                    if !delegates.isEmpty {
                        DelegatedAgentsRow(
                            agents: delegates,
                            isExpanded: expandedDelegates.contains(agent.id),
                            colorScheme: colorScheme,
                            onToggle: { toggleDelegates(agent.id) }
                        )
                        if expandedDelegates.contains(agent.id) {
                            ForEach(delegates) { delegate in
                                Button {
                                    coordinator.onSelectAgent(delegate.id, workspaceId: workspaceId, agentName: delegate.name)
                                } label: {
                                    AgentRowView(agent: delegate, colorScheme: colorScheme, indented: true)
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())
                                .visionListRowHitTarget()
                            }
                        }
                    }
                }

                // Standalone background agents
                if !viewModel.standaloneBackgroundAgents.isEmpty {
                    BackgroundAgentsHeader(
                        agents: viewModel.standaloneBackgroundAgents,
                        isExpanded: showBackgroundAgents,
                        colorScheme: colorScheme,
                        onToggle: { showBackgroundAgents.toggle() }
                    )
                    if showBackgroundAgents {
                        ForEach(viewModel.standaloneBackgroundAgents) { agent in
                            Button {
                                coordinator.onSelectAgent(agent.id, workspaceId: workspaceId, agentName: agent.name)
                            } label: {
                                AgentRowView(agent: agent, colorScheme: colorScheme)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .visionListRowHitTarget()
                        }
                    }
                }
            }
            .padding(.horizontal, Constants.WorkspaceDetail.horizontalPadding)
        }
        .refreshable {
            await agentStore.fetchAgents(workspaceId: workspaceId)
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
                let _ = try await session.connection.request(
                    "workspace.delete", params: ["workspaceId": workspaceId])
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
                let _ = try await session.connection.request(
                    "workspace.archive", params: ["workspaceId": workspaceId])
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

struct WorkspaceTaskProgressLayout: Equatable {
    let total: Int
    let completed: Int
    let inProgress: Int
    let remaining: Int

    init?(total: Int, completed: Int, inProgress: Int) {
        guard total > 0 else { return nil }
        self.total = total
        self.completed = min(max(0, completed), total)
        self.inProgress = min(max(0, inProgress), total - self.completed)
        self.remaining = total - self.completed - self.inProgress
    }

    var visibleSegmentCount: Int {
        [completed, inProgress, remaining].count(where: { $0 > 0 })
    }

    func segmentWidth(
        for count: Int,
        in measuredWidth: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        let totalSpacing = spacing * CGFloat(max(0, visibleSegmentCount - 1))
        let distributableWidth = max(0, measuredWidth - totalSpacing)
        return distributableWidth * CGFloat(count) / CGFloat(total)
    }
}

