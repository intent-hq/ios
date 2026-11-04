import CoreText
import SwiftUI

struct WorkspaceListView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) private var session
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.isAgentHistoryOpen) private var isAgentHistoryOpen
    @Environment(\.openAgentHistory) private var openAgentHistory
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar
    @Environment(\.workspaceVerticalBarEdge) private var verticalBarEdge
    private let workspaceStore: WorkspaceStore
    @State private var viewModel: WorkspaceListViewModel
    @State private var showingCreateWorkspace = false
    @State private var showingConnections = false
    @State private var showingConnectionSwitcher = false
    @State private var revealedSwipeTarget: WorkspaceSwipeTarget?
    @State private var workspaceSwipeProgress: [String: CGFloat] = [:]
    @State private var pendingAction: PendingAction?
    @State private var actionError: String?
    @State private var isSearching = false
    @State private var isFilterPinned = false
    @State private var pageHeaderHeight: CGFloat = 0
    @AppStorage("workspaceList.content") private var listContent: WorkspaceListContentKind = .workspaces
    @AppStorage("pullRequests.filter") private var pullRequestFilter: PullRequestListStore.Filter = .created
    @AppStorage("pullRequests.groupsByProject") private var groupsPullRequestsByProject = false
    @State private var showsClosedPullRequests = false
    @State private var pullRequestSearchText = ""
    @State private var creationPullRequest: PullRequestListItem?
    @State private var detailPullRequest: PullRequestListItem?
    @State private var trailingSafeArea: CGFloat = 0
    @State private var leadingSafeArea: CGFloat = 0
    @FocusState private var searchFocused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var headingTracking: CGFloat = -1.2
    @ScaledMetric(relativeTo: .title) private var compactHeadingTracking: CGFloat = -0.56
    @ScaledMetric(relativeTo: .largeTitle) private var headingSize = Constants.Typography.heading1.size
    @ScaledMetric(relativeTo: .title) private var compactHeadingSize = Constants.Typography.heading2.size

    init(workspaceStore: WorkspaceStore) {
        self.workspaceStore = workspaceStore
        _viewModel = State(initialValue: WorkspaceListViewModel(workspaceStore: workspaceStore))
    }

    private var canSwitchConnections: Bool {
        guard case .workspaceList = coordinator.currentScreen else { return false }
        return !showingConnections && !showingCreateWorkspace && creationPullRequest == nil && detailPullRequest == nil && pendingAction == nil && actionError == nil
            && !isAgentHistoryOpen
    }

    private var railSafeArea: CGFloat { verticalBarEdge == .leading ? leadingSafeArea : trailingSafeArea }

    var body: some View {
        WorkspaceConnectionSwitcher(
            isPresented: $showingConnectionSwitcher,
            isEnabled: canSwitchConnections,
            onReveal: prepareConnectionSwitcher
        ) {
            workspacePage
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.trailing } action: { trailingSafeArea = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.leading } action: { leadingSafeArea = $0 }
        .overlay(alignment: verticalBarEdge == .leading ? .topLeading : .topTrailing) {
            if usesVerticalBar {
                pageMenu
                    .frame(
                        width: max(IPadShellLayout.railWidth, railSafeArea + IPadShellLayout.contextualRailOuterInset),
                        height: IPadShellLayout.railWidth
                    )
                    .padding(.top, IPadShellLayout.contextualRailTopPadding(for: verticalBarEdge))
                    .offset(x: verticalBarEdge == .leading ? -railSafeArea : railSafeArea)
            }
        }
        .modifier(WorkspaceActionLauncher(
            isSearching: isSearching,
            // The Intent menu switches between the two lists.
            onWorkspaces: showsPullRequests ? { listContent = .workspaces } : nil,
            onPullRequests: showsPullRequests ? nil : { listContent = .pullRequests },
            onCreateWorkspace: createWorkspace
        ) {
            showingConnectionSwitcher = false
            showingConnections = true
        })
        .navigationTitle("Workspaces")
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: coordinator.shouldDismissWorkspaceCreation) { _, shouldDismiss in
            if shouldDismiss {
                showingCreateWorkspace = false
                creationPullRequest = nil
            }
        }
        .sheet(isPresented: $showingCreateWorkspace) {
            CreateWorkspaceView(session: session, coordinator: coordinator)
                .environment(coordinator)
        }
        .sheet(item: $creationPullRequest) { item in
            CreateWorkspaceView(session: session, coordinator: coordinator, pullRequest: item)
                .environment(coordinator)
        }
        .navigationDestination(item: $detailPullRequest) { item in
            PullRequestDetailView(
                item: item,
                connection: session.connection,
                linkedWorkspace: PullRequestListItem.linkedWorkspaces(viewModel.workspaces)[item.id]
            ) { workspaceId in
                detailPullRequest = nil
                coordinator.onSelectWorkspace(workspaceId)
            }
        }
        .sheet(isPresented: $showingConnections) {
            ConnectionsView()
                .environment(coordinator)
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
        .onChange(of: viewModel.viewMode) { _, _ in revealedSwipeTarget = nil }
        .onChange(of: viewModel.searchText) { _, _ in revealedSwipeTarget = nil }
        .onChange(of: viewModel.showArchived) { _, _ in revealedSwipeTarget = nil }
        .visionWorkspaceAttentionSound(viewModel.workspaces)
        .preference(
            key: ConnectionBackdropPreference.self,
            value: showingConnections ? ConnectionBackdropPreference.savedOpacity : 0
        )
    }

    private var workspacePage: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                pageHeader
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeaderHeight = $0 }
                Section {
                    workspaceContent
                } header: {
                    if !isSearching {
                        filterBar
                        .modifier(WorkspaceListDuoLeadingInset())
                        .background(Constants.WorkspaceList.canvas(for: colorScheme))
                        .transition(.opacity)
                        .animation(reduceMotion ? nil : .easeInOut(duration: Constants.WorkspaceSearch.focusAnimationDuration), value: isFilterPinned)
                    }
                }
            }
            .padding(.bottom, isSearching ? 0 : AssistantLaunchButton.scrollClearance)
        }
        .accessibilityIdentifier("workspaces.list")
        #if !os(visionOS)
        .scrollDismissesKeyboard(.immediately)
        #endif
        .background(Constants.WorkspaceList.canvas(for: colorScheme))
        .onScrollGeometryChange(for: Bool.self) { geometry in
            pageHeaderHeight > 0 && geometry.contentOffset.y + geometry.contentInsets.top >= pageHeaderHeight
        } action: { _, isPinned in
            isFilterPinned = isPinned
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 0)
                .background(Constants.WorkspaceList.canvas(for: colorScheme), ignoresSafeAreaEdges: .top)
                .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSearching {
                searchInput
                    .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .refreshable {
            if showsPullRequests {
                await session.pullRequestListStore.load(pullRequestQuery)
            } else {
                await workspaceStore.fetchAll()
            }
        }
        .task(id: showsPullRequests ? pullRequestQuery : nil) {
            guard showsPullRequests else { return }
            await PullRequestListContent.sync(session.pullRequestListStore, to: pullRequestQuery)
        }
        .onChange(of: listContent) { _, _ in
            searchFocused = false
            isSearching = false
            revealedSwipeTarget = nil
        }
        .overlay {
            if !showsPullRequests, viewModel.filteredWorkspaces.isEmpty,
               !(viewModel.isLoading && viewModel.workspaces.isEmpty) {
                if viewModel.hasSearchQuery {
                    WorkspaceSearchEmptyState()
                } else {
                    emptyState
                }
            }
        }
    }

    private func prepareConnectionSwitcher() {
        searchFocused = false
        isSearching = false
        revealedSwipeTarget = nil
    }

    private var emptyState: some View {
        Button("New workspace", action: createWorkspace)
            .buttonStyle(IntentButtonStyle(variant: .muted))
            .disabled(!coordinator.canCreateWorkspace)
            .accessibilityIdentifier("workspaces.empty.create")
    }

    private func workspaceRows(
        _ workspaces: [Workspace],
        showRepo: Bool = true,
        usesVisionHitTarget: Bool = true
    ) -> some View {
        // Snapshot store state and bindings here, not in SwiftUI's async row provider.
        let rows = workspaces.enumerated().map { index, workspace in
            let nextId = index + 1 < workspaces.count ? workspaces[index + 1].id : nil
            let content = workspaceButton(workspace, nextWorkspaceId: nextId, showRepo: showRepo, usesVisionHitTarget: usesVisionHitTarget)
            return (id: workspace.id, content: content)
        }
        return ForEach(rows, id: \.id) { @Sendable row in row.content }
    }

    @ViewBuilder
    private func workspaceButton(
        _ workspace: Workspace,
        nextWorkspaceId: String?,
        showRepo: Bool = true,
        usesVisionHitTarget: Bool = true
    ) -> some View {
        if usesVisionHitTarget {
            workspaceButtonContent(workspace, nextWorkspaceId: nextWorkspaceId, showRepo: showRepo)
                .visionListRowHitTarget()
        } else {
            workspaceButtonContent(workspace, nextWorkspaceId: nextWorkspaceId, showRepo: showRepo)
        }
    }

    private func workspaceButtonContent(_ workspace: Workspace, nextWorkspaceId: String?, showRepo: Bool) -> some View {
        WorkspaceSwipeRow(
            workspace: workspace,
            showRepo: showRepo,
            isUpdating: workspaceStore.updatingWorkspaceIDs.contains(workspace.id),
            revealedTarget: $revealedSwipeTarget,
            workspaceSwipeProgress: $workspaceSwipeProgress,
            nextWorkspaceId: nextWorkspaceId
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
        .modifier(WorkspaceListDuoLeadingInset())
    }

    private var confirmationPresented: Binding<Bool> {
        Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    private func perform(_ pending: PendingAction) {
        Task {
            do {
                try await workspaceStore.perform(pending.action, workspaceId: pending.workspace.id)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private struct PendingAction {
        let workspace: Workspace
        let action: WorkspaceAction
    }
}

private struct WorkspaceListDuoLeadingInset: ViewModifier {
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar

    func body(content: Content) -> some View {
        if usesVerticalBar {
            content.padding(.leading, Constants.WorkspaceList.duoLeadingInset - Constants.WorkspaceList.pageInset)
        } else {
            content
        }
    }
}

private extension WorkspaceListView {
    var titleBottomSpacing: CGFloat {
        if isSearching { return Constants.WorkspaceList.searchTitleSpacing }
        return usesVerticalBar ? Constants.WorkspaceList.pageInset : Constants.WorkspaceList.titleBottomSpacing
    }

    var pageHeader: some View {
        let style = isSearching ? Constants.Typography.heading2 : Constants.Typography.heading1
        let face = legibilityWeight == .bold ? style.face.legibleFace : style.face
        let font = CTFontCreateWithName(face.rawValue as CFString, isSearching ? compactHeadingSize : headingSize, nil)
        return HStack {
            WorkspaceTextTrimLayout(capHeight: CTFontGetCapHeight(font)) {
                Text(showsPullRequests ? "Pull requests" : "Workspaces")
                    .interFont(style)
                    .tracking(isSearching ? compactHeadingTracking : headingTracking)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("workspaces.title")
                    .accessibilityAction(named: Text("Switch connection")) {
                        showingConnectionSwitcher = true
                    }
            }
            Spacer(minLength: 0)
            if isSearching, !usesVerticalBar { pageMenu } else if !usesVerticalBar {
                // Reserve the menu's width without inflating the cap-trimmed title height.
                Color.clear.frame(width: Constants.Accessibility.minimumTapTarget, height: 0)
            }
        }
        .overlay(alignment: .trailing) {
            if !isSearching, !usesVerticalBar { pageMenu }
        }
        .padding(.top, isSearching ? Constants.WorkspaceList.searchTitleSpacing : Constants.WorkspaceList.titleTopSpacing)
        .padding(.bottom, titleBottomSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Theme.foreground(for: colorScheme))
        .padding(.horizontal, Constants.WorkspaceList.pageInset)
        .modifier(WorkspaceListDuoLeadingInset())
    }

    func createWorkspace() {
        showingConnectionSwitcher = false
        if coordinator.canCreateWorkspace { showingCreateWorkspace = true }
    }

    var pageMenu: some View {
        WorkspaceListMenu(
            showArchived: $viewModel.showArchived,
            canCreateWorkspace: coordinator.canCreateWorkspace,
            onCreateWorkspace: createWorkspace,
            onRecentAgents: {
                prepareConnectionSwitcher()
                openAgentHistory()
            },
            onRecentConnections: {
                prepareConnectionSwitcher()
                showingConnectionSwitcher = true
            },
            content: $listContent,
            showsClosedPullRequests: $showsClosedPullRequests,
            groupsPullRequestsByProject: $groupsPullRequestsByProject
        )
    }

    var showsPullRequests: Bool { listContent == .pullRequests }

    var pullRequestQuery: PullRequestListStore.Query {
        PullRequestListStore.Query(
            repositories: PullRequestListRepository.scope(viewModel.workspaces),
            filter: pullRequestFilter,
            showsClosed: showsClosedPullRequests,
            text: pullRequestSearchText
        )
    }

    @ViewBuilder var filterBar: some View {
        if showsPullRequests {
            WorkspaceSearchBar(
                viewMode: $pullRequestFilter,
                isSearching: $isSearching,
                horizontalPadding: Constants.WorkspaceList.pageInset,
                isCompact: isFilterPinned,
                identifierPrefix: "pullRequests.filter",
                accessibilityTitle: "Pull request filter",
                searchLabel: "Search pull requests"
            )
        } else {
            WorkspaceSearchBar(
                viewMode: $viewModel.viewMode,
                isSearching: $isSearching,
                horizontalPadding: Constants.WorkspaceList.pageInset,
                isCompact: isFilterPinned
            )
        }
    }

    @ViewBuilder var searchInput: some View {
        if showsPullRequests {
            WorkspaceSearchInput(
                text: $pullRequestSearchText,
                isSearching: $isSearching,
                isFocused: $searchFocused,
                placeholder: "Search pull requests",
                identifierPrefix: "pullRequests.search"
            )
        } else {
            WorkspaceSearchInput(text: $viewModel.searchText, isSearching: $isSearching, isFocused: $searchFocused)
        }
    }
}

private extension WorkspaceListView {
    @ViewBuilder var workspaceContent: some View {
        if showsPullRequests {
            PullRequestListContent(
                store: session.pullRequestListStore,
                query: pullRequestQuery,
                workspaces: viewModel.workspaces,
                groupsByProject: groupsPullRequestsByProject
            ) { workspaceId in
                searchFocused = false
                coordinator.onSelectWorkspace(workspaceId)
            } onOpenDetail: { item in
                searchFocused = false
                detailPullRequest = item
            } onOpenAgent: { workspaceId in
                searchFocused = false
                coordinator.onOpenRecentWorkspaceAgent(workspaceId)
            } onCreateWorkspace: { item in
                searchFocused = false
                if coordinator.canCreateWorkspace { creationPullRequest = item }
            }
        } else if viewModel.isLoading, viewModel.workspaces.isEmpty {
            ProgressView {
                Text("Loading workspaces...").interFont(Constants.Typography.bodyS)
            }
            .frame(maxWidth: .infinity, minHeight: Constants.WorkspaceList.emptyStateHeight)
        } else if !viewModel.filteredWorkspaces.isEmpty {
            workspaceSections
        }
    }

    @ViewBuilder
    var workspaceSections: some View {
        switch viewModel.viewMode {
        case .recent:
            if !isSearching {
                Color.clear
                    .frame(height: Constants.WorkspaceList.recentTopSpacing)
                    .accessibilityHidden(true)
            }
            workspaceRows(viewModel.filteredWorkspaces)
        case .repo:
            groupSections(viewModel.groupedByRepo, mode: .repo) { workspaceRows($0, showRepo: false) }
        case .status:
            groupSections(viewModel.groupedByStatus, mode: .status) { workspaceRows($0, usesVisionHitTarget: false) }
        }
    }

    func groupSections<Rows: View>(
        _ grouped: [(String, [Workspace])],
        mode: ViewMode,
        @ViewBuilder rows: ([Workspace]) -> Rows
    ) -> some View {
        let groups = grouped.map { title, workspaces in
            let isExpanded = viewModel.isGroupExpanded(title, in: mode)
            let heading = WorkspaceListGroupHeading(
                title: title, mode: mode, isExpanded: isExpanded, isToggleEnabled: !viewModel.hasSearchQuery
            ) { viewModel.toggleGroup(title, in: mode) }
            return (id: title, heading: heading.modifier(WorkspaceListDuoLeadingInset()),
                    isExpanded: isExpanded, rows: rows(workspaces))
        }
        return ForEach(groups, id: \.id) { @Sendable group in
            group.heading
            if group.isExpanded { group.rows }
        }
    }
}
