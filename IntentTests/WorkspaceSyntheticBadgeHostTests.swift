@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
private final class SyntheticBadgeHostingController<Content: View>: UIHostingController<Content> {
    private let lifecycleWaiter: SyntheticBadgeHostLifecycleWaiter
    private let observeLifecycle: ((SyntheticBadgeHostLifecycleWaiter.Event) -> Void)?
    private let diagnostics: SyntheticBadgeHostTrace

    init(
        rootView: Content,
        observeLifecycle: ((SyntheticBadgeHostLifecycleWaiter.Event) -> Void)?,
        diagnostics: SyntheticBadgeHostTrace
    ) {
        self.observeLifecycle = observeLifecycle
        self.diagnostics = diagnostics
        lifecycleWaiter = SyntheticBadgeHostLifecycleWaiter(diagnostics: diagnostics)
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor @preconcurrency dynamic required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidAppear(_ animated: Bool) {
        diagnostics.record("didAppear.entry")
        super.viewDidAppear(animated)
        diagnostics.record("didAppear.super.return")
        observeLifecycle?(.didAppear)
        diagnostics.record("didAppear.observer.return")
        lifecycleWaiter.receive(.didAppear)
        diagnostics.record("didAppear.receiver.return")
    }

    override func viewDidDisappear(_ animated: Bool) {
        diagnostics.record("didDisappear.entry")
        super.viewDidDisappear(animated)
        diagnostics.record("didDisappear.super.return")
        observeLifecycle?(.didDisappear)
        diagnostics.record("didDisappear.observer.return")
        lifecycleWaiter.receive(.didDisappear)
        diagnostics.record("didDisappear.receiver.return")
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
    private let diagnostics: SyntheticBadgeHostTrace

    init(
        rootView: Content,
        width: CGFloat,
        height: CGFloat,
        safeAreaRegions: SafeAreaRegions,
        callbackTimeout: TimeInterval,
        afterShowingWindow: (() -> Void)?,
        observeLifecycle: ((SyntheticBadgeHostLifecycleWaiter.Event) -> Void)?,
        diagnostics: SyntheticBadgeHostTrace
    ) throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try #require(
            SyntheticBadgeHostScene.resolve(in: scenes),
            "SyntheticBadgeHost requires a connected foreground window scene: \(SyntheticBadgeHostScene.description(of: scenes))"
        )
        print("SYNTHETIC host scene: \(SyntheticBadgeHostScene.description(of: scenes))")
        controller = SyntheticBadgeHostingController(
            rootView: rootView,
            observeLifecycle: observeLifecycle,
            diagnostics: diagnostics
        )
        controller.safeAreaRegions = safeAreaRegions
        // A detached window can lay out and deliver appearance callbacks while
        // SwiftUI exposes no accessibility tree to the application. Foreground
        // inactivity (for example during a system alert) stops event delivery,
        // not the connected scene's ability to host this view's hierarchy.
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        self.callbackTimeout = callbackTimeout
        self.afterShowingWindow = afterShowingWindow
        self.diagnostics = diagnostics
        diagnostics.bind(window: window, controller: controller)
        diagnostics.record("host.allocated")
        window.rootViewController = controller
        diagnostics.record("host.root.assigned")
    }

    func appear() async throws {
        try await controller.wait(
            for: .didAppear,
            timeout: callbackTimeout,
            honoringCancellation: false
        ) {
            diagnostics.record("show.begin")
            window.isHidden = false
            diagnostics.record("show.return")
            afterShowingWindow?()
        }
        diagnostics.record("appearance.wait.return")
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        diagnostics.record("appearance.layout.return")
    }

    func disappear() async throws {
        diagnostics.record("teardown.begin")
        defer {
            diagnostics.record("teardown.detach.begin")
            window.windowScene = nil
            diagnostics.record("teardown.detached")
        }
        try await controller.wait(
            for: .didDisappear,
            timeout: callbackTimeout,
            honoringCancellation: false
        ) {
            guard !teardownStarted else { return }
            teardownStarted = true
            diagnostics.record("hide.begin")
            window.isHidden = true
            diagnostics.record("hide.return")
            window.rootViewController = nil
            diagnostics.record("teardown.root.cleared")
        }
        diagnostics.record("disappearance.wait.return")
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

    // Keep the existing lifecycle/error/cleanup order together while recording its boundaries.
    // swiftlint:disable:next function_body_length
    static func render<Content: View, Result>(
        _ content: Content,
        width: CGFloat,
        height: CGFloat,
        safeAreaRegions: SafeAreaRegions = .all,
        diagnostics: SyntheticBadgeHostTrace? = nil,
        lifecycleHooks: LifecycleHooks? = nil,
        observeLifecycle: ((LifecycleEvent) -> Void)? = nil,
        inspect: @MainActor (_ hostView: UIView, _ window: UIWindow) async throws -> Result
    ) async throws -> Result {
        let diagnostics = diagnostics ?? SyntheticBadgeHostTrace(context: String(reflecting: Content.self))
        diagnostics.record("render.begin")
        defer {
            diagnostics.record("render.exit")
            diagnostics.publish()
        }
        #if targetEnvironment(simulator)
            let accessibilityOwner = try SyntheticBadgeAccessibilityRuntime.shared.acquire()
            diagnostics.record("accessibility.acquired")
            defer {
                SyntheticBadgeAccessibilityRuntime.shared.release(accessibilityOwner)
                diagnostics.record("accessibility.released")
            }
        #endif
        let session = try autoreleasepool {
            let rootView = SyntheticBadgeHostRoot(content: content, width: width, height: height)
            return try SyntheticBadgeHostSession(
                rootView: rootView,
                width: width,
                height: height,
                safeAreaRegions: safeAreaRegions,
                callbackTimeout: callbackTimeout,
                afterShowingWindow: lifecycleHooks?.afterShowingWindow,
                observeLifecycle: observeLifecycle,
                diagnostics: diagnostics
            )
        }
        var operationResult: Swift.Result<Result, any Error>
        do {
            try await session.appear()
            try Task.checkCancellation()
            diagnostics.record("inspection.begin")
            let inspected = try await inspect(session.controller.view, session.window)
            diagnostics.record("inspection.return")
            try Task.checkCancellation()
            operationResult = .success(inspected)
        } catch {
            diagnostics.record("operation.error", fields: ["error": String(describing: error)])
            operationResult = .failure(error)
        }

        let teardownResult: Swift.Result<Void, any Error>
        do {
            try await session.disappear()
            teardownResult = .success(())
        } catch {
            diagnostics.record("teardown.error", fields: ["error": String(describing: error)])
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
        var visited: Set<ObjectIdentifier> = []
        var elements: [NSObject] = []
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if object !== view { elements.append(object) }
            // ScrollView/Menu can publish intermediate SwiftUI accessibility
            // containers which are NSObjects, not UIViews. Walk their children
            // too; stopping at the first container hides the actual menu chips.
            var children = (object.accessibilityElements ?? []).compactMap { $0 as? NSObject }
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                children += (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            }
            children.forEach(visit)
            if let view = object as? UIView {
                view.subviews.forEach(visit)
            }
        }
        if view.isAccessibilityElement { elements.append(view) }
        visit(view)
        return elements
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
        var renderedWindow: UIWindow?
        try await SyntheticBadgeHost.render(
            Text("content"),
            width: 200,
            height: 100
        ) { stages.append($0.rawValue) } inspect: { hostView, window in
            stages.append("inspection")
            renderedWindow = window
            let controller = try #require(window.rootViewController)
            let scene = try #require(window.windowScene, "A detached window cannot publish the hosted accessibility tree")
            #expect(UIApplication.shared.connectedScenes.contains(scene))
            #expect(scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive)
            #expect(scene.windows.contains { $0 === window })
            #expect(controller.view === hostView)
            #expect(hostView.window === window)
            #expect(hostView.frame == window.bounds)
        }
        #expect(stages == ["didAppear", "inspection", "didDisappear"])
        #expect(renderedWindow?.isHidden == true)
        #expect(renderedWindow?.rootViewController == nil)
        #expect(renderedWindow?.windowScene == nil)
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
