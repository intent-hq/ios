import Foundation
@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct WorkspaceAgentLoadingTests {
    @Test(arguments: [false, true])
    func largeWorkspaceLoadsAllRowsAndKeepsExpansionResponsive(legacy: Bool) async throws {
        let fake = AgentGroupFixtureConnection()
        fake.legacyAllActive = legacy
        fake.rows = DemoAgentListFixtures.largeGroupRows
        let host = Host(connection: fake)
        defer { host.tearDown() }
        let rootCount = legacy ? 1203 : 1201
        try await waitUntil("large workspace loads") {
            host.view.agentStore.hasLoaded && host.view.viewModel.foregroundAgents.count == rootCount
        }
        await host.view.toggleAgentGroup(.delegated(parentId: "groups-parent"))
        try await waitUntil("large delegated group reaches the view") {
            host.view.viewModel.delegatedAgents(for: "groups-parent").count == 1201
        }
        let model = host.view.viewModel
        #expect(model.visibleTree(model.foregroundAgents).count == rootCount + 1201)
        await host.view.toggleAgentGroup(.delegated(parentId: "groups-parent"))
        #expect(model.visibleTree(model.foregroundAgents).count == rootCount)
    }

    @Test func actualViewLoadsVisibleBadgesAndKeepsDeeperGroupsLazyAcrossWorkspaceSwitches() async throws {
        let fake = AgentGroupFixtureConnection()
        let host = Host(connection: fake)
        defer { host.tearDown() }
        try await waitUntil("collapsed visible badges load") {
            host.view.agentStore.isAgentGroupLoaded(.delegated(parentId: "groups-parent"))
        }
        #expect(fake.paramsForMethod("agent.list").count == 2)
        #expect(fake.paramsForMethod("agent.list").first?["scope"] as? String == "topLevel")
        #expect(Set(host.view.agentStore.agents.map(\.id)) == ["groups-parent", "groups-child"])
        #expect(host.view.viewModel.expandedGroups.isEmpty)
        #expect(!host.view.agentStore.isAgentGroupLoaded(.delegated(parentId: "groups-child")))

        await host.view.toggleAgentGroup(.delegated(parentId: "groups-parent"))
        try await waitUntil("newly visible child badges load") {
            host.view.agentStore.isAgentGroupLoaded(.delegated(parentId: "groups-child"))
        }
        #expect(fake.paramsForMethod("agent.list").last?["parentAgentId"] as? String == "groups-child")
        #expect(Set(host.view.agentStore.agents.map(\.id)) == ["groups-parent", "groups-child", "groups-grandchild"])
        #expect(fake.paramsForMethod("agent.list").count == 3)
        await host.view.toggleAgentGroup(.delegated(parentId: "groups-parent"))
        await host.view.toggleAgentGroup(.delegated(parentId: "groups-parent"))
        #expect(fake.paramsForMethod("agent.list").count == 3, "Re-expansion must use loaded rows")

        fake.clearRequestLog()
        fake.simulateConnect()
        try await fake.waitForRequests("agent.list", count: 3)
        #expect(fake.paramsForMethod("agent.list").first?["scope"] as? String == "topLevel")
        #expect(Set(fake.paramsForMethod("agent.list").compactMap { $0["parentAgentId"] as? String }) == ["groups-parent", "groups-child"])
        try await expectNever("unopened background, orphan or retired read") { fake.paramsForMethod("agent.list").count > 3 }

        fake.clearRequestLog()
        host.switchWorkspace(to: "ws-2")
        try await waitUntil("workspace switch resets the real view") {
            fake.paramsForMethod("agent.list").contains { $0["workspaceId"] as? String == "ws-2" }
                && host.view.viewModel.expandedGroups.isEmpty
                && host.view.agentStore.isAgentGroupLoaded(.delegated(parentId: "groups-parent"))
        }
        #expect(fake.paramsForMethod("agent.list").count == 2)
        #expect(fake.paramsForMethod("agent.list").first?["scope"] as? String == "topLevel")
        #expect(host.view.agentStore.list.loadedGroups == [.delegated(parentId: "groups-parent")])
        #expect(host.view.agentStore.list.retiredAgents.isEmpty)
    }

    @Test func actualViewExpansionKeepsLoadingAndFailureRetryLocalToItsGroup() async throws {
        let fake = AgentGroupFixtureConnection()
        let host = Host(connection: fake)
        defer { host.tearDown() }
        try await waitUntil("visible badges load") {
            host.view.agentStore.isAgentGroupLoaded(.delegated(parentId: "groups-parent"))
        }
        fake.pendingMethods.insert("agent.list")
        let expansion = Task { await host.view.toggleAgentGroup(.background) }
        defer { expansion.cancel() }
        try await fake.waitForPendingRequests("agent.list")
        #expect(host.view.agentStore.list.loadingGroups == [.background])
        #expect(host.view.viewModel.isExpanded(.background))
        fake.failPending("agent.list", with: NSError(domain: "test", code: 1))
        await expansion.value
        #expect(host.view.agentStore.list.errors[.background] != nil)
        #expect(host.view.agentStore.list.loadingGroups.isEmpty)
        fake.pendingMethods.remove("agent.list")
        await host.view.agentStore.loadAgentGroup(.background, workspaceId: "ws-1")
        #expect(host.view.agentStore.list.errors.isEmpty)
        #expect(host.view.agentStore.agents.contains { $0.id == "groups-background" })
        #expect(fake.paramsForMethod("agent.list").dropFirst(2).allSatisfy { $0["scope"] as? String == "background" })
    }

    @Test func actualViewUsesOrphanAndRetiredRequestsAndLegacyFallback() async throws {
        let fake = AgentGroupFixtureConnection()
        let host = Host(connection: fake)
        defer { host.tearDown() }
        try await waitUntil("view loads") { host.view.agentStore.hasLoaded }
        await host.view.toggleAgentGroup(.orphaned)
        #expect(fake.paramsForMethod("agent.list").last?["orphanedOnly"] as? Bool == true)
        #expect(host.view.agentStore.list.orphanedAgentIds == ["groups-orphan", "groups-retired-child"])
        await host.view.toggleAgentGroup(.retired)
        #expect(fake.paramsForMethod("agent.list").last?["retiredOnly"] as? Bool == true)
        #expect(host.view.agentStore.list.retiredAgents.map(\.id) == ["groups-retired"])
        fake.omitOrphanCounts = true
        let requestCount = fake.paramsForMethod("agent.list").count
        await host.view.agentStore.fetchAgents(workspaceId: "ws-1")
        let refreshRequests = fake.paramsForMethod("agent.list").dropFirst(requestCount)
        let fallback = try #require(refreshRequests.first { params in
            params["scope"] as? String == "delegated" && params["parentAgentId"] == nil
        })
        #expect(fallback["orphanedOnly"] == nil)
    }

    @Test func emptyExpandedGroupRemainsCollapsibleAndLegacyRowsNeedNoExtraReads() async throws {
        let fake = AgentGroupFixtureConnection()
        let host = Host(connection: fake)
        defer { host.tearDown() }
        try await waitUntil("view loads") { host.view.agentStore.hasLoaded }
        fake.rows = DemoAgentListFixtures.groupRows.filter { $0["id"] as? String == "groups-parent" }
        await host.view.agentStore.fetchAgents(workspaceId: "ws-1")
        await host.view.toggleAgentGroup(.delegated(parentId: "groups-parent"))
        #expect(host.view.viewModel.isExpanded(.delegated(parentId: "groups-parent")))
        #expect(host.view.viewModel.count(for: .delegated(parentId: "groups-parent")) == 0)
        #expect(host.view.agentStore.isAgentGroupLoaded(.delegated(parentId: "groups-parent")))
        fake.rows = DemoAgentListFixtures.groupRows
        fake.legacyAllActive = true
        await host.view.agentStore.fetchAgents(workspaceId: "ws-1")
        let count = fake.paramsForMethod("agent.list").count
        await host.view.toggleAgentGroup(.background)
        #expect(fake.paramsForMethod("agent.list").count == count)
        #expect(host.view.agentStore.list.scopeCounts == nil)
        #expect(host.view.agentStore.agents.contains { $0.id == "groups-background-child" })
    }

    @Test(arguments: [false, true])
    func failedOrphanRefreshDoesNotDuplicateChildrenAfterTheirParentIsRestored(background: Bool) async throws {
        let fake = AgentGroupFixtureConnection()
        fake.rows = [["id": "child", "name": "Child", "parentAgentId": "parent"]]
        let host = Host(connection: fake)
        defer { host.tearDown() }
        try await waitUntil("view loads") { host.view.agentStore.hasLoaded }
        await host.view.toggleAgentGroup(.orphaned)
        #expect(host.view.agentStore.list.orphanedAgentIds == ["child"])
        var parent: [String: Any] = ["id": "parent", "name": "Parent", "metadata": ["isBackground": background]]
        if !background { parent["parentAgentId"] = "missing" }
        fake.rows.append(parent)
        fake.failOrphanReads = true
        await host.view.agentStore.fetchAgents(workspaceId: "ws-1")
        #expect(host.view.agentStore.list.errors[.orphaned] != nil)
        if background {
            await host.view.toggleAgentGroup(.background)
        } else {
            // A live orphan parent arrives through another already-expanded
            // parent scope while the orphan membership remains stale.
            await host.view.agentStore.loadAgentGroup(.delegated(parentId: "missing"), workspaceId: "ws-1")
        }
        await host.view.toggleAgentGroup(.delegated(parentId: "parent"))
        try await waitUntil("restored parent reaches the actual view model") {
            host.view.viewModel.agents.contains { $0.id == "parent" }
        }
        #expect(host.view.agentStore.list.orphanedAgentIds.contains("child"))
        #expect(!host.view.viewModel.orphanedAgents.contains { $0.id == "child" })
        #expect(host.view.viewModel.delegatedAgents(for: "parent").map(\.id) == ["child"])
    }

    private final class Host {
        let view: WorkspaceDetailView
        private let session: BackendSession
        private let coordinator: AppCoordinator
        private var controller: UIHostingController<AnyView>?
        private var window: UIWindow?
        private let suiteName = "WorkspaceAgentLoadingTests-" + UUID().uuidString

        init(connection: FakeConnectionManager) {
            _ = TestKeychainStorage.installed
            session = WorkspaceDetailViewTests().makePinnedSession(connection: connection)
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            coordinator = AppCoordinator(
                workspaceStore: session.workspaceStore,
                connection: connection,
                persistence: PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
            )
            view = WorkspaceDetailView(workspaceId: "ws-1", session: session)
            let controller = UIHostingController(rootView: AnyView(
                NavigationStack { view }.environment(coordinator).environment(session)
            ))
            let window = UIWindow(frame: UIScreen.main.bounds)
            controller.view.frame = window.bounds
            controller.beginAppearanceTransition(true, animated: false)
            window.addSubview(controller.view)
            window.isHidden = false
            controller.endAppearanceTransition()
            controller.view.layoutIfNeeded()
            self.controller = controller
            self.window = window
        }

        func switchWorkspace(to id: String) {
            controller?.rootView = AnyView(
                NavigationStack { WorkspaceDetailView(workspaceId: id, session: session) }
                    .environment(coordinator).environment(session)
            )
            controller?.view.layoutIfNeeded()
        }

        func tearDown() {
            controller?.beginAppearanceTransition(false, animated: false)
            controller?.view.removeFromSuperview()
            window?.isHidden = true
            controller?.endAppearanceTransition()
            controller = nil
            window = nil
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
    }
}

@MainActor
private final class AgentGroupFixtureConnection: FakeConnectionManager {
    var omitOrphanCounts = false
    var legacyAllActive = false
    var failOrphanReads = false
    var rows = DemoAgentListFixtures.groupRows

    override func request(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = ConnectionManager.defaultRequestTimeout) async throws -> Any {
        if method == "agent.list" {
            var response = DemoAgentListFixtures.response(rows: rows, params: legacyAllActive ? [:] : params)
            if legacyAllActive { response["scopeCounts"] = nil; response["delegatedCounts"] = nil }
            if omitOrphanCounts, var counts = response["delegatedCounts"] as? [String: Any] {
                counts["orphaned"] = nil
                response["delegatedCounts"] = counts
            }
            if failOrphanReads, params["orphanedOnly"] as? Bool == true { response = ["error": "Refresh failed"] }
            responseMap[method] = response
        } else if method == "note.list" { responseMap[method] = ["notes": []] }
        return try await super.request(method, params: params, timeout: timeout)
    }
}
