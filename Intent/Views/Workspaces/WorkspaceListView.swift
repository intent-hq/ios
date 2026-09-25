import SwiftUI

struct WorkspaceListView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) private var session
    @Environment(\.colorScheme) var colorScheme
    private let workspaceStore: WorkspaceStore
    @State private var viewModel: WorkspaceListViewModel
    @State private var showingCreateWorkspace = false
    @State private var showingConnections = false
    @State private var showingDiagnosticLogs = false
    @FocusState private var searchFocused: Bool

    init(workspaceStore: WorkspaceStore) {
        self.workspaceStore = workspaceStore
        _viewModel = State(initialValue: WorkspaceListViewModel(workspaceStore: workspaceStore))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $viewModel.viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).interFont(Constants.Typography.bodyXS).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Constants.WorkspaceList.pickerHorizontalPadding)
            .padding(.vertical, Constants.WorkspaceList.pickerVerticalPadding)

            ZStack {
                Theme.background(for: colorScheme).ignoresSafeArea()

                if viewModel.isLoading, viewModel.workspaces.isEmpty {
                    ProgressView {
                        Text("Loading workspaces...").interFont(Constants.Typography.bodyS)
                    }
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
                        Label { Text("Settings").interFont(Constants.Typography.bodyS) } icon: { Image(systemName: "gearshape") }
                    }
                    Button {
                        showingConnections = true
                    } label: {
                        Label { Text("Connect to…").interFont(Constants.Typography.bodyS) } icon: { Image(systemName: "desktopcomputer") }
                    }
                    Button {
                        showingDiagnosticLogs = true
                    } label: {
                        Label { Text("Export logs").interFont(Constants.Typography.bodyS) } icon: { Image(systemName: "doc.zipper") }
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
        .sheet(isPresented: $showingDiagnosticLogs) {
            DiagnosticExportView()
        }
        .refreshable {
            await workspaceStore.fetchAll()
        }
        .visionWorkspaceAttentionSound(viewModel.workspaces)
        .preference(
            key: ConnectionBackdropPreference.self,
            value: showingConnections ? ConnectionBackdropPreference.savedOpacity : 0
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("No Workspaces").interFont(Constants.Typography.bodyM.withFace(.semibold))
            } icon: {
                Image(systemName: "rectangle.stack.badge.plus")
            }
        } description: {
            Text("Create one in the desktop app.").interFont(Constants.Typography.bodyS)
        }
    }

    private var workspaceList: some View {
        List { workspaceSections }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            #if !os(visionOS)
            .scrollDismissesKeyboard(.immediately)
            #endif
    }

    @ViewBuilder
    private var workspaceSections: some View {
        switch viewModel.viewMode {
        case .recent:
            ForEach(viewModel.filteredWorkspaces) { workspace in
                workspaceButton(workspace)
            }
        case .repo:
            ForEach(viewModel.groupedByRepo, id: \.0) { repoName, workspaces in
                Section(header: Text(repoName).interFont(Constants.Typography.eyebrow)) {
                    ForEach(workspaces) { workspace in
                        workspaceButton(workspace, showRepo: false)
                    }
                }
            }
        case .status:
            ForEach(viewModel.groupedByStatus, id: \.0) { statusLabel, workspaces in
                Section(header: Text(statusLabel).interFont(Constants.Typography.eyebrow)) {
                    ForEach(workspaces) { workspace in
                        workspaceButton(workspace, usesVisionHitTarget: false)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func workspaceButton(
        _ workspace: Workspace,
        showRepo: Bool = true,
        usesVisionHitTarget: Bool = true
    ) -> some View {
        if usesVisionHitTarget {
            workspaceButtonContent(workspace, showRepo: showRepo)
                .visionListRowHitTarget()
        } else {
            workspaceButtonContent(workspace, showRepo: showRepo)
        }
    }

    private func workspaceButtonContent(_ workspace: Workspace, showRepo: Bool) -> some View {
        Button {
            searchFocused = false
            coordinator.onSelectWorkspace(workspace.id)
        } label: {
            WorkspaceRowView(workspace: workspace, colorScheme: colorScheme, showRepo: showRepo)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
