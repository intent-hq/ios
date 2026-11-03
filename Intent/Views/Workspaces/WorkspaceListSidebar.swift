import SwiftUI

struct WorkspaceListSidebar: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar
    @Environment(\.isIPadPaneVisible) private var isPaneVisible
    @Environment(\.openAgentHistory) private var openAgentHistory
    @Environment(\.openConnectionSwitcher) private var openConnectionSwitcher
    private let workspaceStore: WorkspaceStore
    private let onCreateWorkspace: () -> Void
    private let onCollapse: (() -> Void)?
    private var isEmbedded: Bool { onCollapse != nil }
    private var isFocusedSearch: Bool { isEmbedded && isSearching }
    private var contentInset: CGFloat {
        if isFocusedSearch { return IPadShellLayout.focusContentInset }
        return usesVerticalBar ? IPadSidebarStyle.compactInset : IPadSidebarStyle.inset
    }
    private var filterListSpacing: CGFloat {
        if isFocusedSearch { return IPadShellLayout.focusContentInset }
        return usesVerticalBar ? IPadSidebarStyle.compactSectionSpacing : IPadSidebarStyle.filterListSpacing
    }
    private var surface: Color { isEmbedded ? IPadSidebarStyle.background(for: colorScheme) : Theme.sidebar(for: colorScheme) }
    @State private var viewModel: WorkspaceListViewModel
    @State private var revealedSwipeTarget: WorkspaceSwipeTarget?
    @State private var workspaceSwipeProgress: [String: CGFloat] = [:]
    @State private var pendingAction: PendingAction?
    @State private var actionError: String?
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
            if isFocusedSearch {
                IPadSidebarTitle(title: "Workspaces")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, contentInset)
                    .padding(.top, IPadShellLayout.focusContentInset)
            } else if let onCollapse {
                sidebarHeader(onCollapse: onCollapse)
            }
            if !isSearching {
                WorkspaceSearchBar(
                    viewMode: $viewModel.viewMode,
                    isSearching: $isSearching,
                    horizontalPadding: isEmbedded ? contentInset : Constants.WorkspaceList.pickerHorizontalPadding,
                    isSidebar: isEmbedded
                )
            }

            workspaceResults
        }
        .background(surface)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSearching {
                WorkspaceSearchInput(
                    text: $viewModel.searchText,
                    isSearching: $isSearching,
                    isFocused: $searchFocused,
                    surfaceColor: isFocusedSearch ? IPadShellStyle.panel(for: colorScheme) : nil,
                    horizontalPadding: isFocusedSearch ? contentInset : Constants.WorkspaceSearch.contentSpacing
                )
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
        .alert(pendingAction?.action.title ?? "Workspace", isPresented: confirmationPresented, presenting: pendingAction) { pending in
            Button("Cancel", role: .cancel) {}
            Button(pending.action.label, role: pending.action == .delete ? .destructive : nil) {
                perform(pending)
            }
        } message: { pending in
            Text(pending.action.message(workspaceTitle: pending.workspace.title))
        }
        .alert("Workspace action failed", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "Please try again.")
        }
        .onChange(of: isSearching) { _, searching in
            revealedSwipeTarget = nil
            if !searching {
                searchFocused = false
                viewModel.searchText = ""
            }
        }
        .onChange(of: viewModel.viewMode) { _, _ in revealedSwipeTarget = nil }
        .onChange(of: viewModel.searchText) { _, _ in revealedSwipeTarget = nil }
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
}

extension WorkspaceListSidebar {
    private var workspaceResults: some View {
        ZStack {
            surface
            if viewModel.isLoading, viewModel.workspaces.isEmpty {
                ProgressView {
                    Text("Loading workspaces...").interFont(Constants.Typography.bodyS)
                }
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            } else if viewModel.filteredWorkspaces.isEmpty {
                if viewModel.hasSearchQuery {
                    WorkspaceSearchEmptyState()
                } else {
                    emptyState
                }
            } else {
                workspaceList
            }
        }
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
                    .environment(\.defaultMinListRowHeight, 0)
            } else {
                workspaceListContent.listStyle(.sidebar)
            }
        }
        .environment(\.defaultMinListHeaderHeight, isEmbedded ? 0 : nil)
        .listRowSpacing(isEmbedded ? 0 : nil)
        #if !os(visionOS)
        // SwiftUI marks scrollDismissesKeyboard @available(visionOS, unavailable).
        .scrollDismissesKeyboard(.immediately)
        // Custom row backgrounds already mark selection; suppress the system
        // keyboard-focus halo (ios#339).
        .focusEffectDisabled()
        #endif
        .scrollContentBackground(isEmbedded ? .hidden : .automatic)
        .accessibilityIdentifier("workspaces.list")
        .contentMargins(.horizontal, isEmbedded ? contentInset : nil, for: .scrollContent)
        // Keep the filter gap scrollable so it cannot consume the reduced
        // viewport above the keyboard; the final row retains bottom clearance.
        .contentMargins(.top, isEmbedded ? filterListSpacing : Constants.WorkspaceList.sidebarTopContentMargin, for: .scrollContent)
        .contentMargins(.bottom, isEmbedded ? IPadSidebarStyle.inset : (isSearching ? 0 : AssistantLaunchButton.scrollClearance), for: .scrollContent)
        .mask(alignment: .top) { scrollFadeMask }
    }

    /// Rows dissolve under the filter control instead of clipping. The fade fits inside the
    /// list's top margin, so resting rows stay fully opaque.
    private var scrollFadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: isEmbedded ? min(IPadSidebarStyle.scrollFadeHeight, filterListSpacing) : 0)
            Color.black
        }
    }

    private var workspaceListContent: some View {
        List(selection: Binding(
            get: { coordinator.selectedWorkspaceId },
            set: { newId in
                searchFocused = false
                if let id = newId {
                    coordinator.onSelectWorkspace(id)
                } else if !isEmbedded {
                    coordinator.selectedWorkspaceId = nil
                }
            }
        )) {
            switch viewModel.viewMode {
            case .recent:
                sidebarRows(viewModel.filteredWorkspaces)
            case .repo:
                repoGroups
            case .status:
                let groups = viewModel.groupedByStatus.map { statusLabel, workspaces in
                    let content = sidebarGroup(workspaces, isFirst: statusLabel == viewModel.groupedByStatus.first?.0) {
                        Text(statusLabel).interFont(Constants.Typography.eyebrow)
                    }
                    return (id: statusLabel, content: content)
                }
                ForEach(groups, id: \.id) { @Sendable group in group.content }
            }
        }
    }

    @ViewBuilder
    private var repoGroups: some View {
        let groups = viewModel.groupedByRepo.map { repoName, workspaces in
            let isExpanded = viewModel.isRepoGroupExpanded(repoName)
            let content = sidebarGroup(
                workspaces,
                isFirst: repoName == viewModel.groupedByRepo.first?.0,
                showRepo: false,
                isExpanded: isExpanded,
                disclosure: (repoName, { viewModel.toggleRepoGroup(repoName) })
            ) {
                HStack(spacing: Constants.WorkspaceList.sidebarSectionSpacing) {
                    RepoOwnerAvatarView(
                        owner: workspaces.first?.repositoryOwner,
                        size: Constants.WorkspaceList.sidebarSectionAvatarSize
                    )
                    Text(repoName).interFont(Constants.Typography.eyebrow)
                }
            }
            return (id: repoName, content: content)
        }
        ForEach(groups, id: \.id) { @Sendable group in group.content }
    }

    @ViewBuilder
    private func sidebarGroup<Header: View>(
        _ workspaces: [Workspace],
        isFirst: Bool,
        showRepo: Bool = true,
        isExpanded: Bool = true,
        disclosure: (repoKey: String, toggle: () -> Void)? = nil,
        @ViewBuilder header: () -> Header
    ) -> some View {
        if isEmbedded {
            // Ordinary header rows avoid the List's implicit section padding.
            // The scroll-content top margin is the entire filter-to-label gap.
            let insets = EdgeInsets(
                top: isFirst ? 0 : IPadSidebarStyle.sectionSpacing,
                leading: IPadSidebarStyle.rowInset,
                bottom: IPadSidebarStyle.groupLabelSpacing,
                trailing: IPadSidebarStyle.rowInset
            )
            Group {
                if let disclosure {
                    disclosureHeader(disclosure, isExpanded: isExpanded, insets: insets, label: header())
                } else {
                    header()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(insets)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            if isExpanded { sidebarRows(workspaces, showRepo: showRepo) }
        } else if let disclosure {
            Section(header: disclosureHeader(disclosure, isExpanded: isExpanded, insets: EdgeInsets(), label: header())) {
                if isExpanded { sidebarRows(workspaces, showRepo: showRepo) }
            }
        } else {
            Section(header: header()) { sidebarRows(workspaces, showRepo: showRepo) }
        }
    }

    private func disclosureHeader<Label: View>(
        _ disclosure: (repoKey: String, toggle: () -> Void),
        isExpanded: Bool,
        insets: EdgeInsets,
        label: Label
    ) -> some View {
        RepoGroupDisclosureButton(
            repoKey: disclosure.repoKey,
            isExpanded: isExpanded,
            isToggleEnabled: !viewModel.hasSearchQuery,
            insets: insets,
            action: disclosure.toggle
        ) { label }
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
            isSidebar: isEmbedded,
            isSelected: coordinator.selectedWorkspaceId == workspace.id,
            isNextSelected: nextWorkspaceId != nil && coordinator.selectedWorkspaceId == nextWorkspaceId
        ) {
            searchFocused = false
            coordinator.onSelectWorkspace(workspace.id)
        } onOpenRecentAgent: {
            searchFocused = false
            coordinator.onOpenRecentWorkspaceAgent(workspace.id)
        } onAction: { action in
            searchFocused = false
            pendingAction = PendingAction(workspace: workspace, action: action)
        }
        #endif
    }

    static func rowSelectionBackground(isSelected: Bool, colorScheme: ColorScheme) -> Color {
        isSelected ? Theme.sidebarSelection(for: colorScheme) : .clear
    }
}

private extension WorkspaceListSidebar {
    var confirmationPresented: Binding<Bool> {
        Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })
    }

    var errorPresented: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    func perform(_ pending: PendingAction) {
        Task {
            do {
                try await workspaceStore.perform(pending.action, workspaceId: pending.workspace.id)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    struct PendingAction {
        let workspace: Workspace
        let action: WorkspaceAction
    }
}
