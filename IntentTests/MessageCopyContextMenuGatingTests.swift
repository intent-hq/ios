@testable import Intent
import SwiftUI
import Testing
import UIKit

/// Availability gate for the copy-context-menu interaction
/// (MessageCopyContextMenu): the overlay is applied unconditionally so the
/// row subtree never changes structural identity, and this predicate only
/// decides whether the overlay carries a live `UIContextMenuInteraction`.
/// The interaction attaches once the message has settled and there is text
/// to copy — image-only rows and live streaming rows stay inert.
struct MessageCopyContextMenuGatingTests {
    @Test func emptyTextNeverEnables() {
        #expect(!MessageCopyContextMenu.shouldEnableCopyInteraction(text: "", isStreaming: false))
        #expect(!MessageCopyContextMenu.shouldEnableCopyInteraction(text: "", isStreaming: true))
    }

    /// The first text delta makes the copy text non-empty while the turn is
    /// still streaming — the interaction must NOT attach mid-stream.
    @Test func streamingRowWithTextDoesNotEnable() {
        #expect(!MessageCopyContextMenu.shouldEnableCopyInteraction(text: "partial delta", isStreaming: true))
    }

    /// Settled rows with copyable text keep the upright-lift-preview
    /// interaction from #140.
    @Test func settledRowWithTextEnables() {
        #expect(MessageCopyContextMenu.shouldEnableCopyInteraction(text: "final answer", isStreaming: false))
    }

    /// User rows never stream and pass isStreaming: false — a non-empty
    /// user bubble gets the interaction exactly as before the gate.
    @Test func userRowBehaviorUnchanged() {
        let copyText = MessageView.userCopyText(from: [
            ContentBlock(id: "u1", type: .text, text: "hello there")
        ])
        #expect(MessageCopyContextMenu.shouldEnableCopyInteraction(text: copyText, isStreaming: false))
    }

    /// End-to-end shape of the assistant flow: during the thinking phase
    /// assistantCopyText is empty (no interaction); after the first text
    /// delta it is non-empty, and only the streaming flag keeps the row
    /// inert until the turn settles.
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

/// Selective hit-testing of the transparent overlay
/// (CopyContextMenuOverlay.OverlayView): as a sibling above the row content
/// it must claim touches over plain SwiftUI regions (the underlying hit view
/// is its ancestor — the hosting view — whose gesture recognizers still see
/// the touch), pass touches through to UIKit-backed sibling subtrees
/// (in-row scroll views), and be completely inert while the interaction is
/// disabled. The probe runs from the window, so every fixture is rooted in
/// a real `UIWindow`.
@MainActor
struct CopyContextMenuOverlayHitTestTests {
    /// Holds the fixture's strong references: `UIContextMenuInteraction`
    /// keeps its delegate weakly, so the coordinator must outlive the
    /// assertions for the fixture to stay realistic.
    private struct Fixture {
        let window: UIWindow
        let host: UIView
        let overlay: CopyContextMenuOverlay.OverlayView
        let coordinator: CopyContextMenuOverlay.Coordinator
    }

    /// Builds `window > host > [siblings..., overlay]`. With `wrapped: true`
    /// the overlay sits inside an intermediate wrapper sized exactly to it,
    /// mimicking SwiftUI's per-representable wrapper in production.
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
        // No UIKit-backed sibling below: the probe finds the host (an
        // ancestor), so the overlay claims the touch for its interaction.
        let fixture = makeFixture(enabled: true)
        let hit = fixture.host.hitTest(CGPoint(x: 50, y: 50), with: nil)
        #expect(hit === fixture.overlay)
    }

    @Test func overlayPassesThroughToUIKitBackedSiblings() {
        // A scroll view beneath the overlay (e.g. a code block) must keep
        // receiving its touches; the overlay yields over that sub-region
        // and still claims the rest of the row.
        let fixture = makeFixture(enabled: true)
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 50, height: 100))
        fixture.host.insertSubview(scrollView, belowSubview: fixture.overlay)
        #expect(fixture.host.hitTest(CGPoint(x: 25, y: 50), with: nil) === scrollView)
        #expect(fixture.host.hitTest(CGPoint(x: 75, y: 50), with: nil) === fixture.overlay)
    }

    @Test func probeSeesSiblingsThroughSizedWrapper() throws {
        // Production shape: the overlay's immediate superview is SwiftUI's
        // per-representable wrapper, sized exactly to the overlay with the
        // overlay as its only subview. A probe from that superview could
        // only ever find the wrapper; the window-rooted probe must disable
        // the wrapper chain and still find the scroll view beneath.
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
        // A pass-through marker (the background of a tappable image
        // thumbnail) beneath the overlay: the probe resolves to the marker,
        // so the touch reaches the SwiftUI Button above it instead of
        // being claimed for the copy interaction. The rest of the row is
        // still claimed.
        let fixture = makeFixture(enabled: true)
        let marker = CopyContextMenuPassthroughMarker.MarkerView(
            frame: CGRect(x: 0, y: 0, width: 50, height: 100)
        )
        fixture.host.insertSubview(marker, belowSubview: fixture.overlay)
        #expect(fixture.host.hitTest(CGPoint(x: 25, y: 50), with: nil) === marker)
        #expect(fixture.host.hitTest(CGPoint(x: 75, y: 50), with: nil) === fixture.overlay)
    }

    @Test func overlayFindsPassthroughMarkerUnderZeroFramedWrapper() {
        // Regular hit-testing never descends into a zero-framed wrapper, so
        // the probe resolves to the host (an ancestor); the overlay must
        // still find the correctly-framed marker beneath it.
        let fixture = makeFixture(enabled: true)
        let wrapper = UIView(frame: .zero)
        let marker = CopyContextMenuPassthroughMarker.MarkerView(
            frame: CGRect(x: 0, y: 0, width: 50, height: 100)
        )
        wrapper.addSubview(marker)
        fixture.host.insertSubview(wrapper, belowSubview: fixture.overlay)
        #expect(fixture.host.hitTest(CGPoint(x: 25, y: 50), with: nil) === marker)
        #expect(fixture.host.hitTest(CGPoint(x: 75, y: 50), with: nil) === fixture.overlay)
    }
}

/// End-to-end hit-testing of a hosted `AssistantMessageView` (ios#344): a
/// settled message carrying text AND a tool_use block enables the copy
/// overlay over the whole row, and a tap on the tool row's header must still
/// reach the header `Button` (expand / hydrate) instead of being claimed for
/// the copy interaction. The text region keeps the copy long-press, and a
/// tool-only message (no copy text, overlay inert) keeps expanding too.
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
        blocks.append(ContentBlock(id: "b-tool", type: .toolUse, name: "view", input: toolInput))
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

    /// Every accessibility element reachable from `root`, depth-first. Unlike
    /// `SyntheticBadgeHost.accessibilityElements(in:)` this also descends into
    /// SwiftUI's non-`UIView` container nodes, which is where a nested row's
    /// buttons and text live.
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

    /// Frame of the first accessibility element whose label (or value, for
    /// UIKit-backed text views) contains `fragment`, in window coordinates.
    private static func frame(
        ofElementContaining fragment: String,
        in hostView: UIView,
        window: UIWindow
    ) throws -> CGRect {
        var visited: Set<ObjectIdentifier> = []
        let elements = allAccessibilityElements(under: hostView, visited: &visited)
        let seen = elements.compactMap { element -> String? in
            let text = element.accessibilityLabel ?? element.accessibilityValue
            return text.map { "\(type(of: element))(\($0.prefix(60)))" }
        }.joined(separator: ", ")
        let element = try #require(
            elements.first { element in
                element.accessibilityLabel?.contains(fragment) == true
                    || element.accessibilityValue?.contains(fragment) == true
            },
            Comment(rawValue: "no accessibility element labelled with \(fragment); saw: [\(seen)]")
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

    /// The row's single copy overlay, with its frame in window coordinates.
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

    /// Window-level hit at `point`: must resolve to a non-nil view inside the
    /// hosted row whose own bounds contain the point.
    private static func requireHit(at point: CGPoint, in hostView: UIView, window: UIWindow) throws -> UIView {
        let hit = try #require(window.hitTest(point, with: nil), "nothing hit-tests at \(point)")
        try #require(hit.isDescendant(of: hostView), "hit \(hit) lies outside the hosted row")
        try #require(
            hit.point(inside: hit.convert(point, from: window), with: nil),
            "hit \(hit) does not contain \(point) in its own bounds"
        )
        return hit
    }

    /// Asserts a tap at the centre of the tool row's header lands on a view
    /// SwiftUI routes to the header `Button`: the header's own pass-through
    /// marker (sitting inside the header's accessibility frame, so not some
    /// other marker in the row) or — only where `allowingHostingView` —
    /// the hosting view itself, which is how plain SwiftUI content receives
    /// taps when no overlay competes for them. Never the copy overlay.
    private static func expectHeaderTapReachesButton(
        subject: String,
        in hostView: UIView,
        window: UIWindow,
        allowingHostingView: Bool = false
    ) throws {
        let headerFrame = try frame(ofElementContaining: subject, in: hostView, window: window)
        let point = CGPoint(x: headerFrame.midX, y: headerFrame.midY)
        let hit = try requireHit(at: point, in: hostView, window: window)
        #expect(!(hit is CopyContextMenuOverlay.OverlayView), "copy overlay swallowed the header tap")
        if allowingHostingView, hit === hostView { return }
        let marker = try #require(
            hit as? CopyContextMenuPassthroughMarker.MarkerView,
            "header tap resolved to \(hit) instead of the header's pass-through marker"
        )
        let markerFrame = window.convert(marker.bounds, from: marker)
        #expect(
            headerFrame.insetBy(dx: -1, dy: -1).contains(markerFrame),
            "marker \(markerFrame) is not the header's own (header \(headerFrame))"
        )
    }

    private func hitTest(
        includeText: Bool,
        probe: (_ hostView: UIView, _ window: UIWindow) throws -> Void
    ) throws {
        let coordinator = try Self.makeCoordinator()
        let view = AssistantMessageView(
            message: Self.makeMessage(includeText: includeText),
            workspaceId: "ws-1",
            onNavigateToNote: nil,
            hydratingBlockIds: [],
            onHydrateBlock: nil
        )
        .environment(coordinator)
        try SyntheticBadgeHost.render(view, width: Self.hostWidth, height: Self.hostHeight, inspect: probe)
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

    // Gated like the rendered badge tests: always true on the simulator, so a
    // missing header element there is a real failure, not a skip.
    @Test(.enabled(Self.accessibilityGate) { await SyntheticBadgeHost.publishesAccessibilityTree() })
    func toolRowHeaderTapReachesButtonInTextBearingMessage() throws {
        let subject = try toolSubject
        try hitTest(includeText: true) { hostView, window in
            // The copy interaction is live and spans the header: the overlay
            // is what would otherwise claim the tap.
            let overlay = try Self.copyOverlay(in: hostView, window: window)
            #expect(overlay.view.interactions.contains { $0 is UIContextMenuInteraction })
            let headerFrame = try Self.frame(ofElementContaining: subject, in: hostView, window: window)
            #expect(overlay.frame.contains(CGPoint(x: headerFrame.midX, y: headerFrame.midY)))
            try Self.expectHeaderTapReachesButton(subject: subject, in: hostView, window: window)
        }
    }

    @Test(.enabled(Self.accessibilityGate) { await SyntheticBadgeHost.publishesAccessibilityTree() })
    func textRegionKeepsCopyMenuInTextBearingMessage() throws {
        try hitTest(includeText: true) { hostView, window in
            let overlay = try Self.copyOverlay(in: hostView, window: window)
            #expect(
                overlay.view.interactions.contains { $0 is UIContextMenuInteraction },
                "copy interaction is not attached to a settled text-bearing message"
            )
            let textFrame = try Self.frame(ofElementContaining: Self.bodyText, in: hostView, window: window)
            let point = CGPoint(x: textFrame.midX, y: textFrame.midY)
            #expect(overlay.frame.contains(point), "overlay \(overlay.frame) does not cover the text at \(point)")
            // The overlay either claims the text touch itself or defers to
            // Textual's UITextInput-conforming text view beneath it (which
            // keeps its own selection / copy affordances); either way the
            // tap must not land on a pass-through marker.
            let hit = try Self.requireHit(at: point, in: hostView, window: window)
            #expect(
                hit === overlay.view || hit is UITextInput,
                "text region resolved to \(hit), neither the copy overlay nor a text input"
            )
            #expect(!(hit is CopyContextMenuPassthroughMarker.MarkerView))
        }
    }

    @Test(.enabled(Self.accessibilityGate) { await SyntheticBadgeHost.publishesAccessibilityTree() })
    func toolRowHeaderTapReachesButtonInToolOnlyMessage() throws {
        let subject = try toolSubject
        try hitTest(includeText: false) { hostView, window in
            // No copy text: the overlay is present but inert, so the tap
            // reaches the header with or without the marker (this case
            // already worked before ios#344 was fixed).
            let overlay = try Self.copyOverlay(in: hostView, window: window)
            #expect(
                !overlay.view.interactions.contains { $0 is UIContextMenuInteraction },
                "copy interaction attached to a message without copy text"
            )
            try Self.expectHeaderTapReachesButton(
                subject: subject,
                in: hostView,
                window: window,
                allowingHostingView: true
            )
        }
    }
}