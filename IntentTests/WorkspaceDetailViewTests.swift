import CoreGraphics
import Foundation
@testable import Intent
import SwiftUI
import Testing
import UIKit

struct WorkspaceDetailViewTests {
    @Test func delegatedAgentCountUsesLegibleSingularAndPluralLabels() {
        #expect(AgentGroupSummary.delegatedTitle(count: 1) == "1 delegated agent")
        #expect(AgentGroupSummary.delegatedTitle(count: 34) == "34 delegated agents")
    }

    @Test func tabsDoNotDoubleHeaderSpacingAfterTaskProgress() {
        #expect(WorkspaceDetailHeaderLayout.tabTopPadding(hasTaskProgress: true) == 0)
        #expect(WorkspaceDetailHeaderLayout.tabTopPadding(hasTaskProgress: false)
            == Constants.WorkspaceDetail.tabVerticalPadding)
    }

    @Test func progressCountsPreserveAllThreeProportions() throws {
        let progress = try #require(WorkspaceTaskProgressLayout(
            total: 10,
            completed: 4,
            inProgress: 3
        ))

        #expect(progress.completed == 4)
        #expect(progress.inProgress == 3)
        #expect(progress.remaining == 3)
    }

    @Test func progressSummaryIncludesOnlyActiveWork() throws {
        let active = try #require(WorkspaceTaskProgressLayout(total: 10, completed: 4, inProgress: 3))
        let inactive = try #require(WorkspaceTaskProgressLayout(total: 10, completed: 4, inProgress: 0))

        #expect(active.summary == "4 of 10 tasks complete, 3 in progress")
        #expect(inactive.summary == "4 of 10 tasks complete")
    }

    @Test func overflowingCountsAreClampedToTotal() throws {
        let progress = try #require(WorkspaceTaskProgressLayout(
            total: 5,
            completed: 4,
            inProgress: 4
        ))

        #expect(progress.completed == 4)
        #expect(progress.inProgress == 1)
        #expect(progress.remaining == 0)
    }

    @Test func negativeCountsAreClampedToZero() throws {
        let progress = try #require(WorkspaceTaskProgressLayout(
            total: 5,
            completed: -2,
            inProgress: -3
        ))

        #expect(progress.completed == 0)
        #expect(progress.inProgress == 0)
        #expect(progress.remaining == 5)
    }

    @Test func nonpositiveTotalHasNoLayout() {
        #expect(WorkspaceTaskProgressLayout(total: 0, completed: 0, inProgress: 0) == nil)
        #expect(WorkspaceTaskProgressLayout(total: -1, completed: 0, inProgress: 0) == nil)
    }

    @Test func visibleSegmentCountIncludesOnlyPositiveSegments() throws {
        let threeSegments = try #require(WorkspaceTaskProgressLayout(
            total: 10,
            completed: 4,
            inProgress: 3
        ))
        let twoSegments = try #require(WorkspaceTaskProgressLayout(
            total: 10,
            completed: 4,
            inProgress: 6
        ))
        let oneSegment = try #require(WorkspaceTaskProgressLayout(
            total: 10,
            completed: 10,
            inProgress: 0
        ))

        #expect(threeSegments.visibleSegmentCount == 3)
        #expect(twoSegments.visibleSegmentCount == 2)
        #expect(oneSegment.visibleSegmentCount == 1)
    }

    @Test func visibleSegmentsAndSpacingUseTheMeasuredWidth() throws {
        let measuredWidth: CGFloat = 320
        let spacing: CGFloat = 4
        let inputs = [
            (total: 10, completed: 4, inProgress: 3),
            (total: 10, completed: 4, inProgress: 6),
            (total: 10, completed: 0, inProgress: 3),
            (total: 10, completed: 10, inProgress: 0)
        ]

        for input in inputs {
            let progress = try #require(WorkspaceTaskProgressLayout(
                total: input.total,
                completed: input.completed,
                inProgress: input.inProgress
            ))
            let counts = [progress.completed, progress.inProgress, progress.remaining]
                .filter { $0 > 0 }
            let segmentsWidth = counts.reduce(CGFloat.zero) { width, count in
                width + progress.segmentWidth(
                    for: count,
                    in: measuredWidth,
                    spacing: spacing
                )
            }
            let totalSpacing = spacing * CGFloat(progress.visibleSegmentCount - 1)

            #expect(abs(segmentsWidth + totalSpacing - measuredWidth) < 0.001)
        }
    }

    @Test func segmentWidthsAreZeroWhenSpacingExceedsMeasuredWidth() throws {
        let progress = try #require(WorkspaceTaskProgressLayout(
            total: 10,
            completed: 4,
            inProgress: 3
        ))

        for count in [progress.completed, progress.inProgress, progress.remaining] {
            #expect(progress.segmentWidth(for: count, in: 1, spacing: 4) == 0)
        }
    }

    // MARK: - Session store routing (multi-window state split)

    /// A backend-bound session composed over a fake backend connection; the
    /// coordinator factory is never invoked by these tests.
    @MainActor
    private func makePinnedSession(connection: FakeConnectionManager) -> BackendSession {
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        return BackendSession(
            backendID: BackendID(UUID()),
            connection: connection,
            workspaceStore: WorkspaceStore(forTesting: true),
            coordinatorFactory: { _ in fatalError("coordinator is not built in these tests") },
            githubRepoStore: GitHubRepoStore(connectionManager: connection),
            creationOptionsStore: CreationOptionsStore(connectionManager: connection),
            prMonitorsStore: WorkspacePrMonitorsStore(connectionManager: connection),
            attachmentUploadService: AttachmentUploadService(connection: connection),
            workspaceFileImageLoader: fileLoader,
            attachmentImageLoader: AttachmentImageLoader(
                connection: connection,
                fileLoader: fileLoader
            ),
            attentionCueCenter: WorkspaceAttentionCueCenter {}
        )
    }

    /// A pinned window's workspace detail must fetch/observe agents and
    /// notes over its own session's backend, never the default one.
    @MainActor
    @Test func workspaceDetailStoresRouteOverTheSessionConnection() {
        let fake = FakeConnectionManager()
        let view = WorkspaceDetailView(
            workspaceId: "ws-1",
            session: makePinnedSession(connection: fake)
        )

        #expect(view.agentStoreConnectionID == ObjectIdentifier(fake))
        #expect(view.noteStoreConnectionID == ObjectIdentifier(fake))
        #expect(view.agentStoreConnectionID != ObjectIdentifier(ConnectionManager.shared))
        #expect(view.noteStoreConnectionID != ObjectIdentifier(ConnectionManager.shared))
    }

    /// Same contract for the note detail: its note/agent stores are bound
    /// to the session that opened the note.
    @MainActor
    @Test func noteDetailStoresRouteOverTheSessionConnection() {
        let fake = FakeConnectionManager()
        let view = NoteDetailView(
            noteId: "n-1",
            workspaceId: "ws-1",
            noteTitle: "Note",
            session: makePinnedSession(connection: fake)
        )

        #expect(view.noteStoreConnectionID == ObjectIdentifier(fake))
        #expect(view.agentStoreConnectionID == ObjectIdentifier(fake))
        #expect(view.noteStoreConnectionID != ObjectIdentifier(ConnectionManager.shared))
        #expect(view.agentStoreConnectionID != ObjectIdentifier(ConnectionManager.shared))
    }
}

extension WorkspaceDetailViewTests {
    /// Exercise the real view's onAppear/onChange callbacks with held backend
    /// responses, including the empty-to-sole-agent transition on a later reload.
    @MainActor
    @Test(.serialized, arguments: [0, 1, 2], ["none", "conversation", "note"])
    func delayedAgentLoadsKeepExplicitEntryOnOverview(initialCount: Int, savedScreen: String) async throws {
        let suiteName = "WorkspaceEntry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
        let workspaceId = UUID().uuidString
        if savedScreen != "none" {
            persistence.saveWorkspaceScreen(workspaceId: workspaceId, screen: .init(
                screen: savedScreen,
                workspaceId: workspaceId,
                agentId: "agent-0",
                agentName: "Coordinator",
                noteId: "spec",
                noteTitle: "Spec"
            ))
        }
        let fake = FakeConnectionManager()
        fake.pendingMethods = ["agent.list"]
        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["workspace.markSeen"] = [:]
        let session = makePinnedSession(connection: fake)
        let coordinator = AppCoordinator(
            workspaceStore: session.workspaceStore, connection: fake, persistence: persistence
        )
        coordinator.onSelectWorkspace(workspaceId)
        let view = WorkspaceDetailView(workspaceId: workspaceId, session: session)
        let store = view.agentStoreForTesting
        let (controller, window) = host(view, coordinator: coordinator, session: session)
        defer { tearDown(controller, window: window) }

        for (index, count) in [initialCount, 0, 1, 2, 1].enumerated() {
            if index > 0 {
                fake.deliverEvent(method: "events.event", params: [
                    "event": ["type": "agent:created", "workspaceId": workspaceId]
                ])
            }
            try await waitForEntryCondition {
                fake.requestLog.filter { $0.method == "agent.list" }.count == index + 1
            }
            let agents = (0..<count).map { ["id": "agent-\($0)", "name": "Coordinator \($0)"] }
            fake.resolvePending("agent.list", with: ["agents": agents])
            try await waitForEntryCondition { store.hasLoaded && !store.isLoading && store.agents.count == count }
            // Let SwiftUI render and deliver both agents/hasLoaded onChange callbacks.
            try await Task.sleep(for: .milliseconds(100))
            if case let .workspaceDetail(selectedId) = coordinator.currentScreen {
                #expect(selectedId == workspaceId)
            } else {
                Issue.record("Delayed agent load forwarded explicit workspace entry: \(coordinator.currentScreen)")
            }
        }
        #expect(fake.requestLog.contains { $0.method == "workspace.markSeen" })
    }

    @MainActor
    private func waitForEntryCondition(_ condition: () -> Bool) async throws {
        let timeoutSeconds = 5
        let pollMilliseconds = 10
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(pollMilliseconds))
        }
        try #require(condition(), "Timed out waiting for the hosted workspace's agent load")
    }

    @MainActor
    private func host(
        _ view: WorkspaceDetailView, coordinator: AppCoordinator, session: BackendSession
    ) -> (UIHostingController<AnyView>, UIWindow) {
        let controller = UIHostingController(rootView: AnyView(
            NavigationStack { view }.environment(coordinator).environment(session)
        ))
        let viewportWidth = 390
        let viewportHeight = 844
        let viewport = CGSize(width: viewportWidth, height: viewportHeight)
        let window = UIWindow(frame: CGRect(origin: .zero, size: viewport))
        controller.view.frame = window.bounds
        controller.beginAppearanceTransition(true, animated: false)
        window.addSubview(controller.view)
        window.isHidden = false
        controller.endAppearanceTransition()
        controller.view.layoutIfNeeded()
        return (controller, window)
    }

    @MainActor
    private func tearDown(_ controller: UIHostingController<AnyView>, window: UIWindow) {
        controller.beginAppearanceTransition(false, animated: false)
        controller.view.removeFromSuperview()
        window.isHidden = true
        controller.endAppearanceTransition()
    }
}
