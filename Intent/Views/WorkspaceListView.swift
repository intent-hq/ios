import SwiftUI

struct WorkspaceListView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var viewModel = WorkspaceListViewModel()
    @State private var showingCreateWorkspace = false

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
        .background(Theme.background(for: colorScheme))
        .navigationTitle("Workspaces")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    coordinator.onOpenSettings()
                } label: {
                    Image(systemName: "gearshape")
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
        .contentMargins(.bottom, 60)
    }
}

