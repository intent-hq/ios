@testable import Intent
import SwiftUI
import Testing
import UIKit

struct MessageCopyContextMenuGatingTests {
    @Test func emptyTextNeverEnables() {
        #expect(!MessageCopyContextMenu.shouldEnableCopyInteraction(text: "", isStreaming: false))
        #expect(!MessageCopyContextMenu.shouldEnableCopyInteraction(text: "", isStreaming: true))
    }

    @Test func streamingRowWithTextDoesNotEnable() {
        #expect(!MessageCopyContextMenu.shouldEnableCopyInteraction(text: "partial delta", isStreaming: true))
    }

    @Test func settledRowWithTextEnables() {
        #expect(MessageCopyContextMenu.shouldEnableCopyInteraction(text: "final answer", isStreaming: false))
    }

    @Test func userRowBehaviorUnchanged() {
        let copyText = MessageView.userCopyText(from: [
            ContentBlock(id: "u1", type: .text, text: "hello there")
        ])
        #expect(MessageCopyContextMenu.shouldEnableCopyInteraction(text: copyText, isStreaming: false))
    }

    @Test func assistantCopyTextDrivesTheGateAcrossPhases() {
        let thinkingOnly: [ContentBlock] = [
            ContentBlock(id: "t1", type: .thinking, text: "reasoning...")
        ]
        let thinkingText = MessageView.assistantCopyText(from: thinkingOnly)
        #expect(thinkingText.isEmpty)
        #expect(!MessageCopyContextMenu.shouldEnableCopyInteraction(text: thinkingText, isStreaming: true))

        let withDelta = thinkingOnly + [
            ContentBlock(id: "t2", type: .text, text: "first streamed words")
        ]
        let deltaText = MessageView.assistantCopyText(from: withDelta)
        #expect(!deltaText.isEmpty)
        #expect(!MessageCopyContextMenu.shouldEnableCopyInteraction(text: deltaText, isStreaming: true))
        #expect(MessageCopyContextMenu.shouldEnableCopyInteraction(text: deltaText, isStreaming: false))
    }
}

@MainActor
struct CopyContextMenuOverlayHitTestTests {
    private struct Fixture {
        let window: UIWindow
        let host: UIView
        let overlay: CopyContextMenuOverlay.OverlayView
        let coordinator: CopyContextMenuOverlay.Coordinator
    }

    private func makeFixture(enabled: Bool, wrapped: Bool = false) -> Fixture {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let window = UIWindow(frame: frame)
        window.isHidden = false
        let host = UIView(frame: frame)
        window.addSubview(host)
        let overlay = CopyContextMenuOverlay.OverlayView()
        let coordinator = CopyContextMenuOverlay.Coordinator(
            text: "copy me",
            preview: AnyView(EmptyView())
        )
        overlay.setInteractionEnabled(enabled, delegate: coordinator)
        if wrapped {
            let wrapper = UIView(frame: host.bounds)
            overlay.frame = wrapper.bounds
            wrapper.addSubview(overlay)
            host.addSubview(wrapper)
        } else {
            overlay.frame = host.bounds
            host.addSubview(overlay)
        }
        return Fixture(window: window, host: host, overlay: overlay, coordinator: coordinator)
    }

    @Test func disabledOverlayIsInvisibleToHitTesting() {
        let fixture = makeFixture(enabled: false)
        let hit = fixture.host.hitTest(CGPoint(x: 50, y: 50), with: nil)
        #expect(hit === fixture.host)
    }

    @Test func overlayClaimsTouchesOverPlainContent() {
        let fixture = makeFixture(enabled: true)
        let hit = fixture.host.hitTest(CGPoint(x: 50, y: 50), with: nil)
        #expect(hit === fixture.overlay)
    }

    @Test func overlayPassesThroughToUIKitBackedSiblings() {
        let fixture = makeFixture(enabled: true)
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 50, height: 100))
        fixture.host.insertSubview(scrollView, belowSubview: fixture.overlay)
        #expect(fixture.host.hitTest(CGPoint(x: 25, y: 50), with: nil) === scrollView)
        #expect(fixture.host.hitTest(CGPoint(x: 75, y: 50), with: nil) === fixture.overlay)
    }

    @Test func probeSeesSiblingsThroughSizedWrapper() throws {
        let fixture = makeFixture(enabled: true, wrapped: true)
        let wrapper = try #require(fixture.overlay.superview)
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 50, height: 100))
        fixture.host.insertSubview(scrollView, belowSubview: wrapper)
        #expect(fixture.host.hitTest(CGPoint(x: 25, y: 50), with: nil) === scrollView)
        #expect(fixture.host.hitTest(CGPoint(x: 75, y: 50), with: nil) === fixture.overlay)
    }

    @Test func hitTestProbeRestoresUserInteraction() throws {
        let fixture = makeFixture(enabled: true, wrapped: true)
        let wrapper = try #require(fixture.overlay.superview)
        _ = fixture.host.hitTest(CGPoint(x: 50, y: 50), with: nil)
        #expect(fixture.overlay.isUserInteractionEnabled)
        #expect(wrapper.isUserInteractionEnabled)
    }

    @Test func overlayPassesThroughToImagePassthroughMarker() {
        let fixture = makeFixture(enabled: true)
        let marker = CopyContextMenuPassthroughMarker.MarkerView(
            frame: CGRect(x: 0, y: 0, width: 50, height: 100)
        )
        fixture.host.insertSubview(marker, belowSubview: fixture.overlay)
        #expect(fixture.overlay.hitTest(CGPoint(x: 25, y: 50), with: nil) == nil)
        #expect(fixture.host.hitTest(CGPoint(x: 25, y: 50), with: nil) === marker)
        #expect(fixture.host.hitTest(CGPoint(x: 75, y: 50), with: nil) === fixture.overlay)
    }

    @Test func overlayFindsPassthroughMarkerUnderZeroFramedWrapper() {
        let fixture = makeFixture(enabled: true)
        let wrapper = UIView(frame: .zero)
        let marker = CopyContextMenuPassthroughMarker.MarkerView(
            frame: CGRect(x: 0, y: 0, width: 50, height: 100)
        )
        wrapper.addSubview(marker)
        fixture.host.insertSubview(wrapper, belowSubview: fixture.overlay)
        #expect(fixture.overlay.hitTest(CGPoint(x: 25, y: 50), with: nil) == nil)
        #expect(fixture.host.hitTest(CGPoint(x: 25, y: 50), with: nil) === fixture.host)
        #expect(fixture.host.hitTest(CGPoint(x: 75, y: 50), with: nil) === fixture.overlay)
    }

    @Test func overlayFindsButtonMarkerInsideProbedScrollContainer() {
        let fixture = makeFixture(enabled: true)
        let scrollView = UIScrollView(frame: fixture.host.bounds)
        let wrapper = UIView(frame: .zero)
        let marker = CopyContextMenuPassthroughMarker.MarkerView(
            frame: CGRect(x: 0, y: 0, width: 50, height: 100)
        )
        wrapper.addSubview(marker)
        scrollView.addSubview(wrapper)
        fixture.host.insertSubview(scrollView, belowSubview: fixture.overlay)
        #expect(fixture.overlay.hitTest(CGPoint(x: 25, y: 50), with: nil) == nil)
        #expect(fixture.host.hitTest(CGPoint(x: 25, y: 50), with: nil) === scrollView)
        #expect(fixture.host.hitTest(CGPoint(x: 75, y: 50), with: nil) === scrollView)
    }
}

@MainActor
struct AssistantMessageToolRowHitTestTests {
    private static let hostWidth: CGFloat = 390
    private static let hostHeight: CGFloat = 320
    private static let bodyText = "Here is the file you asked for."
    private static let toolInput: [String: AnyCodable] = [
        "path": AnyCodable("Sources/Package.swift")
    ]

    private static func makeMessage(includeText: Bool) -> ConversationMessage {
        var blocks: [ContentBlock] = []
        if includeText {
            blocks.append(ContentBlock(id: "b-text", type: .text, text: bodyText))
        }
        blocks.append(ContentBlock(
            id: "b-tool", type: .toolUse, name: "view", input: toolInput, inputTruncation: .truncated
        ))
        return ConversationMessage(
            id: "m-344",
            role: .assistant,
            contentBlocks: blocks,
            timestamp: "2025-01-01T00:00:00Z",
            streamingState: .complete
        )
    }

    private static func makeCoordinator() throws -> AppCoordinator {
        _ = TestKeychainStorage.installed
        let suiteName = "AssistantMessageToolRowHitTestTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: FakeConnectionManager(),
            persistence: PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
        )
    }

    private static func allAccessibilityElements(
        under root: NSObject,
        visited: inout Set<ObjectIdentifier>,
        maxDepth: Int = 12
    ) -> [NSObject] {
        guard maxDepth > 0, visited.insert(ObjectIdentifier(root)).inserted else { return [] }
        var children = (root.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        let elementCount = root.accessibilityElementCount()
        if elementCount != NSNotFound, elementCount > 0 {
            children += (0..<elementCount).compactMap { root.accessibilityElement(at: $0) as? NSObject }
        }
        if let view = root as? UIView {
            children += view.subviews
        }
        return [root] + children.flatMap { child in
            allAccessibilityElements(under: child, visited: &visited, maxDepth: maxDepth - 1)
        }
    }

    private static let accessibilityObservationDeadline: TimeInterval = 3
    private static let accessibilityObservationInterval: TimeInterval = 0.02

    private static func labelledElement(
        containing fragment: String,
        under hostView: UIView
    ) -> (element: NSObject?, seen: [String]) {
        var visited: Set<ObjectIdentifier> = []
        let elements = allAccessibilityElements(under: hostView, visited: &visited)
        let match = elements.first { element in
            element.accessibilityLabel?.contains(fragment) == true
                || element.accessibilityValue?.contains(fragment) == true
        }
        let seen = elements.compactMap { element -> String? in
            let text = element.accessibilityLabel ?? element.accessibilityValue
            return text.map { "\(type(of: element))(\($0.prefix(60)))" }
        }
        return (match, seen)
    }

    private static func frame(
        ofElementContaining fragment: String,
        in hostView: UIView,
        window: UIWindow
    ) throws -> CGRect {
        let deadline = Date(timeIntervalSinceNow: accessibilityObservationDeadline)
        var found = labelledElement(containing: fragment, under: hostView)
        while found.element == nil, Date() < deadline {
            _ = RunLoop.current.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: accessibilityObservationInterval)
            )
            hostView.layoutIfNeeded()
            found = labelledElement(containing: fragment, under: hostView)
        }
        let element = try #require(
            found.element,
            Comment(
                rawValue: "no accessibility element labelled with \(fragment) within "
                    + "\(accessibilityObservationDeadline)s; saw: [\(found.seen.joined(separator: ", "))]"
            )
        )
        let frame = window.convert(element.accessibilityFrame, from: nil)
        try #require(!frame.isEmpty, "\(fragment) has an empty accessibility frame")
        return frame
    }

    private static func firstDescendant<T: UIView>(of _: T.Type, in root: UIView) -> T? {
        for subview in root.subviews {
            if let match = subview as? T { return match }
            if let match = firstDescendant(of: T.self, in: subview) { return match }
        }
        return nil
    }

    private static func copyOverlay(
        in hostView: UIView,
        window: UIWindow
    ) throws -> (view: CopyContextMenuOverlay.OverlayView, frame: CGRect) {
        let overlay = try #require(
            firstDescendant(of: CopyContextMenuOverlay.OverlayView.self, in: hostView),
            "hosted AssistantMessageView carries no copy overlay"
        )
        return (overlay, window.convert(overlay.bounds, from: overlay))
    }

    private static func requireHit(at point: CGPoint, in hostView: UIView, window: UIWindow) throws -> UIView {
        let hit = try #require(window.hitTest(point, with: nil), "nothing hit-tests at \(point)")
        try #require(hit.isDescendant(of: hostView), "hit \(hit) lies outside the hosted row")
        try #require(
            hit.point(inside: hit.convert(point, from: window), with: nil),
            "hit \(hit) does not contain \(point) in its own bounds"
        )
        return hit
    }

    private static func expectHeaderPassThroughAndActivation(
        subject: String,
        in hostView: UIView,
        window: UIWindow,
        workspaceDesign: Bool
    ) throws {
        let headerFrame = try frame(ofElementContaining: subject, in: hostView, window: window)
        if workspaceDesign { #expect(headerFrame.maxY >= headerFrame.minY + 44) }
        let point = CGPoint(x: headerFrame.midX, y: headerFrame.midY)
        let hit = try requireHit(at: point, in: hostView, window: window)
        #expect(!(hit is CopyContextMenuOverlay.OverlayView), "copy overlay swallowed the header tap")
        let header = try #require(labelledElement(containing: subject, under: hostView).element)
        #expect(header.accessibilityTraits.contains(.button))
        #expect(header.accessibilityValue == "Collapsed")
        #expect(header.accessibilityActivate(), "the real header Button must accept accessibility activation")
        let deadline = Date(timeIntervalSinceNow: accessibilityObservationDeadline)
        while labelledElement(containing: subject, under: hostView).element?.accessibilityValue != "Expanded",
              Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: accessibilityObservationInterval))
            hostView.layoutIfNeeded()
        }
        #expect(labelledElement(containing: subject, under: hostView).element?.accessibilityValue == "Expanded")
    }

    private func hitTest(
        includeText: Bool,
        workspaceDesign: Bool,
        expectExpansion: Bool = false,
        probe: @MainActor (_ hostView: UIView, _ window: UIWindow) throws -> Void
    ) async throws {
        let coordinator = try Self.makeCoordinator()
        var hydratedBlockIDs: [String] = []
        defer { #expect(hydratedBlockIDs == (expectExpansion ? ["b-tool"] : [])) }
        let view = AssistantMessageView(
            message: Self.makeMessage(includeText: includeText),
            workspaceId: "ws-1",
            onNavigateToNote: nil,
            hydratingBlockIds: []
        ) { hydratedBlockIDs.append($0) }
        .environment(coordinator)
        .environment(\.workspaceTranscriptDesign, workspaceDesign)
        try await SyntheticBadgeHost.render(view, width: Self.hostWidth, height: Self.hostHeight, inspect: probe)
    }

    private var toolSubject: String {
        get throws {
            try #require(ToolClassifier.classify(name: "view", input: Self.toolInput).subject)
        }
    }

    private static let accessibilityGate = Comment(
        rawValue:
            "SwiftUI publishes its accessibility tree only when accessibility is enabled "
            + "for the process (scripts/xcodebuild.sh enables it on the simulator; a "
            + "physical-device unit-test run needs VoiceOver or an XCUITest session)"
    )

    @Test(.enabled(Self.accessibilityGate) { await SyntheticBadgeHost.publishesAccessibilityTree() }, arguments: [false, true])
    func toolRowHeaderPassesHitTestAndActivatesInTextBearingMessage(workspaceDesign: Bool) async throws {
        let subject = try toolSubject
        try await hitTest(includeText: true, workspaceDesign: workspaceDesign, expectExpansion: true) { hostView, window in
            let overlay = try Self.copyOverlay(in: hostView, window: window)
            #expect(overlay.view.interactions.contains { $0 is UIContextMenuInteraction })
            let headerFrame = try Self.frame(ofElementContaining: subject, in: hostView, window: window)
            #expect(overlay.frame.contains(CGPoint(x: headerFrame.midX, y: headerFrame.midY)))
            try Self.expectHeaderPassThroughAndActivation(
                subject: subject, in: hostView, window: window, workspaceDesign: workspaceDesign
            )
        }
    }

    private static let minimumTextBandHeight: CGFloat = 12

    @Test(.enabled(Self.accessibilityGate) { await SyntheticBadgeHost.publishesAccessibilityTree() }, arguments: [false, true])
    func textRegionKeepsCopyMenuInTextBearingMessage(workspaceDesign: Bool) async throws {
        let subject = try toolSubject
        try await hitTest(includeText: true, workspaceDesign: workspaceDesign) { hostView, window in
            let overlay = try Self.copyOverlay(in: hostView, window: window)
            #expect(
                overlay.view.interactions.contains { $0 is UIContextMenuInteraction },
                "copy interaction is not attached to a settled text-bearing message"
            )
            let headerFrame = try Self.frame(ofElementContaining: subject, in: hostView, window: window)
            let textBandHeight = headerFrame.minY - overlay.frame.minY
            try #require(
                textBandHeight >= Self.minimumTextBandHeight,
                "no text band above the tool header (overlay \(overlay.frame), header \(headerFrame))"
            )
            let point = CGPoint(x: headerFrame.midX, y: overlay.frame.minY + textBandHeight / 2)
            #expect(overlay.frame.contains(point), "overlay \(overlay.frame) does not cover the text at \(point)")
            let hit = try Self.requireHit(at: point, in: hostView, window: window)
            #expect(
                hit === overlay.view || hit is UITextInput,
                "text region resolved to \(hit), neither the copy overlay nor a text input"
            )
            #expect(!(hit is CopyContextMenuPassthroughMarker.MarkerView))
        }
    }

    @Test(.enabled(Self.accessibilityGate) { await SyntheticBadgeHost.publishesAccessibilityTree() }, arguments: [false, true])
    func toolRowHeaderPassesHitTestAndActivatesInToolOnlyMessage(workspaceDesign: Bool) async throws {
        let subject = try toolSubject
        try await hitTest(includeText: false, workspaceDesign: workspaceDesign, expectExpansion: true) { hostView, window in
            let overlay = try Self.copyOverlay(in: hostView, window: window)
            #expect(
                !overlay.view.interactions.contains { $0 is UIContextMenuInteraction },
                "copy interaction attached to a message without copy text"
            )
            try Self.expectHeaderPassThroughAndActivation(
                subject: subject,
                in: hostView,
                window: window,
                workspaceDesign: workspaceDesign
            )
        }
    }
}
