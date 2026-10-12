import SwiftUI

struct WorkspaceListSidebar: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.isIPadPaneVisible) private var isPaneVisible
    @Environment(\.openAgentHistory) private var openAgentHistory
    @Environment(\.openConnectionSwitcher) private var openConnectionSwitcher
    private let workspaceStore: WorkspaceStore
    private let onCreateWorkspace: () -> Void
    private let onCollapse: (() -> Void)?
    private var isEmbedded: Bool { onCollapse != nil }
    private var surface: Color { isEmbedded ? IPadSidebarStyle.background(for: colorScheme) : Theme.sidebar(for: colorScheme) }
    @State private var viewModel: WorkspaceListViewModel
    @State private var revealedSwipeTarget: WorkspaceSwipeTarget?
    @State private var workspaceSwipeProgress: [String: CGFloat] = [:]
    @Binding private var isSearching: Bool
    @FocusState private var searchFocused: Bool

    init(
        workspaceStore: WorkspaceStore,
        isSearching: Binding<Bool>,
        onCreateWorkspace: @escaping () -> Void,
        onCollapse: (() -> Void)? = nil
    ) {
        self.workspaceStore = workspaceStore
        self.onCreateWorkspace = onCreateWorkspace
        self.onCollapse = onCollapse
        _viewModel = State(initialValue: WorkspaceListViewModel(workspaceStore: workspaceStore))
        _isSearching = isSearching
    }

    var body: some View {
        VStack(spacing: 0) {
            if let onCollapse {
                sidebarHeader(onCollapse: onCollapse)
            }
            if isEmbedded || !isSearching {
                WorkspaceSearchBar(
                    viewMode: $viewModel.viewMode,
                    isSearching: $isSearching,
                    horizontalPadding: isEmbedded ? IPadSidebarStyle.inset : Constants.WorkspaceList.pickerHorizontalPadding,
                    isSidebar: isEmbedded
                )
                .padding(.bottom, isEmbedded ? IPadSidebarStyle.sectionSpacing : 0)
            }

            ZStack {
                surface

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
        .background(surface)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSearching {
                WorkspaceSearchInput(text: $viewModel.searchText, isSearching: $isSearching, isFocused: $searchFocused)
            }
        }
        .refreshable {
            await workspaceStore.fetchAll()
        }
        .navigationTitle("Workspaces")
        .toolbar {
            if !isEmbedded {
                ToolbarItem(placement: .topBarTrailing) { workspaceMenu }
                    .intentToolbarSurface()
            }
        }
        .onChange(of: viewModel.showArchived) { _, _ in revealedSwipeTarget = nil }
        .onChange(of: isPaneVisible) { _, visible in
            if !visible { searchFocused = false }
        }
        .onDisappear {
            searchFocused = false
            if !isEmbedded {
                isSearching = false
                viewModel.searchText = ""
            }
        }
        .visionWorkspaceAttentionSound(viewModel.workspaces)
    }

    private var workspaceMenu: some View {
        WorkspaceListMenu(
            showArchived: $viewModel.showArchived,
            canCreateWorkspace: coordinator.canCreateWorkspace,
            onCreateWorkspace: onCreateWorkspace,
            onRecentAgents: {
                searchFocused = false
                if !isEmbedded { isSearching = false }
                revealedSwipeTarget = nil
                openAgentHistory()
            },
            onRecentConnections: {
                searchFocused = false
                if !isEmbedded { isSearching = false }
                revealedSwipeTarget = nil
                openConnectionSwitcher()
            },
            showsSidebarTitle: isEmbedded
        )
    }

    private func sidebarHeader(onCollapse: @escaping () -> Void) -> some View {
        IPadSidebarHeader(onCollapse: onCollapse) {
            workspaceMenu
        } actions: {
            IntentIconButton(icon: .addIcon, label: "New workspace", showsBackground: false, action: onCreateWorkspace)
                .disabled(!coordinator.canCreateWorkspace)
                .accessibilityIdentifier("workspaces.create")
            WorkspaceSearchButton(
                isSearching: $isSearching,
                height: Constants.WorkspaceSearch.compactHeight,
                showsBackground: false
            ) { searchFocused = true }
        }
    }

    private var emptyState: some View {
        Button("New workspace", action: onCreateWorkspace)
            .buttonStyle(IntentButtonStyle(variant: .muted))
            .disabled(!coordinator.canCreateWorkspace)
            .accessibilityIdentifier("workspaces.empty.create")
    }

    private var workspaceList: some View {
        Group {
            if isEmbedded {
                // Sidebar list styling clips section edges to the system radius.
                // The persistent sidebar uses the same custom radius for every row.
                workspaceListContent.listStyle(.plain)
            } else {
                workspaceListContent.listStyle(.sidebar)
            }
        }
        .environment(\.defaultMinListHeaderHeight, isEmbedded && viewModel.viewMode == .recent ? 0 : nil)
        .listRowSpacing(isEmbedded ? 0 : nil)
        #if !os(visionOS)
        // SwiftUI marks scrollDismissesKeyboard @available(visionOS, unavailable).
        .scrollDismissesKeyboard(.immediately)
        // Custom row backgrounds already mark selection; suppress the system
        // keyboard-focus halo (ios#339).
        .focusEffectDisabled()
        #endif
        .scrollContentBackground(isEmbedded ? .hidden : .automatic)
        .contentMargins(.horizontal, isEmbedded ? IPadSidebarStyle.inset : nil)
        .contentMargins(.top, isEmbedded ? 0 : Constants.WorkspaceList.sidebarTopContentMargin)
        .contentMargins(.bottom, isEmbedded ? IPadSidebarStyle.inset : (isSearching ? 0 : AssistantLaunchButton.scrollClearance), for: .scrollContent)
    }

    private var workspaceListContent: some View {
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
                recentWorkspaces
            case .repo:
                let groups = viewModel.groupedByRepo.map { repoName, workspaces in
                    let content = Section(header: HStack(spacing: Constants.WorkspaceList.sidebarSectionSpacing) {
                        RepoOwnerAvatarView(
                            owner: workspaces.first?.repositoryOwner,
                            size: Constants.WorkspaceList.sidebarSectionAvatarSize
                        )
                        Text(repoName)
                            .interFont(Constants.Typography.eyebrow)
                    }) {
                        sidebarRows(workspaces, showRepo: false)
                    }
                    .listSectionSeparator(isEmbedded ? .hidden : .automatic)
                    return (id: repoName, content: content)
                }
                ForEach(groups, id: \.id) { @Sendable group in group.content }
            case .status:
                let groups = viewModel.groupedByStatus.map { statusLabel, workspaces in
                    let content = Section(header: Text(statusLabel).interFont(Constants.Typography.eyebrow)) {
                        sidebarRows(workspaces)
                    }
                    .listSectionSeparator(isEmbedded ? .hidden : .automatic)
                    return (id: statusLabel, content: content)
                }
                ForEach(groups, id: \.id) { @Sendable group in group.content }
            }
        }
    }

    @ViewBuilder
    private var recentWorkspaces: some View {
        if isEmbedded {
            Section {
                sidebarRows(viewModel.filteredWorkspaces)
            } header: {
                Color.clear.frame(height: 0)
                    .listRowInsets(EdgeInsets())
                    .accessibilityHidden(true)
            }
            .listSectionSeparator(.hidden)
        } else {
            sidebarRows(viewModel.filteredWorkspaces)
        }
    }

    private func sidebarRows(_ workspaces: [Workspace], showRepo: Bool = true) -> some View {
        // Snapshot selection, updating state and bindings outside every row provider.
        let rows = workspaces.indices.map { index in
            let workspace = workspaces[index]
            let nextID = index + 1 < workspaces.count ? workspaces[index + 1].id : nil
            return (id: workspace.id, content: sidebarRow(workspace, nextWorkspaceId: nextID, showRepo: showRepo))
        }
        return ForEach(rows, id: \.id) { @Sendable row in row.content }
    }

    /// Shared row modifiers for every view mode. The explicit row background
    /// replaces the sidebar list's accent-tinted selection with a neutral grey.
    /// On visionOS that custom background also replaces the system row
    /// background that drew the gaze highlight (ios#339), so the hover effect
    /// is reapplied to the row content in the selection's rounded shape.
    private func sidebarRow(_ workspace: Workspace, nextWorkspaceId: String?, showRepo: Bool = true) -> some View {
        sidebarRowContent(workspace, nextWorkspaceId: nextWorkspaceId, showRepo: showRepo)
            #if os(visionOS)
            .contentShape(
                .hoverEffect,
                .rect(cornerRadius: Constants.WorkspaceList.sidebarSelectionCornerRadius)
            )
            .hoverEffect()
            #endif
            .tag(workspace.id)
            .listRowInsets(EdgeInsets(
                top: isEmbedded ? 0 : Constants.WorkspaceList.sidebarRowInset,
                leading: isEmbedded ? 0 : Constants.WorkspaceList.sidebarRowInset,
                bottom: isEmbedded ? 0 : Constants.WorkspaceList.sidebarRowInset,
                trailing: isEmbedded ? 0 : Constants.WorkspaceList.sidebarRowInset
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(
                RoundedRectangle(
                    cornerRadius: isEmbedded ? IPadSidebarStyle.rowRadius : Constants.WorkspaceList.sidebarSelectionCornerRadius,
                    style: .continuous
                )
                .fill(coordinator.selectedWorkspaceId == workspace.id
                    ? (isEmbedded ? IPadSidebarStyle.selection(for: colorScheme) : Theme.sidebarSelection(for: colorScheme))
                    : .clear)
            )
    }

    @ViewBuilder
    private func sidebarRowContent(_ workspace: Workspace, nextWorkspaceId: String?, showRepo: Bool) -> some View {
        #if os(visionOS)
        WorkspaceRowView(workspace: workspace, colorScheme: colorScheme, showRepo: showRepo)
        #else
        WorkspaceSwipeRow(
            workspace: workspace,
            showRepo: showRepo,
            isUpdating: workspaceStore.updatingWorkspaceIDs.contains(workspace.id),
            revealedTarget: $revealedSwipeTarget,
            workspaceSwipeProgress: $workspaceSwipeProgress,
            nextWorkspaceId: nextWorkspaceId,
            spacious: false,
            showsTrailingActions: false,
            isSidebar: isEmbedded,
            isSelected: coordinator.selectedWorkspaceId == workspace.id,
            isNextSelected: nextWorkspaceId != nil && coordinator.selectedWorkspaceId == nextWorkspaceId
        ) {
            searchFocused = false
            coordinator.onSelectWorkspace(workspace.id)
        } onOpenRecentAgent: {
            searchFocused = false
            coordinator.onOpenRecentWorkspaceAgent(workspace.id)
        } onAction: { _ in }
        #endif
    }

    static func rowSelectionBackground(isSelected: Bool, colorScheme: ColorScheme) -> Color {
        isSelected ? Theme.sidebarSelection(for: colorScheme) : .clear
    }
}
