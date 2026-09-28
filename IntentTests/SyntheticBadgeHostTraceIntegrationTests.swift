import SwiftUI
import Testing
import UIKit

extension SyntheticBadgeHostTests {
    @Test func renderedTraceCorrelatesTheActualHostThroughCleanup() async throws {
        let trace = SyntheticBadgeHostTrace(context: "native lifecycle control")
        try await SyntheticBadgeHost.render(Text("trace"), width: 200, height: 100, diagnostics: trace) { _, window in
            #expect(window.isHidden == false)
        }
        let events = trace.entries.map(\.event)
        let ordered = [
            "host.allocated", "wait.install", "timer.armed", "trigger.begin", "show.begin",
            "didAppear.entry", "didAppear.super.return", "didAppear.observer.return",
            "didAppear.receiver.return", "inspection.begin", "inspection.return", "teardown.begin",
            "didDisappear.entry", "didDisappear.super.return", "didDisappear.observer.return",
            "didDisappear.receiver.return", "teardown.detached", "render.exit"
        ]
        let indices = try ordered.map { try #require(events.firstIndex(of: $0)) }
        #expect(indices == indices.sorted())
        #expect(events.contains("show.return"))
        #expect(events.contains("trigger.return"))
        #expect(events.contains("timer.fire") == false)
        #expect(trace.omittedEntries == 0)
        let allocated = try #require(trace.entries.first { $0.event == "host.allocated" })
        let appeared = try #require(trace.entries.first { $0.event == "didAppear.entry" })
        let detached = try #require(trace.entries.first { $0.event == "teardown.detached" })
        #expect(allocated.state["window"] == appeared.state["window"])
        #expect(allocated.state["controller"] == appeared.state["controller"])
        #expect(allocated.state["scene"] == appeared.state["scene"])
        #expect(appeared.state["viewWindow"] == appeared.state["window"])
        #expect(detached.state["window"] == appeared.state["window"])
        #expect(detached.state["scene"] == "nil")
        #expect(detached.state["hidden"] == "true")
        #expect(detached.state["rootMatchesController"] == "false")
    }

    @Test func timeoutTraceDistinguishesLateDeliveryFromTheExpiredWait() async throws {
        let trace = SyntheticBadgeHostTrace(context: "missing callback control")
        let waiter = SyntheticBadgeHostLifecycleWaiter(diagnostics: trace)
        await #expect(throws: SyntheticBadgeHostLifecycleWaiter.WaitError.timedOut(.didAppear)) {
            try await waiter.wait(for: .didAppear, timeout: 0.01, honoringCancellation: true) {}
        }
        // Match the existing waiter control's direct callback delivery; the rendered host never synthesizes it.
        waiter.receive(.didAppear)
        try await waiter.wait(for: .didDisappear, timeout: 1, honoringCancellation: true) {
            waiter.receive(.didDisappear)
        }
        #expect(trace.entries.prefix(5).map(\.event) == [
            "wait.install", "timer.armed", "trigger.begin", "trigger.return", "timer.fire"
        ])
        let late = try #require(trace.entries.first { $0.event == "wait.receive" })
        #expect(late.fields == ["event": "didAppear", "expected": "none", "hasContinuation": "false"])
        let finished = trace.entries.filter { $0.event == "wait.finish" }
        #expect(finished.count == 2)
        #expect(finished.first?.fields["outcome"]?.contains("timedOut") == true)
        #expect(finished.last?.fields["outcome"] == "success")
    }

    @Test func tracingDoesNotLoadTheControllerViewOrRetainTheHost() {
        let trace = SyntheticBadgeHostTrace(context: "passive state control")
        weak var releasedWindow: UIWindow?
        weak var releasedController: UIViewController?
        autoreleasepool {
            let window = UIWindow(frame: .zero)
            let controller = UIViewController()
            releasedWindow = window
            releasedController = controller
            trace.bind(window: window, controller: controller)
            trace.record("unloaded")
            #expect(controller.isViewLoaded == false)
            #expect(trace.entries.last?.state["viewLoaded"] == "false")
            #expect(trace.entries.last?.state["viewWindow"] == "nil")
        }
        #expect(releasedWindow == nil)
        #expect(releasedController == nil)
        trace.record("released")
        #expect(trace.entries.last?.state == ["host": "released"])
    }
}
