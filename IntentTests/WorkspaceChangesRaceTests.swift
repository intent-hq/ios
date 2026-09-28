import Foundation
@testable import Intent
import Testing

extension WorkspaceChangesStoreTests {
    @Test func oldWorkspaceResponseCannotOverwriteNewWorkspace() async throws {
        let fake = makeFake()
        fake.pendingMethods.insert("file-tracking.getChanges")
        let store = WorkspaceChangesStore(connectionManager: fake)
        let oldRequest = Task { await store.refresh(workspaceId: "old-workspace") }
        try await fake.waitForPendingRequests("file-tracking.getChanges")

        fake.pendingMethods.remove("file-tracking.getChanges")
        fake.responseMap["file-tracking.getChanges"] = WorkspaceChangesFixture.snapshot([
            WorkspaceChangesFixture.change(id: "current-file")
        ])
        await store.refresh(workspaceId: "new-workspace")
        fake.resolvePending("file-tracking.getChanges", with: WorkspaceChangesFixture.snapshot([
            WorkspaceChangesFixture.change(id: "stale-file")
        ]))
        await oldRequest.value

        #expect(store.unstagedChanges.map(\.id) == ["current-file"])
        #expect(fake.paramsForMethod("file-tracking.loadCommits").count == 1)
        #expect(store.isLoading == false)
    }

    @Test func cancelledRefreshCannotPublishLateSuccess() async throws {
        let fake = makeFake()
        fake.pendingMethods.insert("file-tracking.loadCommits")
        let store = WorkspaceChangesStore(connectionManager: fake)
        let refresh = Task { await store.refresh(workspaceId: "workspace-1") }
        try await fake.waitForPendingRequests("file-tracking.loadCommits")

        refresh.cancel()
        fake.resolvePending("file-tracking.loadCommits", with: WorkspaceChangesFixture.page(["late"]))
        await refresh.value
        #expect(store.commits.isEmpty)
        #expect(store.hasLoaded == false)
        #expect(store.isLoading == false)
        #expect(store.errorMessage == nil)
    }

    @Test func newerRefreshWinsWhenEarlierRefreshFailsLate() async throws {
        let fake = makeFake()
        fake.pendingMethods.insert("file-tracking.getChanges")
        let store = WorkspaceChangesStore(connectionManager: fake)
        let earlier = Task { await store.refresh(workspaceId: "workspace-1") }
        try await fake.waitForPendingRequests("file-tracking.getChanges")

        fake.pendingMethods.remove("file-tracking.getChanges")
        fake.responseMap["file-tracking.loadCommits"] = WorkspaceChangesFixture.page(["current"])
        await store.refresh(workspaceId: "workspace-1")
        fake.failPending("file-tracking.getChanges", with: URLError(.timedOut))
        await earlier.value

        #expect(store.commits.map(\.hash) == ["current"])
        #expect(store.errorMessage == nil)
        #expect(store.isLoading == false)
    }

    @Test func refreshInvalidatesAnInFlightPageAndKeepsPaginationSingleFlight() async throws {
        let fake = makeFake()
        fake.responseMap["file-tracking.loadCommits"] = WorkspaceChangesFixture.page(["old"], nextToken: "page-2")
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        fake.pendingMethods.insert("file-tracking.loadCommits")
        let page = Task { await store.loadMoreCommits() }
        try await fake.waitForPendingRequests("file-tracking.loadCommits")
        await store.loadMoreCommits()
        #expect(fake.pendingRequestCount("file-tracking.loadCommits") == 1)

        fake.pendingMethods.remove("file-tracking.loadCommits")
        fake.responseMap["file-tracking.loadCommits"] = WorkspaceChangesFixture.page(["current"])
        await store.refresh(workspaceId: "workspace-1")
        fake.resolvePending("file-tracking.loadCommits", with: WorkspaceChangesFixture.page(["stale-page"]))
        await page.value

        #expect(store.commits.map(\.hash) == ["current"])
        #expect(store.isLoadingMore == false)
        #expect(store.hasMoreCommits == false)
    }

    @Test func stopObservingInvalidatesPendingRefreshAndRemovesHandler() async throws {
        let fake = makeFake()
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.startObserving(workspaceId: "workspace-1")
        fake.pendingMethods.insert("file-tracking.getChanges")
        let refresh = Task { await store.refresh(workspaceId: "workspace-1") }
        try await fake.waitForPendingRequests("file-tracking.getChanges")

        store.stopObserving()
        fake.resolvePending("file-tracking.getChanges", with: WorkspaceChangesFixture.snapshot([
            WorkspaceChangesFixture.change()
        ]))
        await refresh.value
        #expect(store.unstagedChanges.isEmpty)
        #expect(store.hasLoaded == false)
        #expect(store.isLoading == false)
        #expect(fake.eventHandlerCount == 0)
    }

    @Test func eventBurstDiscardsStaleReadAndCoalescesOneFollowup() async throws {
        let fake = makeFake()
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.startObserving(workspaceId: "workspace-1")
        fake.clearRequestLog()
        fake.pendingMethods.insert("file-tracking.getChanges")
        deliverChange(fake)
        try await fake.waitForPendingRequests("file-tracking.getChanges")

        deliverChange(fake)
        deliverChange(fake, type: "changes:git-status")
        deliverChange(fake, type: "git:commit")
        try await expectNever("parallel refreshes for a burst of Changes events") {
            fake.paramsForMethod("file-tracking.getChanges").count > 1
        }
        fake.resolvePending("file-tracking.getChanges", with: WorkspaceChangesFixture.snapshot([
            WorkspaceChangesFixture.change(id: "stale-file")
        ]))
        try await fake.waitForPendingRequests("file-tracking.getChanges")
        #expect(store.unstagedChanges.isEmpty)
        #expect(fake.paramsForMethod("file-tracking.getChanges").count == 2)
        fake.resolvePending("file-tracking.getChanges", with: WorkspaceChangesFixture.snapshot([
            WorkspaceChangesFixture.change(id: "current-file")
        ]))
        try await waitUntil("fresh Changes snapshot after the event burst") {
            store.unstagedChanges.first?.id == "current-file" && !store.isLoading
        }
        #expect(fake.paramsForMethod("file-tracking.loadCommits").count == 1)
        store.stopObserving()
    }

    @Test func staleSubscriptionAckIsReleasedWithoutReplacingNewObservation() async throws {
        let fake = makeFake()
        fake.pendingMethods.insert("events.subscribe")
        let store = WorkspaceChangesStore(connectionManager: fake)
        let earlier = Task { await store.startObserving(workspaceId: "old-workspace") }
        try await fake.waitForPendingRequests("events.subscribe")

        store.stopObserving()
        fake.pendingMethods.remove("events.subscribe")
        fake.responseMap["events.subscribe"] = ["subscriptionId": "current-subscription"]
        await store.startObserving(workspaceId: "workspace-1")
        fake.resolvePending("events.subscribe", with: ["subscriptionId": "old-subscription"])
        await earlier.value
        try await fake.waitForRequests("events.unsubscribe")

        #expect(fake.eventHandlerCount == 1)
        #expect(fake.paramsForMethod("events.unsubscribe").compactMap { $0["subscriptionId"] as? String } == ["old-subscription"])
        #expect(fake.paramsForMethod("file-tracking.getChanges").count == 1)
        fake.responseMap["file-tracking.loadCommits"] = WorkspaceChangesFixture.page(["current-event"])
        deliverChange(fake, subscriptionId: "current-subscription")
        try await waitUntil("event delivery through the current Changes subscription") {
            store.commits.first?.hash == "current-event"
        }
        store.stopObserving()
    }

    @Test func cancelledSubscriptionReleasesLateAckAndHandlerWithoutSeeding() async throws {
        let fake = makeFake()
        fake.pendingMethods.insert("events.subscribe")
        let store = WorkspaceChangesStore(connectionManager: fake)
        let observing = Task { await store.startObserving(workspaceId: "workspace-1") }
        try await fake.waitForPendingRequests("events.subscribe")

        observing.cancel()
        fake.resolvePending("events.subscribe", with: ["subscriptionId": "cancelled-subscription"])
        await observing.value
        try await fake.waitForRequests("events.unsubscribe")
        #expect(fake.eventHandlerCount == 0)
        #expect(fake.didCallMethod("file-tracking.getChanges") == false)
        #expect(store.hasLoaded == false)
    }

    @Test func independentStoresDoNotReplaceEachOthersSubscriptions() async throws {
        let fake = makeFake()
        fake.responseQueueMap["events.subscribe"] = [
            ["subscriptionId": "first-subscription"],
            ["subscriptionId": "second-subscription"]
        ]
        let first = WorkspaceChangesStore(connectionManager: fake)
        let second = WorkspaceChangesStore(connectionManager: fake)
        await first.startObserving(workspaceId: "workspace-1")
        await second.startObserving(workspaceId: "workspace-1")
        let groups = fake.paramsForMethod("events.subscribe").compactMap { $0["replaceGroup"] as? String }
        #expect(Set(groups).count == 2)
        first.stopObserving()
        #expect(fake.eventHandlerCount == 1)
        fake.responseMap["file-tracking.loadCommits"] = WorkspaceChangesFixture.page(["second-still-live"])
        deliverChange(fake, subscriptionId: "second-subscription")
        try await waitUntil("remaining Changes store refresh") {
            second.commits.first?.hash == "second-still-live"
        }
        #expect(first.commits.isEmpty)
        second.stopObserving()
    }
}
