import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing

@Suite @MainActor
struct WorkspaceListCacheTests {
    private func workspace(_ id: String, _ fields: [String: Any] = [:]) throws -> Workspace {
        var wire: [String: Any] = ["id": id, "title": id]
        wire.merge(fields) { _, replacement in replacement }
        return try #require(WorkspaceStore.parseWorkspace(wire))
    }

    private func sharesStorage<Element>(_ lhs: [Element], _ rhs: [Element]) -> Bool {
        lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in
                left.baseAddress == right.baseAddress && left.count == right.count
            }
        }
    }

    @Test func unchangedReadsReuseListsGroupsAndParsedTimes() throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = try [
            workspace("older", ["lastActivity": "2026-01-01T00:00:00Z", "repositoryName": "app"]),
            workspace("newer", ["lastActivity": "2026-02-01T00:00:00Z", "repositoryName": "lib"])
        ]
        var parsedIDs: [String] = []
        let model = WorkspaceListViewModel(workspaceStore: store) { workspace in
            parsedIDs.append(workspace.id)
            return workspaceActivityDisplayTime(workspace)
        }
        let filtered = model.filteredWorkspaces
        let repos = model.groupedByRepo
        let statuses = model.groupedByStatus
        #expect(filtered.map(\.id) == ["newer", "older"])

        store.isLoading = true
        model.searchText = " \n "
        for mode in ViewMode.allCases {
            model.viewMode = mode
            #expect(sharesStorage(filtered, model.filteredWorkspaces))
            #expect(sharesStorage(repos, model.groupedByRepo))
            #expect(sharesStorage(statuses, model.groupedByStatus))
        }
        #expect(parsedIDs == ["older", "newer"])
    }

    @Test func searchChangesReuseSortedTimesAndUpdateEveryGrouping() throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = try [
            workspace("older", ["title": "Alpha", "repositoryName": "app", "displayStatus": "idle"]),
            workspace("newer", ["title": "Beta", "repositoryName": "lib", "displayStatus": "in_progress"])
        ]
        var parseCount = 0
        let model = WorkspaceListViewModel(workspaceStore: store) { workspace in
            parseCount += 1
            return workspaceActivityDisplayTime(workspace)
        }
        let initial = model.filteredWorkspaces
        model.searchText = "  ALPHA  "
        #expect(model.filteredWorkspaces.map(\.id) == ["older"])
        #expect(model.groupedByRepo.map(\.0) == ["app"])
        #expect(model.groupedByStatus.map(\.0) == ["Idle"])
        model.searchText = "missing"
        #expect(model.filteredWorkspaces.isEmpty)
        #expect(model.groupedByRepo.isEmpty)
        #expect(model.groupedByStatus.isEmpty)
        model.searchText = ""
        #expect(model.filteredWorkspaces == initial)
        #expect(parseCount == store.workspaces.count)
    }

    @Test func activityPatchReparsesOnlyChangedWorkspaceAndReordersGroups() throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = try [
            workspace("older", ["lastActivity": "2026-01-01T00:00:00Z", "repositoryName": "app"]),
            workspace("newer", ["lastActivity": "2026-02-01T00:00:00Z", "repositoryName": "lib"])
        ]
        var parsedIDs: [String] = []
        let model = WorkspaceListViewModel(workspaceStore: store) { workspace in
            parsedIDs.append(workspace.id)
            return workspaceActivityDisplayTime(workspace)
        }
        #expect(model.groupedByRepo.map(\.0) == ["lib", "app"])
        store.updateLastActivity(workspaceId: "older", lastActivity: "2026-03-01T00:00:00.500Z")
        #expect(model.filteredWorkspaces.map(\.id) == ["older", "newer"])
        #expect(model.groupedByRepo.map(\.0) == ["app", "lib"])
        #expect(model.groupedByStatus.first?.1.map(\.id) == ["older", "newer"])
        #expect(parsedIDs == ["older", "newer", "older"])
    }

    @Test func sameIDReplacementRefreshesMetadataWithoutReparsing() throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = try [workspace("same", ["title": "Before", "repositoryName": "app"])]
        var parseCount = 0
        let model = WorkspaceListViewModel(workspaceStore: store) { workspace in
            parseCount += 1
            return workspaceActivityDisplayTime(workspace)
        }
        #expect(model.filteredWorkspaces.first?.title == "Before")
        let replacement = try workspace("same", [
            "title": "After",
            "branch": "feature/cache",
            "repositoryOwner": "acme",
            "repositoryName": "lib",
            "displayStatus": "needs_attention",
            "attention": "unread",
            "waiting": true,
            "statusMessage": "Review ready",
            "statusImageAssetId": "image-1",
            "taskStats": ["total": 2, "completed": 1]
        ])
        store.addOrUpdate(replacement)
        #expect(model.filteredWorkspaces == [replacement])
        #expect(model.groupedByRepo.map(\.0) == ["acme/lib"])
        #expect(model.groupedByRepo.first?.1 == [replacement])
        #expect(model.groupedByStatus.map(\.0) == ["Needs Attention"])
        #expect(model.groupedByStatus.first?.1 == [replacement])
        model.searchText = "Before"
        #expect(model.filteredWorkspaces.isEmpty)
        model.searchText = "feature/cache"
        #expect(model.filteredWorkspaces == [replacement])
        #expect(parseCount == 1)
    }

    @Test func statusChangesDeletionAndInsertionInvalidateWarmResults() throws {
        let store = WorkspaceStore(forTesting: true)
        let active = try workspace("active", ["repositoryName": "app"])
        store.workspaces = [active]
        var parseCount = 0
        let model = WorkspaceListViewModel(workspaceStore: store) { workspace in
            parseCount += 1
            return workspaceActivityDisplayTime(workspace)
        }
        #expect(model.groupedByRepo.first?.1 == [active])
        for status in ["Archived", "DELETED"] {
            store.workspaces[0] = try workspace("active", ["status": status])
            #expect(model.filteredWorkspaces.isEmpty)
            #expect(model.groupedByRepo.isEmpty)
            #expect(model.groupedByStatus.isEmpty)
            store.workspaces[0] = active
            #expect(model.filteredWorkspaces == [active])
        }
        let beforeRemoval = parseCount
        store.workspaces.removeAll()
        #expect(model.filteredWorkspaces.isEmpty)
        #expect(model.groupedByRepo.isEmpty)
        #expect(model.groupedByStatus.isEmpty)
        store.workspaces.append(active)
        #expect(model.groupedByRepo.first?.1 == [active])
        #expect(model.groupedByStatus.first?.1 == [active])
        // Re-adding the same ID resolves its time again: removed entries were evicted.
        #expect(parseCount == beforeRemoval + 1)
    }

    @Test func fallbackTimestampChangesAndFractionalTiesKeepExistingOrder() throws {
        let store = WorkspaceStore(forTesting: true)
        let epoch = "1970-01-01T00:00:00Z"
        let earlier = "1969-12-31T23:59:59Z"
        store.workspaces = try [
            workspace("created", ["lastActivity": epoch, "createdAt": "2026-01-01T00:00:00.500Z", "repositoryName": "zeta"]),
            workspace("updated", ["lastActivity": earlier, "createdAt": "bad", "updatedAt": "2026-01-01T00:00:00.500Z", "repositoryName": "alpha"]),
            workspace("whole", ["lastActivity": "2026-01-01T00:00:00Z"])
        ]
        let model = WorkspaceListViewModel(workspaceStore: store)
        #expect(model.filteredWorkspaces.map(\.id) == ["created", "updated", "whole"])
        #expect(model.groupedByRepo.map(\.0) == ["zeta", "alpha", "Unknown"])
        store.workspaces[0] = try workspace("created", ["lastActivity": epoch, "createdAt": "2025-01-01T00:00:00Z"])
        #expect(model.filteredWorkspaces.map(\.id) == ["updated", "whole", "created"])
        store.workspaces[1] = try workspace("updated", ["createdAt": "bad", "updatedAt": "2024-01-01T00:00:00Z"])
        #expect(model.filteredWorkspaces.map(\.id) == ["whole", "created", "updated"])
        store.workspaces[2] = try workspace("whole", ["lastActivity": "invalid"])
        #expect(model.filteredWorkspaces.map(\.id) == ["created", "updated", "whole"])
    }

    @Test func warmCacheReadsStillObserveStoreAndSearchChanges() throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = try [workspace("first")]
        let model = WorkspaceListViewModel(workspaceStore: store)
        let readers: [() -> Void] = [
            { _ = model.filteredWorkspaces },
            { _ = model.groupedByRepo },
            { _ = model.groupedByStatus }
        ]
        for read in readers {
            read()
            let storeChanges = Mutex(0)
            withObservationTracking(read) {
                storeChanges.withLock { $0 += 1 }
            }
            store.workspaces.append(try workspace(UUID().uuidString))
            #expect(storeChanges.withLock { $0 } == 1)

            read()
            let searchChanges = Mutex(0)
            withObservationTracking(read) {
                searchChanges.withLock { $0 += 1 }
            }
            model.searchText += "first"
            #expect(searchChanges.withLock { $0 } == 1)
        }
    }

    @Test func coldCacheReadObservesSubsequentSnapshotAndLiveMetadataPatches() throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = try [workspace("same")]
        let model = WorkspaceListViewModel(workspaceStore: store)
        let changes = Mutex(0)
        withObservationTracking {
            _ = model.groupedByStatus
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        #expect(changes.withLock { $0 } == 0)
        let replacement = try workspace("same", ["title": "Refreshed", "attention": "unread"])
        store.publishFetchedWorkspaces([replacement])
        #expect(changes.withLock { $0 } == 1)
        #expect(model.groupedByStatus.first?.1 == [replacement])
        store.updateWaiting(workspaceId: "same", waiting: true)
        #expect(model.filteredWorkspaces.first?.waiting == true)
        store.clearUnreadAttentionLocally(workspaceId: "same")
        #expect(model.filteredWorkspaces.first?.attention == "none")
    }

    @Test func cachesStayBoundToTheirBackendStore() throws {
        let firstStore = WorkspaceStore(forTesting: true)
        let secondStore = WorkspaceStore(forTesting: true)
        firstStore.workspaces = try [workspace("same", ["title": "First backend"])]
        secondStore.workspaces = try [workspace("same", ["title": "Second backend"])]
        let first = WorkspaceListViewModel(workspaceStore: firstStore)
        let second = WorkspaceListViewModel(workspaceStore: secondStore)
        #expect(first.filteredWorkspaces.first?.title == "First backend")
        #expect(second.filteredWorkspaces.first?.title == "Second backend")
        firstStore.workspaces.removeAll()
        #expect(first.filteredWorkspaces.isEmpty)
        #expect(second.filteredWorkspaces.first?.title == "Second backend")
    }
}
