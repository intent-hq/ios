import SwiftUI

struct WorkspaceListSidebar: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var viewModel = WorkspaceListViewModel()
    @State private var showingCreateWorkspace = false
    @State private var showingConnections = false

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
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .font(.subheadline)
                TextField("Search workspaces", text: $viewModel.searchText)
                    .font(.subheadline)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                if !viewModel.searchText.isEmpty {
                    Button(action: { viewModel.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.mutedForeground(for: colorScheme).opacity(0.2), lineWidth: 0.5)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
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
        List(selection: Binding(
            get: { coordinator.selectedWorkspaceId },
            set: { newId in
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
        .contentMargins(.top, 4)
        .contentMargins(.bottom, 60)
    }
}

