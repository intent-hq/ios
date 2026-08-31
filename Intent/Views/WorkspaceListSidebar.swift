import SwiftUI

struct WorkspaceListSidebar: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.colorScheme) var colorScheme
    @State private var viewModel = WorkspaceListViewModel()
    @State private var showingCreateWorkspace = false
    @State private var showingConnections = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // View mode picker
                Picker("View", selection: $viewModel.viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)

                ZStack {
                    Theme.sidebar(for: colorScheme).ignoresSafeArea()

                    if viewModel.isLoading && viewModel.workspaces.isEmpty {
                        ProgressView("Loading workspaces...")
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    } else if viewModel.workspaces.isEmpty {
                        emptyState
                    } else {
                        workspaceList
                    }
                }
            }

            // Floating search bar at bottom
            WorkspaceSearchBar(
                text: $viewModel.searchText,
                isFocused: $searchFocused,
                colorScheme: colorScheme
            )
        }
        .background(Theme.sidebar(for: colorScheme))
        .navigationTitle("Workspaces")
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
            }
        }
        .sheet(isPresented: $showingCreateWorkspace) {
            CreateWorkspaceView()
                .environment(coordinator)
        }
        .sheet(isPresented: $showingConnections) {
            ConnectionsView()
                .environment(coordinator)
        }
        .refreshable {
            await WorkspaceStore.shared.fetchAll()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Text("No workspaces yet")
                .font(.headline)
                .foregroundStyle(Theme.foreground(for: colorScheme))
            Text("Create one in the desktop app.")
                .font(.subheadline)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
    }

    @ViewBuilder
    private var workspaceList: some View {
        List(selection: Binding(
            get: { coordinator.selectedWorkspaceId },
            set: { newId in
                searchFocused = false
                if let id = newId {
                    coordinator.onSelectWorkspace(id)
                } else {
                    coordinator.selectedWorkspaceId = nil
                }
            }
        )) {
            switch viewModel.viewMode {
            case .recent:
                ForEach(viewModel.filteredWorkspaces) { workspace in
                    WorkspaceRowView(workspace: workspace, colorScheme: colorScheme)
                        .tag(workspace.id)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                        .listRowSeparator(.hidden)
                }
            case .repo:
                ForEach(viewModel.groupedByRepo, id: \.0) { repoName, workspaces in
                    Section(header: HStack(spacing: 6) {
                        RepoOwnerAvatarView(owner: workspaces.first?.repositoryOwner, size: 16)
                        Text(repoName)
                    }) {
                        ForEach(workspaces) { workspace in
                            WorkspaceRowView(workspace: workspace, colorScheme: colorScheme, showRepo: false)
                                .tag(workspace.id)
                                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                                .listRowSeparator(.hidden)
                        }
                    }
                }
            case .status:
                ForEach(viewModel.groupedByStatus, id: \.0) { statusLabel, workspaces in
                    Section(header: Text(statusLabel)) {
                        ForEach(workspaces) { workspace in
                            WorkspaceRowView(workspace: workspace, colorScheme: colorScheme)
                                .tag(workspace.id)
                                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                                .listRowSeparator(.hidden)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollDismissesKeyboard(.immediately)
        .contentMargins(.top, 4)
        .contentMargins(.bottom, 60)
    }
}

