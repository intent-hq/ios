import SwiftUI

struct WorkspaceListView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) private var session
    @Environment(\.colorScheme) var colorScheme
    private let workspaceStore: WorkspaceStore
    @State private var viewModel: WorkspaceListViewModel
    @State private var showingCreateWorkspace = false
    @State private var showingConnections = false
    @State private var isSearching = false
    @State private var showingDiagnosticLogs = false
    @FocusState private var searchFocused: Bool

    init(workspaceStore: WorkspaceStore) {
        self.workspaceStore = workspaceStore
        _viewModel = State(initialValue: WorkspaceListViewModel(workspaceStore: workspaceStore))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                pageHeader
                Section {
                    workspaceContent
                } header: {
                    if !isSearching {
                        WorkspaceSearchBar(
                            viewMode: $viewModel.viewMode,
                            isSearching: $isSearching,
                            horizontalPadding: Constants.WorkspaceList.pageInset
                        )
                        .background(Theme.background(for: colorScheme))
                    }
                }
            }
            .padding(.bottom, isSearching ? 0 : AssistantLaunchButton.scrollClearance)
        }
        .accessibilityIdentifier("workspaces.list")
        #if !os(visionOS)
        .scrollDismissesKeyboard(.immediately)
        #endif
        .background(Theme.background(for: colorScheme))
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 0)
                .background(Theme.background(for: colorScheme), ignoresSafeAreaEdges: .top)
                .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSearching {
                WorkspaceSearchInput(text: $viewModel.searchText, isSearching: $isSearching, isFocused: $searchFocused)
            }
        }
        .refreshable {
            await workspaceStore.fetchAll()
        }
        .modifier(WorkspaceActionLauncher(
            isSearching: isSearching,
            onCreateWorkspace: { showingCreateWorkspace = true },
            onConnections: { showingConnections = true }
        ))
        .navigationTitle("Workspaces")
        .toolbar(.hidden, for: .navigationBar)
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
        .visionWorkspaceAttentionSound(viewModel.workspaces)
        .preference(
            key: ConnectionBackdropPreference.self,
            value: showingConnections ? ConnectionBackdropPreference.savedOpacity : 0
        )
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Workspaces",
            systemImage: "rectangle.stack.badge.plus",
            description: Text("Create one in the desktop app.")
        )
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isSearching {
                pageActions
            }
            Text("Workspaces")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("workspaces.title")
                .padding(.top, isSearching ? Constants.WorkspaceList.searchTitleSpacing : Constants.WorkspaceList.titleTopSpacing)
                .padding(.bottom, isSearching ? Constants.WorkspaceList.searchTitleSpacing : Constants.WorkspaceList.titleBottomSpacing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Theme.foreground(for: colorScheme))
        .padding(.horizontal, Constants.WorkspaceList.pageInset)
    }

    private var pageActions: some View {
        HStack {
            workspaceOptions
            Spacer()
            Button {
                showingCreateWorkspace = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: Constants.WorkspaceList.actionSize, height: Constants.WorkspaceList.actionSize)
            }
            .accessibilityLabel("Create workspace")
        }
        .font(.title2)
        .buttonStyle(.plain)
    }

    private var workspaceOptions: some View {
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
            Button {
                showingDiagnosticLogs = true
            } label: {
                Label("Export logs", systemImage: "doc.zipper")
            }
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(Constants.WorkspaceList.optionsRotation))
                .frame(width: Constants.WorkspaceList.actionSize, height: Constants.WorkspaceList.actionSize)
        }
        .accessibilityLabel("Workspace options")
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if viewModel.isLoading, viewModel.workspaces.isEmpty {
            ProgressView("Loading workspaces...")
                .frame(maxWidth: .infinity, minHeight: Constants.WorkspaceList.emptyStateHeight)
        } else if viewModel.filteredWorkspaces.isEmpty {
            if viewModel.hasSearchQuery {
                ContentUnavailableView.search
            } else {
                emptyState
            }
        } else {
            workspaceSections
                .padding(.horizontal, Constants.WorkspaceList.pageInset)
        }
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
                groupHeading(repoName)
                ForEach(workspaces) { workspace in
                    workspaceButton(workspace, showRepo: false)
                }
            }
        case .status:
            ForEach(viewModel.groupedByStatus, id: \.0) { statusLabel, workspaces in
                groupHeading(statusLabel)
                ForEach(workspaces) { workspace in
                    workspaceButton(workspace, usesVisionHitTarget: false)
                }
            }
        }
    }

    private func groupHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Constants.WorkspaceList.groupTopSpacing)
            .padding(.bottom, Constants.WorkspaceList.groupBottomSpacing)
            .accessibilityAddTraits(.isHeader)
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
            WorkspaceRowView(workspace: workspace, colorScheme: colorScheme, showRepo: showRepo, spacious: true)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
