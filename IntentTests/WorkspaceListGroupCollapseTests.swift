import Foundation
@testable import Intent
import Testing

@Suite(.serialized)
struct WorkspaceListGroupCollapseTests {
    @Test @MainActor func repoGroupsDefaultExpandedAndToggleCollapsedState() throws {
        let suiteName = "WorkspaceListGroupCollapseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
        let model = WorkspaceListViewModel(workspaceStore: WorkspaceStore(forTesting: true), persistence: persistence)

        #expect(model.isGroupExpanded("acme/app", in: .repo))
        #expect(defaults.object(forKey: "workspaceListCollapsedRepoGroups") == nil)

        model.toggleGroup("acme/app", in: .repo)
        #expect(!model.isGroupExpanded("acme/app", in: .repo))
        #expect(model.isGroupExpanded("acme/lib", in: .repo))
        #expect(defaults.stringArray(forKey: "workspaceListCollapsedRepoGroups") == ["acme/app"])

        model.toggleGroup("acme/app", in: .repo)
        #expect(model.isGroupExpanded("acme/app", in: .repo))
        #expect(defaults.object(forKey: "workspaceListCollapsedRepoGroups") == nil)
    }

    @Test @MainActor func collapsedRepoGroupsRestoreWithNewPersistenceInstance() throws {
        let suiteName = "WorkspaceListGroupCollapseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
        let model = WorkspaceListViewModel(workspaceStore: WorkspaceStore(forTesting: true), persistence: persistence)
        model.toggleGroup("zeta/late", in: .repo)
        model.toggleGroup("Unknown", in: .repo)

        let restoredDefaults = try #require(UserDefaults(suiteName: suiteName))
        let restoredPersistence = PersistenceManager(defaults: restoredDefaults, keychainStorage: InMemoryKeychainStorage())
        let restored = WorkspaceListViewModel(workspaceStore: WorkspaceStore(forTesting: true), persistence: restoredPersistence)
        #expect(restored.collapsedGroups[.repo] == ["zeta/late", "Unknown"])
        #expect(!restored.isGroupExpanded("zeta/late", in: .repo))
        #expect(restored.isGroupExpanded("acme/app", in: .repo))
    }

    @Test @MainActor func searchForcesRepoGroupsExpandedWithoutForgettingCollapse() throws {
        let suiteName = "WorkspaceListGroupCollapseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
        let model = WorkspaceListViewModel(workspaceStore: WorkspaceStore(forTesting: true), persistence: persistence)
        model.toggleGroup("acme/app", in: .repo)

        model.searchText = "  dashboard "
        #expect(model.isGroupExpanded("acme/app", in: .repo))
        model.toggleGroup("acme/app", in: .repo)
        model.toggleGroup("acme/lib", in: .repo)
        #expect(model.collapsedGroups[.repo] == ["acme/app"], "Toggling is disabled while searching")

        model.searchText = "   "
        #expect(!model.isGroupExpanded("acme/app", in: .repo))
        model.searchText = ""
        #expect(!model.isGroupExpanded("acme/app", in: .repo))
    }

    @Test @MainActor func statusAndRepoGroupsCollapseIndependently() throws {
        let suiteName = "WorkspaceListGroupCollapseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
        let model = WorkspaceListViewModel(workspaceStore: WorkspaceStore(forTesting: true), persistence: persistence)

        model.toggleGroup("Unknown", in: .status)
        #expect(!model.isGroupExpanded("Unknown", in: .status))
        #expect(model.isGroupExpanded("Unknown", in: .repo), "A status label never collapses a same-named repo group")
        #expect(defaults.stringArray(forKey: "workspaceListCollapsedStatusGroups") == ["Unknown"])
        #expect(defaults.object(forKey: "workspaceListCollapsedRepoGroups") == nil)

        let restored = WorkspaceListViewModel(workspaceStore: WorkspaceStore(forTesting: true), persistence: persistence)
        #expect(!restored.isGroupExpanded("Unknown", in: .status))
    }
}
