import Foundation
@testable import Intent
import SwiftUI
import Testing
import UIKit

/// Native rendered coverage: onAppear on a prefetched lazy row is insufficient.
/// Exercise the actual onScrollVisibilityChange callbacks in a foreground window.
@MainActor
@Suite(.serialized)
struct AgentWaitingViewTests {
    @Test(arguments: [false, true])
    func scrollingLoadsOnlyRowsIntersectingTheWaitingViewport(bundled: Bool) async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.bundlesWatchedAgents = bundled
        let childCount = 50
        fixture.watchedIds = (0..<childCount).map { String(format: "visible-child-%02d", $0) }
        let model = fixture.makeViewModel()
        await model.load()
        let view = AgentWaitingView(viewModel: model, store: model.store) { _, _, _ in }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try #require(SyntheticBadgeHostScene.resolve(in: scenes))
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        let size = CGSize(width: 360, height: 300)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        defer { window.isHidden = true; window.rootViewController = nil; window.windowScene = nil }
        window.isHidden = false
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        let checkpoint = fixture.connection.checkpoint
        try await waitUntil("real waiting viewport loads the first row", timeout: .seconds(5)) {
            model.store.watchedAgentCoordinator.row("visible-child-00").hasSummary
        }
        let initialMaximum = 10
        try await expectNever("eager offscreen rows", within: .milliseconds(300)) {
            fixture.connection.traffic(since: checkpoint).calls("agent.get").count >= initialMaximum
        }
        #expect(model.store.watchedAgentCoordinator.row("visible-child-49").hasSummary == bundled)
        let scroll = try #require(scrollViews(in: controller.view).first)
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
        try await waitUntil("scrolling realizes the final watched row", timeout: .seconds(5)) {
            model.store.watchedAgentCoordinator.row("visible-child-49").hasSummary
        }
        let afterScrolling = fixture.connection.traffic(since: checkpoint)
        let scrollingMaximum = 20
        #expect(afterScrolling.calls("agent.get").count < scrollingMaximum)
        if bundled {
            try await expectNever("details while scrolling bundled rows", within: .milliseconds(300)) {
                fixture.connection.traffic().calls("agent.get").count > 1
            }
            #expect(fixture.details.cached(agentId: "visible-child-49") == nil)
        }
        #expect(afterScrolling.calls("agent.list").isEmpty)
        #expect(afterScrolling.calls("chat.subscribe").isEmpty)
        #expect(afterScrolling.calls("agent.getSubscriptions").isEmpty)
        #expect(afterScrolling.pendingCount == 0 && afterScrolling.failures.isEmpty)
        print("Rendered waiting rows including scroll: \(afterScrolling.summary)")
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}
