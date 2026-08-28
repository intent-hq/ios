import SwiftUI

struct WorkspaceListView: View {
    @EnvironmentObject var coordinator: AppCoordinator
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
                .padding(.vertical, 8)

                ZStack {
                    Theme.background(for: colorScheme).ignoresSafeArea()

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
        .background(Theme.background(for: colorScheme))
        .navigationTitle("Workspaces")
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
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingCreateWorkspace = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                }
            }
        }
        .sheet(isPresented: $showingCreateWorkspace) {
            CreateWorkspaceView()
                .environmentObject(coordinator)
        }
        .sheet(isPresented: $showingConnections) {
            ConnectionsView()
                .environmentObject(coordinator)
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
        .scrollDismissesKeyboard(.immediately)
        .contentMargins(.bottom, 60)
    }
}

