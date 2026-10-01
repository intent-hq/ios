import CoreText
import SwiftUI

struct WorkspaceListView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) private var session
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.legibilityWeight) private var legibilityWeight
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
        return !showingConnections && !showingCreateWorkspace && pendingAction == nil && actionError == nil
    }

    var body: some View {
        WorkspaceConnectionSwitcher(
            isPresented: $showingConnectionSwitcher,
            isEnabled: canSwitchConnections,
            onReveal: prepareConnectionSwitcher
        ) {
            workspacePage
        }
        .modifier(WorkspaceActionLauncher(
            isSearching: isSearching,
            onCreateWorkspace: {
                showingConnectionSwitcher = false
                if coordinator.canCreateWorkspace { showingCreateWorkspace = true }
            },
            onConnections: {
                showingConnectionSwitcher = false
                showingConnections = true
            }
        ))
        .navigationTitle("Workspaces")
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: coordinator.shouldDismissWorkspaceCreation) { _, shouldDismiss in
            if shouldDismiss { showingCreateWorkspace = false }
        }
        .sheet(isPresented: $showingCreateWorkspace) {
            CreateWorkspaceView(session: session)
                .environment(coordinator)
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
                        WorkspaceSearchBar(
                            viewMode: $viewModel.viewMode,
                            isSearching: $isSearching,
                            horizontalPadding: Constants.WorkspaceList.pageInset,
                            isCompact: isFilterPinned
                        )
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
                WorkspaceSearchInput(text: $viewModel.searchText, isSearching: $isSearching, isFocused: $searchFocused)
                    .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .refreshable {
            await workspaceStore.fetchAll()
        }
    }

    private func prepareConnectionSwitcher() {
        searchFocused = false
        isSearching = false
        revealedSwipeTarget = nil
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

    private var pageHeader: some View {
        let style = isSearching ? Constants.Typography.heading2 : Constants.Typography.heading1
        let face = legibilityWeight == .bold ? style.face.legibleFace : style.face
        let font = CTFontCreateWithName(face.rawValue as CFString, isSearching ? compactHeadingSize : headingSize, nil)
        return WorkspaceTextTrimLayout(capHeight: CTFontGetCapHeight(font)) {
            Text("Workspaces")
                .interFont(style)
                .tracking(isSearching ? compactHeadingTracking : headingTracking)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("workspaces.title")
                .accessibilityAction(named: Text("Switch connection")) {
                    showingConnectionSwitcher = true
                }
        }
        .padding(.top, isSearching ? Constants.WorkspaceList.searchTitleSpacing : Constants.WorkspaceList.titleTopSpacing)
        .padding(.bottom, isSearching ? Constants.WorkspaceList.searchTitleSpacing : Constants.WorkspaceList.titleBottomSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Theme.foreground(for: colorScheme))
        .padding(.horizontal, Constants.WorkspaceList.pageInset)
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if viewModel.isLoading, viewModel.workspaces.isEmpty {
            ProgressView {
                Text("Loading workspaces...").interFont(Constants.Typography.bodyS)
            }
            .frame(maxWidth: .infinity, minHeight: Constants.WorkspaceList.emptyStateHeight)
        } else if viewModel.filteredWorkspaces.isEmpty {
            if viewModel.hasSearchQuery {
                ContentUnavailableView.search
            } else {
                emptyState
            }
        } else {
            workspaceSections
        }
    }

    @ViewBuilder
    private var workspaceSections: some View {
        switch viewModel.viewMode {
        case .recent:
            if !isSearching {
                Color.clear
                    .frame(height: Constants.WorkspaceList.recentTopSpacing)
                    .accessibilityHidden(true)
            }
            workspaceRows(viewModel.filteredWorkspaces)
        case .repo:
            ForEach(viewModel.groupedByRepo, id: \.0) { repoName, workspaces in
                groupHeading(repoName)
                workspaceRows(workspaces, showRepo: false)
            }
        case .status:
            ForEach(viewModel.groupedByStatus, id: \.0) { statusLabel, workspaces in
                groupHeading(statusLabel)
                workspaceRows(workspaces, usesVisionHitTarget: false)
            }
        }
    }

    private func workspaceRows(
        _ workspaces: [Workspace],
        showRepo: Bool = true,
        usesVisionHitTarget: Bool = true
    ) -> some View {
        ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, workspace in
            let nextId = index + 1 < workspaces.count ? workspaces[index + 1].id : nil
            workspaceButton(workspace, nextWorkspaceId: nextId, showRepo: showRepo, usesVisionHitTarget: usesVisionHitTarget)
        }
    }

    private func groupHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .interFont(Constants.Typography.eyebrow)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Constants.WorkspaceList.groupTopSpacing)
            .padding(.bottom, Constants.WorkspaceList.groupBottomSpacing)
            .padding(.horizontal, Constants.WorkspaceList.pageInset)
            .accessibilityAddTraits(.isHeader)
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
        } onAction: { action in
            searchFocused = false
            pendingAction = PendingAction(workspace: workspace, action: action)
        }
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
