import SwiftUI

struct WorkspaceDetailView: View {
    let workspaceId: String
    @EnvironmentObject var coordinator: AppCoordinator
    @StateObject private var agentStore = AgentStore()
    @StateObject private var viewModel = AgentListViewModel()
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @State private var showBackgroundAgents = false
    @State private var expandedDelegates: Set<String> = []
    @State private var showDeleteConfirmation = false
    @State private var showArchiveConfirmation = false
    @State private var showSpecialistPicker = false
    @State private var selectedTab = 0  // 0 = Agents, 1 = Context
    @StateObject private var noteStore = NoteStore()
    @ObservedObject private var workspaceStore = WorkspaceStore.shared

    private var workspace: Workspace? {
        workspaceStore.workspaces.first { $0.id == workspaceId }
    }

    var body: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()

            VStack(spacing: 0) {
                // Title row with menu aligned
                HStack(alignment: .center) {
                    if let title = workspace?.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(title)
                            .font(.title2.bold())
                            .foregroundStyle(Theme.foreground(for: colorScheme))
                            .lineLimit(2)
                    } else {
                        Text("<Untitled>")
                            .font(.title2.bold())
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            .lineLimit(2)
                    }
                    Spacer()
                    Menu {
                        Button {
                            showSpecialistPicker = true
                        } label: {
                            Label("Create New Agent", systemImage: "plus.circle")
                        }
                        Divider()
                        Button(role: .none, action: { showArchiveConfirmation = true }) {
                            Label("Archive", systemImage: "archivebox")
                        }
                        Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, horizontalSizeClass == .compact ? 0 : 4)
                .padding(.bottom, 4)

                // Repo name
                if let owner = workspace?.repositoryOwner, let repo = workspace?.repositoryName {
                    Text("\(owner)/\(repo)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                }

                // Task progress bar
                if let total = workspace?.taskStatsTotal, total > 0 {
                    let completed = workspace?.taskStatsCompleted ?? 0
                    let inProgress = workspace?.taskStatsInProgress ?? 0
                    let remaining = total - completed - inProgress

                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { geometry in
                            HStack(spacing: 1) {
                                if completed > 0 {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.green)
                                        .frame(width: geometry.size.width * CGFloat(completed) / CGFloat(total))
                                }
                                if inProgress > 0 {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.blue)
                                        .frame(width: geometry.size.width * CGFloat(inProgress) / CGFloat(total))
                                }
                                if remaining > 0 {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Theme.mutedForeground(for: colorScheme).opacity(0.2))
                                        .frame(width: geometry.size.width * CGFloat(remaining) / CGFloat(total))
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                        .frame(height: 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }

                // Tab content
                if selectedTab == 0 {
                    // Agent list
                    if agentStore.isLoading && viewModel.agents.isEmpty {
                        Spacer()
                        ProgressView("Loading agents...")
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        Spacer()
                    } else if viewModel.agents.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "person.2")
                                .font(.largeTitle)
                                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            Text("No agents")
                                .font(.headline)
                                .foregroundStyle(Theme.foreground(for: colorScheme))
                            Text("Agents will appear here when active.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        }
                        Spacer()
                    } else {
                        agentListContent
                    }
                } else {
                    // Notes list
                    NoteListView(workspaceId: workspaceId, noteStore: noteStore)
                }

                // Bottom tab bar
                Picker("View", selection: $selectedTab) {
                    Text("Agents").tag(0)
                    Text("Context").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
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
        .alert("Delete Workspace", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        let _ = try await ConnectionManager.shared.request("workspace.delete", params: ["workspaceId": workspaceId])
                        coordinator.onBackToWorkspaceList()
                        await WorkspaceStore.shared.fetchAll()
                    } catch {
                        print("[WorkspaceDetail] Delete failed: \(error)")
                    }
                }
            }
        } message: {
            Text("Are you sure you want to delete this workspace? This cannot be undone.")
        }
        .alert("Archive Workspace", isPresented: $showArchiveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Archive") {
                Task {
                    do {
                        let _ = try await ConnectionManager.shared.request("workspace.archive", params: ["workspaceId": workspaceId])
                        coordinator.onBackToWorkspaceList()
                        await WorkspaceStore.shared.fetchAll()
                    } catch {
                        print("[WorkspaceDetail] Archive failed: \(error)")
                    }
                }
            }
        } message: {
            Text("Archive this workspace? You can unarchive it later.")
        }
        .fullScreenCover(isPresented: $showSpecialistPicker) {
            SpecialistPickerView(workspaceId: workspaceId, agentStore: agentStore)
                .environmentObject(coordinator)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)

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
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
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
}

