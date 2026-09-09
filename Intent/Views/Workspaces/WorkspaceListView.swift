import SwiftUI

struct WorkspaceListView: View {
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
                Theme.background(for: colorScheme).ignoresSafeArea()

                if viewModel.isLoading && viewModel.workspaces.isEmpty {
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
        .background(Theme.background(for: colorScheme))
        .navigationTitle("Workspaces")
        .workspaceSearch(text: $viewModel.searchText, isFocused: $searchFocused)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Button {
                        coordinator.onOpenSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    Button {
                        showingConnections = true
                    } label: {
                        Label("Connect to…", systemImage: "desktopcomputer")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Workspace options")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingCreateWorkspace = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create workspace")
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

    @ViewBuilder
    private var workspaceList: some View {
        List {
            switch viewModel.viewMode {
            case .recent:
                ForEach(viewModel.filteredWorkspaces) { workspace in
                    Button {
                        searchFocused = false
                        coordinator.onSelectWorkspace(workspace.id)
                    } label: {
                        WorkspaceRowView(workspace: workspace, colorScheme: colorScheme)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .visionListRowHitTarget()
                }
            case .repo:
                ForEach(viewModel.groupedByRepo, id: \.0) { repoName, workspaces in
                    Section(header: Text(repoName)) {
                        ForEach(workspaces) { workspace in
                            Button {
                                searchFocused = false
                                coordinator.onSelectWorkspace(workspace.id)
                            } label: {
                                WorkspaceRowView(workspace: workspace, colorScheme: colorScheme, showRepo: false)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .visionListRowHitTarget()
                        }
                    }
                }
            case .status:
                ForEach(viewModel.groupedByStatus, id: \.0) { statusLabel, workspaces in
                    Section(header: Text(statusLabel)) {
                        ForEach(workspaces) { workspace in
                            Button {
                                searchFocused = false
                                coordinator.onSelectWorkspace(workspace.id)
                            } label: {
                                WorkspaceRowView(workspace: workspace, colorScheme: colorScheme)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        #if !os(visionOS)
        // SwiftUI marks scrollDismissesKeyboard @available(visionOS, unavailable).
        .scrollDismissesKeyboard(.immediately)
        #endif
    }
}

