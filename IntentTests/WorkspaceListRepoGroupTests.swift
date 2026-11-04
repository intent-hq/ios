import Foundation
@testable import Intent
import Testing

@Suite(.serialized)
struct WorkspaceListRepoGroupTests {
    @Test @MainActor func repoGroupsDefaultExpandedAndToggleCollapsedState() throws {
        let suiteName = "WorkspaceListRepoGroupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
        let model = WorkspaceListViewModel(workspaceStore: WorkspaceStore(forTesting: true), persistence: persistence)

        #expect(model.isRepoGroupExpanded("acme/app"))
        #expect(defaults.object(forKey: "workspaceListCollapsedRepoGroups") == nil)

        model.toggleRepoGroup("acme/app")
        #expect(!model.isRepoGroupExpanded("acme/app"))
        #expect(model.isRepoGroupExpanded("acme/lib"))
        #expect(defaults.stringArray(forKey: "workspaceListCollapsedRepoGroups") == ["acme/app"])

        model.toggleRepoGroup("acme/app")
        #expect(model.isRepoGroupExpanded("acme/app"))
        #expect(defaults.object(forKey: "workspaceListCollapsedRepoGroups") == nil)
    }

    @Test @MainActor func collapsedRepoGroupsRestoreWithNewPersistenceInstance() throws {
        let suiteName = "WorkspaceListRepoGroupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
        let model = WorkspaceListViewModel(workspaceStore: WorkspaceStore(forTesting: true), persistence: persistence)
        model.toggleRepoGroup("zeta/late")
        model.toggleRepoGroup("Unknown")

        let restoredDefaults = try #require(UserDefaults(suiteName: suiteName))
        let restoredPersistence = PersistenceManager(defaults: restoredDefaults, keychainStorage: InMemoryKeychainStorage())
        let restored = WorkspaceListViewModel(workspaceStore: WorkspaceStore(forTesting: true), persistence: restoredPersistence)
        #expect(restored.collapsedRepoGroups == ["zeta/late", "Unknown"])
        #expect(!restored.isRepoGroupExpanded("zeta/late"))
        #expect(restored.isRepoGroupExpanded("acme/app"))
    }

    @Test @MainActor func searchForcesRepoGroupsExpandedWithoutForgettingCollapse() throws {
        let suiteName = "WorkspaceListRepoGroupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
        let model = WorkspaceListViewModel(workspaceStore: WorkspaceStore(forTesting: true), persistence: persistence)
        model.toggleRepoGroup("acme/app")

        model.searchText = "  dashboard "
        #expect(model.isRepoGroupExpanded("acme/app"))
        model.toggleRepoGroup("acme/app")
        model.toggleRepoGroup("acme/lib")
        #expect(model.collapsedRepoGroups == ["acme/app"], "Toggling is disabled while searching")

        model.searchText = "   "
        #expect(!model.isRepoGroupExpanded("acme/app"))
        model.searchText = ""
        #expect(!model.isRepoGroupExpanded("acme/app"))
    }
}
