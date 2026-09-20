@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
final class SyntheticBadgeHostLifecycleWaiter: NSObject {
    enum Event: String, Hashable {
        case didAppear
        case didDisappear
    }

    enum WaitError: Error, Equatable {
        case concurrentWait
        case timedOut(Event)
    }

    private var continuation: CheckedContinuation<Void, any Error>?
    private var expectedEvent: Event?
    private var receivedEvents: Set<Event> = []
    private var timer: Timer?

    func wait(
        for event: Event,
        timeout: TimeInterval,
        honoringCancellation: Bool,
        trigger: () -> Void
    ) async throws {
        guard !receivedEvents.contains(event) else { return }
        guard continuation == nil else { throw WaitError.concurrentWait }
        if honoringCancellation {
            try await withTaskCancellationHandler {
                try await installWait(for: event, timeout: timeout, trigger: trigger)
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelWait(for: event)
                }
            }
        } else {
            try await installWait(for: event, timeout: timeout, trigger: trigger)
        }
    }

    func receive(_ event: Event) {
        receivedEvents.insert(event)
        guard expectedEvent == event else { return }
        finish(with: .success(()))
    }

    private func installWait(
        for event: Event,
        timeout: TimeInterval,
        trigger: () -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            guard self.continuation == nil else {
                continuation.resume(throwing: WaitError.concurrentWait)
                return
            }
            self.continuation = continuation
            expectedEvent = event
            let timer = Timer(
                timeInterval: timeout,
                target: self,
                selector: #selector(timeoutFired),
                userInfo: nil,
                repeats: false
            )
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            trigger()
        }
    }

    private func cancelWait(for event: Event) {
        guard expectedEvent == event else { return }
        finish(with: .failure(CancellationError()))
    }

    @objc private func timeoutFired() {
        guard let expectedEvent else { return }
        finish(with: .failure(WaitError.timedOut(expectedEvent)))
    }

    private func finish(with result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        expectedEvent = nil
        timer?.invalidate()
        timer = nil
        continuation.resume(with: result)
    }
}

@MainActor
private final class SyntheticBadgeHostingController<Content: View>: UIHostingController<Content> {
    private let lifecycleWaiter = SyntheticBadgeHostLifecycleWaiter()
    private let observeLifecycle: ((SyntheticBadgeHostLifecycleWaiter.Event) -> Void)?

    init(
        rootView: Content,
        observeLifecycle: ((SyntheticBadgeHostLifecycleWaiter.Event) -> Void)?
    ) {
        self.observeLifecycle = observeLifecycle
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor @preconcurrency dynamic required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        observeLifecycle?(.didAppear)
        lifecycleWaiter.receive(.didAppear)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        observeLifecycle?(.didDisappear)
        lifecycleWaiter.receive(.didDisappear)
    }

    func wait(
        for event: SyntheticBadgeHostLifecycleWaiter.Event,
        timeout: TimeInterval,
        honoringCancellation: Bool,
        trigger: () -> Void
    ) async throws {
        try await lifecycleWaiter.wait(
            for: event,
            timeout: timeout,
            honoringCancellation: honoringCancellation,
            trigger: trigger
        )
    }
}

private struct SyntheticBadgeHostRoot<Content: View>: View {
    let content: Content
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        content.frame(width: width, height: height, alignment: .topLeading)
    }
}

@MainActor
private final class SyntheticBadgeHostSession<Content: View> {
    let controller: SyntheticBadgeHostingController<Content>
    let window: UIWindow
    private let callbackTimeout: TimeInterval
    private let afterShowingWindow: (() -> Void)?
    private var teardownStarted = false

    init(
        rootView: Content,
        width: CGFloat,
        height: CGFloat,
        callbackTimeout: TimeInterval,
        afterShowingWindow: (() -> Void)?,
        observeLifecycle: ((SyntheticBadgeHostLifecycleWaiter.Event) -> Void)?
    ) {
        controller = SyntheticBadgeHostingController(
            rootView: rootView,
            observeLifecycle: observeLifecycle
        )
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        self.callbackTimeout = callbackTimeout
        self.afterShowingWindow = afterShowingWindow
        window.rootViewController = controller
    }

    func appear() async throws {
        try await controller.wait(
            for: .didAppear,
            timeout: callbackTimeout,
            honoringCancellation: false
        ) {
            window.isHidden = false
            afterShowingWindow?()
        }
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
    }

    func disappear() async throws {
        try await controller.wait(
            for: .didDisappear,
            timeout: callbackTimeout,
            honoringCancellation: false
        ) {
            guard !teardownStarted else { return }
            teardownStarted = true
            window.isHidden = true
            window.rootViewController = nil
        }
    }
}

private struct SyntheticBadgeHostCombinedError: Error, CustomStringConvertible {
    let operation: any Error
    let teardown: any Error

    var description: String {
        "Synthetic host operation failed with \(operation); teardown also failed with \(teardown)"
    }
}

/// Hosts a SwiftUI view in a synthetic window for the rendered badge tests and
/// for the accessibility-tree probe that gates them.
@MainActor
enum SyntheticBadgeHost {
    typealias LifecycleEvent = SyntheticBadgeHostLifecycleWaiter.Event

    struct LifecycleHooks {
        let afterShowingWindow: () -> Void
    }

    static let probeIdentifier = "workspaceRow.syntheticHost.probe"
    private static let probeWidth: CGFloat = 200
    private static let probeHeight: CGFloat = 100
    private static let callbackTimeout: TimeInterval = 5

    static func render<Content: View, Result>(
        _ content: Content,
        width: CGFloat,
        height: CGFloat,
        lifecycleHooks: LifecycleHooks? = nil,
        observeLifecycle: ((LifecycleEvent) -> Void)? = nil,
        inspect: (_ hostView: UIView, _ window: UIWindow) throws -> Result
    ) async throws -> Result {
        let session = autoreleasepool {
            let rootView = SyntheticBadgeHostRoot(content: content, width: width, height: height)
            return SyntheticBadgeHostSession(
                rootView: rootView,
                width: width,
                height: height,
                callbackTimeout: callbackTimeout,
                afterShowingWindow: lifecycleHooks?.afterShowingWindow,
                observeLifecycle: observeLifecycle
            )
        }
        var operationResult: Swift.Result<Result, any Error>
        do {
            try await session.appear()
            try Task.checkCancellation()
            let inspected = try inspect(session.controller.view, session.window)
            try Task.checkCancellation()
            operationResult = .success(inspected)
        } catch {
            operationResult = .failure(error)
        }

        let teardownResult: Swift.Result<Void, any Error>
        do {
            try await session.disappear()
            teardownResult = .success(())
        } catch {
            teardownResult = .failure(error)
        }
        if Task.isCancelled, case .success = operationResult {
            operationResult = .failure(CancellationError())
        }

        switch (operationResult, teardownResult) {
        case (.success(let result), .success):
            return result
        case (.failure(let operation), .success):
            throw operation
        case (.success, .failure(let teardown)):
            throw teardown
        case let (.failure(operation), .failure(teardown)):
            throw SyntheticBadgeHostCombinedError(
                operation: operation,
                teardown: teardown
            )
        }
    }

    /// Whether a hosted SwiftUI view exposes its accessibility elements at all.
    /// The simulator lane always enables accessibility (scripts/xcodebuild.sh), so
    /// the probe is only consulted on a physical device; a simulator regression
    /// must surface as a failing badge test, not a skip.
    static func publishesAccessibilityTree() async -> Bool {
        #if targetEnvironment(simulator)
            return true
        #else
            let probe = Text("probe").accessibilityIdentifier(probeIdentifier)
            let found = try? await render(probe, width: probeWidth, height: probeHeight) { hostView, _ in
                accessibilityElements(in: hostView)
                    .contains { accessibilityIdentifier(of: $0) == probeIdentifier }
            }
            let publishes = found ?? false
            if !publishes {
                print(
                    "SYNTHETIC host probe found no accessibility tree on this physical device; "
                        + "skipping rendered badge tests (see intent-hq/ios#322 for the device-side "
                        + "repair and verification that remain open)."
                )
            }
            return publishes
        #endif
    }

    static func accessibilityElements(in view: UIView) -> [NSObject] {
        let elementCount = view.accessibilityElementCount()
        let direct =
            elementCount == NSNotFound
            ? (view.accessibilityElements ?? []).compactMap { $0 as? NSObject }
            : (0..<elementCount).compactMap { index in
                view.accessibilityElement(at: index) as? NSObject
            }
        return (view.isAccessibilityElement ? [view] : direct)
            + view.subviews.flatMap(accessibilityElements(in:))
    }

    /// SwiftUI's accessibility nodes are not `UIView`s, so read the identifier
    /// through `UIAccessibilityIdentification` rather than a view cast.
    static func accessibilityIdentifier(of object: NSObject) -> String? {
        if let identified = object as? UIAccessibilityIdentification {
            return identified.accessibilityIdentifier
        }
        let selector = #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)
        guard object.responds(to: selector) else { return nil }
        return object.value(forKey: "accessibilityIdentifier") as? String
    }
}

@MainActor
struct SyntheticBadgeHostTests {
    private enum InspectionFailure: Error {
        case expected
    }

    @Test func renderUsesRootViewControllerContainmentAcrossCompleteLifecycle() async throws {
        var stages: [String] = []
        try await SyntheticBadgeHost.render(
            Text("content"),
            width: 200,
            height: 100
        ) { stages.append($0.rawValue) } inspect: { hostView, window in
            stages.append("inspection")
            let controller = try #require(window.rootViewController)
            #expect(controller.view === hostView)
            #expect(hostView.window === window)
            #expect(hostView.frame == window.bounds)
        }
        #expect(stages == ["didAppear", "inspection", "didDisappear"])
    }

    @Test func inspectionFailureStillCompletesDisappearance() async {
        var events: [SyntheticBadgeHost.LifecycleEvent] = []
        await #expect(throws: InspectionFailure.self) {
            try await SyntheticBadgeHost.render(
                Text("content"),
                width: 200,
                height: 100
            ) { events.append($0) } inspect: { _, _ in
                throw InspectionFailure.expected
            }
        }
        #expect(events == [.didAppear, .didDisappear])
    }

    @Test func cancellationAfterInspectionStillCompletesDisappearance() async throws {
        var events: [SyntheticBadgeHost.LifecycleEvent] = []
        var renderTask: Task<Void, any Error>?
        renderTask = Task { @MainActor in
            try await SyntheticBadgeHost.render(
                Text("content"),
                width: 200,
                height: 100
            ) { events.append($0) } inspect: { _, _ in
                renderTask?.cancel()
            }
        }
        let task = try #require(renderTask)
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(events == [.didAppear, .didDisappear])
    }

    @Test func cancellationDuringAppearanceStillCompletesLifecycle() async throws {
        var stages: [String] = []
        var didInspect = false
        var renderTask: Task<Void, any Error>?
        renderTask = Task { @MainActor in
            try await SyntheticBadgeHost.render(
                Text("content"),
                width: 200,
                height: 100,
                lifecycleHooks: .init {
                    stages.append("cancellationRequested")
                    renderTask?.cancel()
                }
            ) { stages.append($0.rawValue) } inspect: { _, _ in
                didInspect = true
            }
        }
        let task = try #require(renderTask)
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(didInspect == false)
        #expect(stages == ["cancellationRequested", "didAppear", "didDisappear"])
    }

    @Test func missingLifecycleCallbackFailsBoundedlyAndLeavesWaiterReusable() async throws {
        let waiter = SyntheticBadgeHostLifecycleWaiter()
        await #expect(throws: SyntheticBadgeHostLifecycleWaiter.WaitError.timedOut(.didAppear)) {
            try await waiter.wait(
                for: .didAppear,
                timeout: 0.01,
                honoringCancellation: true
            ) {}
        }
        try await waiter.wait(
            for: .didAppear,
            timeout: 1,
            honoringCancellation: true
        ) {
            waiter.receive(.didAppear)
            waiter.receive(.didAppear)
        }
    }
}
