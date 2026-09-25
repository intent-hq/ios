import SwiftUI

struct WorkspaceListSidebar: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) private var session
    @Environment(\.colorScheme) var colorScheme
    private let workspaceStore: WorkspaceStore
    @State private var viewModel: WorkspaceListViewModel
    @State private var showingCreateWorkspace = false
    @State private var showingConnections = false
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool

    init(workspaceStore: WorkspaceStore) {
        self.workspaceStore = workspaceStore
        _viewModel = State(initialValue: WorkspaceListViewModel(workspaceStore: workspaceStore))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isSearching {
                WorkspaceSearchBar(viewMode: $viewModel.viewMode, isSearching: $isSearching)
            }

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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSearching {
                WorkspaceSearchInput(text: $viewModel.searchText, isSearching: $isSearching, isFocused: $searchFocused)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isSearching {
                AssistantLaunchButton {
                    coordinator.onSelectAssistant()
                }
            }
        }
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
                    sidebarRow(workspace)
                }
            case .repo:
                ForEach(viewModel.groupedByRepo, id: \.0) { repoName, workspaces in
                    Section(header: HStack(spacing: Constants.WorkspaceList.sidebarSectionSpacing) {
                        RepoOwnerAvatarView(
                            owner: workspaces.first?.repositoryOwner,
                            size: Constants.WorkspaceList.sidebarSectionAvatarSize
                        )
                        Text(repoName)
                    }) {
                        ForEach(workspaces) { workspace in
                            sidebarRow(workspace, showRepo: false)
                        }
                    }
                }
            case .status:
                ForEach(viewModel.groupedByStatus, id: \.0) { statusLabel, workspaces in
                    Section(header: Text(statusLabel)) {
                        ForEach(workspaces) { workspace in
                            sidebarRow(workspace)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        #if !os(visionOS)
        // SwiftUI marks scrollDismissesKeyboard @available(visionOS, unavailable).
        .scrollDismissesKeyboard(.immediately)
        #endif
        .contentMargins(.top, Constants.WorkspaceList.sidebarTopContentMargin)
        .contentMargins(.bottom, isSearching ? 0 : AssistantLaunchButton.scrollClearance, for: .scrollContent)
    }

    /// Shared row modifiers for every view mode. The explicit row background
    /// replaces the sidebar list's accent-tinted selection with a neutral grey.
    private func sidebarRow(_ workspace: Workspace, showRepo: Bool = true) -> some View {
        WorkspaceRowView(workspace: workspace, colorScheme: colorScheme, showRepo: showRepo)
            .tag(workspace.id)
            .listRowInsets(EdgeInsets(
                top: Constants.WorkspaceList.sidebarRowInset,
                leading: Constants.WorkspaceList.sidebarRowInset,
                bottom: Constants.WorkspaceList.sidebarRowInset,
                trailing: Constants.WorkspaceList.sidebarRowInset
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(
                RoundedRectangle(
                    cornerRadius: Constants.WorkspaceList.sidebarSelectionCornerRadius,
                    style: .continuous
                )
                .fill(Self.rowSelectionBackground(
                    isSelected: coordinator.selectedWorkspaceId == workspace.id,
                    colorScheme: colorScheme
                ))
            )
    }

    static func rowSelectionBackground(isSelected: Bool, colorScheme: ColorScheme) -> Color {
        isSelected ? Theme.sidebarSelection(for: colorScheme) : .clear
    }
}
