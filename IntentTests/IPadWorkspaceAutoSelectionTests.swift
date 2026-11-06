import Foundation
@testable import Intent
import Testing

/// SHELL-5: a wide iPad window opens the workspace in the top visible row of
/// the user's list, from one decision and one trigger.
@MainActor
struct IPadWorkspaceAutoSelectionTests {
    /// Flat order: chief, archived, a, b, c. Status order puts failed (b, c) first.
    private static let workspaces = [
        makeWorkspace(id: Workspace.chiefWorkspaceId, repo: "assistant", display: "idle", day: 9),
        makeWorkspace(id: "archived", repo: "zero", display: "blocked", day: 8, status: "archived"),
        makeWorkspace(id: "a", repo: "one", display: "in_progress", day: 5),
        makeWorkspace(id: "b", repo: "two", display: "failed", day: 4),
        makeWorkspace(id: "c", repo: "one", display: "failed", day: 3, title: "Needle"),
        makeWorkspace(id: "deleted", repo: "one", display: "failed", day: 7, status: "deleted")
    ]

    private static func makeWorkspace(
        id: String,
        repo: String,
        display: String,
        day: Int,
        title: String? = nil,
        status: String? = nil
    ) -> Workspace {
        Workspace(
            id: id,
            title: title ?? "WS \(id)",
            branch: nil,
            baseRef: nil,
            status: status,
            activity: nil,
            displayStatus: display,
            lastActivity: String(format: "2026-01-%02dT00:00:00Z", day),
            createdAt: nil,
            updatedAt: nil,
            repositoryOwner: "intent",
            repositoryName: repo,
            prStatus: nil,
            prNumber: nil,
            diffSummaryTotalFiles: nil,
            taskStatsTotal: nil,
            taskStatsCompleted: nil,
            taskStatsInProgress: nil,
            agentSummaryCount: nil
        )
    }

    private static var wideNavigation: IPadNavigationState {
        var navigation = IPadNavigationState()
        navigation.updateLayout(usesOverlay: false)
        return navigation
    }

    private static func choice(
        _ presentation: WorkspaceListPresentation = WorkspaceListPresentation(),
        workspaces: [Workspace] = workspaces,
        includeArchived: Bool = false,
        navigation: IPadNavigationState = wideNavigation,
        screen: AppScreen = .workspaceList,
        usesIPadShell: Bool = true
    ) -> String? {
        IPadWorkspaceAutoSelection(
            usesIPadShell: usesIPadShell,
            navigation: navigation,
            screen: screen,
            includeArchived: includeArchived,
            presentation: presentation
        ).workspaceId(in: workspaces)
    }

    @Test func picksTheTopVisibleRowForEachListSetting() {
        #expect(Self.choice(WorkspaceListPresentation(viewMode: .recent)) == "a")
        #expect(Self.choice(WorkspaceListPresentation(viewMode: .repo)) == "a")
        #expect(Self.choice(WorkspaceListPresentation(viewMode: .status)) == "b", "Failed sorts before In Progress")
        #expect(Self.choice(WorkspaceListPresentation(viewMode: .repo, collapsedGroups: [.repo: ["intent/one"]])) == "b")
        #expect(Self.choice(WorkspaceListPresentation(viewMode: .status, collapsedGroups: [.status: ["Failed"]])) == "a")
        #expect(Self.choice(WorkspaceListPresentation(viewMode: .recent), includeArchived: true) == "archived")
        #expect(Self.choice(WorkspaceListPresentation(viewMode: .recent, searchText: "  needle ")) == "c")
        let searchOpensCollapsed = WorkspaceListPresentation(viewMode: .repo, collapsedGroups: [.repo: ["intent/one"]], searchText: "needle")
        #expect(Self.choice(searchOpensCollapsed) == "c", "Searching expands every group")
        #expect(Self.choice(WorkspaceListPresentation(searchText: "no match")) == nil)
        #expect(Self.choice(workspaces: []) == nil)
        #expect(Self.choice(workspaces: [Self.workspaces[0]]) == nil, "The Assistant's workspace is never a row")
    }

    @Test func onlyAWideWorkspaceListAutoSelects() {
        #expect(Self.choice(usesIPadShell: false) == nil)
        #expect(Self.choice(navigation: IPadNavigationState()) == nil, "Unmeasured layout")
        var compact = IPadNavigationState()
        compact.updateLayout(usesOverlay: true, usesCompactNavigation: true, showsWorkspaceList: true)
        #expect(Self.choice(navigation: compact) == nil)
        var overlay = IPadNavigationState()
        overlay.updateLayout(usesOverlay: true)
        #expect(Self.choice(navigation: overlay) == "a")
        var assistant = Self.wideNavigation
        assistant.selectSection(.assistant)
        #expect(Self.choice(navigation: assistant) == nil)
        var pairing = Self.wideNavigation
        pairing.presentPairing(.qrCode)
        #expect(Self.choice(navigation: pairing) == nil)
        #expect(Self.choice(screen: .workspaceDetail(workspaceId: "b")) == nil)
    }

    /// The sidebar renders from the view model's groups; the decision must agree with them.
    @Test(arguments: ViewMode.allCases)
    func matchesTheRowTheSidebarRendersFirst(_ mode: ViewMode) throws {
        let suiteName = "IPadWorkspaceAutoSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = Self.workspaces.filter { $0.id != Workspace.chiefWorkspaceId }
        let model = WorkspaceListViewModel(workspaceStore: store, persistence: persistence)
        model.viewMode = mode
        for showArchived in [false, true] {
            model.showArchived = showArchived
            let rendered: Workspace?
            switch mode {
            case .recent: rendered = model.filteredWorkspaces.first
            case .repo: rendered = model.groupedByRepo.first { model.isGroupExpanded($0.0, in: .repo) }?.1.first
            case .status: rendered = model.groupedByStatus.first { model.isGroupExpanded($0.0, in: .status) }?.1.first
            }
            let chosen = Self.choice(model.presentation, workspaces: store.workspaces, includeArchived: showArchived)
            #expect(chosen == rendered?.id)
        }
    }

    @Test func coordinatorSelectsFromItsOneObserverWithInjectedListSettings() async throws {
        let suiteName = "IPadWorkspaceAutoSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
        persistence.saveWorkspaceListViewMode(.status)
        let store = WorkspaceStore(forTesting: true)
        let coordinator = AppCoordinator(workspaceStore: store, connection: FakeConnectionManager(), persistence: persistence)
        #expect(coordinator.workspaceListPresentation.viewMode == .status)
        coordinator.usesIPadShell = true
        coordinator.currentScreen = .workspaceList
        store.workspaces = Self.workspaces
        try await expectNever("selection before the layout is measured") { coordinator.selectedWorkspaceId != nil }
        coordinator.iPadNavigation.updateLayout(usesOverlay: false)
        try await waitUntil("the top Status row opens") { coordinator.selectedWorkspaceId == "b" }
        coordinator.onSelectAgent("agent", workspaceId: "b", agentName: "Agent")
        coordinator.workspaceListPresentation.viewMode = .recent
        coordinator.onSelectIPadSection(.assistant)
        coordinator.onSelectIPadSection(.workspaces)
        try await expectNever("a jump to the new top row while a workspace is open") {
            coordinator.selectedWorkspaceId != "b"
        }
    }

    @Test func compactCoordinatorStaysOnTheList() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = Self.workspaces
        let suiteName = "IPadWorkspaceAutoSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
        let coordinator = AppCoordinator(workspaceStore: store, connection: FakeConnectionManager(), persistence: persistence)
        coordinator.usesIPadShell = true
        coordinator.currentScreen = .workspaceList
        coordinator.iPadNavigation.updateLayout(usesOverlay: true, usesCompactNavigation: true, showsWorkspaceList: true)
        try await expectNever("a compact window leaving the list") { coordinator.selectedWorkspaceId != nil }
        coordinator.iPadNavigation.updateLayout(usesOverlay: false)
        try await waitUntil("widening opens the top row") { coordinator.selectedWorkspaceId == "a" }
    }
}
