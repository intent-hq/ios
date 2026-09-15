import SwiftUI

struct WorkspaceListSidebar: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) private var session
    @Environment(\.colorScheme) var colorScheme
    private let workspaceStore: WorkspaceStore
    @State private var viewModel: WorkspaceListViewModel
    @State private var showingCreateWorkspace = false
    @State private var showingConnections = false
    @FocusState private var searchFocused: Bool

    init(workspaceStore: WorkspaceStore) {
        self.workspaceStore = workspaceStore
        _viewModel = State(initialValue: WorkspaceListViewModel(workspaceStore: workspaceStore))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $viewModel.viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Constants.WorkspaceList.pickerHorizontalPadding)
            .padding(.vertical, Constants.WorkspaceList.pickerVerticalPadding)

            ZStack {
                Theme.sidebar(for: colorScheme).ignoresSafeArea()

                if viewModel.isLoading, viewModel.workspaces.isEmpty {
                    ProgressView("Loading workspaces...")
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                } else if viewModel.filteredWorkspaces.isEmpty {
                    if viewModel.hasSearchQuery {
                        ContentUnavailableView.search
                    } else {
                        emptyState
                    }
                } else {
                    workspaceList
                }
            }
        }
        .background(Theme.sidebar(for: colorScheme))
        .navigationTitle("Workspaces")
        .workspaceSearch(text: $viewModel.searchText, isFocused: $searchFocused)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Button {
                        showingCreateWorkspace = true
                    } label: {
                        Label("Create New Workspace", systemImage: "plus.rectangle")
                    }
                    Button {
                        coordinator.onOpenSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    Divider()
                    Button {
                        showingConnections = true
                    } label: {
                        Label("Connect to…", systemImage: "desktopcomputer")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                }
                .accessibilityLabel("Workspace options")
            }
        }
        .sheet(isPresented: $showingCreateWorkspace) {
            CreateWorkspaceView(session: session)
                .environment(coordinator)
        }
        .sheet(isPresented: $showingConnections) {
            ConnectionsView()
                .environment(coordinator)
        }
        .refreshable {
            await workspaceStore.fetchAll()
        }
        .visionWorkspaceAttentionSound(viewModel.workspaces)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Workspaces",
            systemImage: "rectangle.stack.badge.plus",
            description: Text("Create one in the desktop app.")
        )
    }

    private var workspaceList: some View {
        List(selection: workspaceSelection) { workspaceSections }
            .listStyle(.sidebar)
            #if !os(visionOS)
            .scrollDismissesKeyboard(.immediately)
            #endif
            .contentMargins(.top, Constants.WorkspaceList.sidebarTopContentMargin)
    }

    private var workspaceSelection: Binding<String?> {
        Binding(
            get: { coordinator.selectedWorkspaceId },
            set: selectWorkspace
        )
    }

    private func selectWorkspace(_ newId: String?) {
        searchFocused = false
        if let id = newId {
            coordinator.onSelectWorkspace(id)
        } else {
            coordinator.selectedWorkspaceId = nil
        }
    }

    @ViewBuilder
    private var workspaceSections: some View {
        switch viewModel.viewMode {
        case .recent:
            ForEach(viewModel.filteredWorkspaces) { workspace in
                workspaceRow(workspace)
            }
        case .repo:
            ForEach(viewModel.groupedByRepo, id: \.0) { repoName, workspaces in
                Section {
                    ForEach(workspaces) { workspace in
                        workspaceRow(workspace, showRepo: false)
                    }
                } header: {
                    HStack(spacing: Constants.WorkspaceList.sidebarSectionSpacing) {
                        RepoOwnerAvatarView(
                            owner: workspaces.first?.repositoryOwner,
                            size: Constants.WorkspaceList.sidebarSectionAvatarSize
                        )
                        Text(repoName)
                    }
                }
            }
        case .status:
            ForEach(viewModel.groupedByStatus, id: \.0) { statusLabel, workspaces in
                Section(header: Text(statusLabel)) {
                    ForEach(workspaces) { workspace in
                        workspaceRow(workspace)
                    }
                }
            }
        }
    }

    private func workspaceRow(_ workspace: Workspace, showRepo: Bool = true) -> some View {
        WorkspaceRowView(workspace: workspace, colorScheme: colorScheme, showRepo: showRepo)
            .tag(workspace.id)
            .listRowInsets(EdgeInsets(
                top: Constants.WorkspaceList.sidebarRowInset,
                leading: Constants.WorkspaceList.sidebarRowInset,
                bottom: Constants.WorkspaceList.sidebarRowInset,
                trailing: Constants.WorkspaceList.sidebarRowInset
            ))
            .listRowSeparator(.hidden)
    }
}
