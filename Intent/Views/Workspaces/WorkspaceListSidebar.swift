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
        .background(Theme.sidebar(for: colorScheme))
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
            onCreateWorkspace: { if coordinator.canCreateWorkspace { showingCreateWorkspace = true } },
            onConnections: { showingConnections = true }
        ))
        .navigationTitle("Workspaces")
        .onChange(of: coordinator.canCreateWorkspace) { _, allowed in
            if !allowed { showingCreateWorkspace = false }
        }
        .sheet(isPresented: $showingCreateWorkspace) {
            CreateWorkspaceView(session: session)
                .environment(coordinator)
        }
        .sheet(isPresented: $showingConnections) {
            ConnectionsView()
                .environment(coordinator)
        }
        .visionWorkspaceAttentionSound(viewModel.workspaces)
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
                            .interFont(Constants.Typography.eyebrow)
                    }) {
                        ForEach(workspaces) { workspace in
                            sidebarRow(workspace, showRepo: false)
                        }
                    }
                }
            case .status:
                ForEach(viewModel.groupedByStatus, id: \.0) { statusLabel, workspaces in
                    Section(header: Text(statusLabel).interFont(Constants.Typography.eyebrow)) {
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
        // With a hardware keyboard attached, iPadOS draws the focused row's
        // selection as an accent-coloured halo once the row background is
        // customised (ios#339). The grey listRowBackground already marks the
        // selection, so suppress the default focus effect for the sidebar rows.
        .focusEffectDisabled()
        #endif
        .contentMargins(.top, Constants.WorkspaceList.sidebarTopContentMargin)
        .contentMargins(.bottom, isSearching ? 0 : AssistantLaunchButton.scrollClearance, for: .scrollContent)
    }

    /// Shared row modifiers for every view mode. The explicit row background
    /// replaces the sidebar list's accent-tinted selection with a neutral grey.
    /// On visionOS that custom background also replaces the system row
    /// background that drew the gaze highlight (ios#339), so the hover effect
    /// is reapplied to the row content in the selection's rounded shape.
    private func sidebarRow(_ workspace: Workspace, showRepo: Bool = true) -> some View {
        WorkspaceRowView(workspace: workspace, colorScheme: colorScheme, showRepo: showRepo)
            #if os(visionOS)
            .contentShape(
                .hoverEffect,
                .rect(cornerRadius: Constants.WorkspaceList.sidebarSelectionCornerRadius)
            )
            .hoverEffect()
            #endif
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
