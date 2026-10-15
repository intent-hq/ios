@testable import Intent
import Observation
import SwiftUI
import Testing
import UIKit

@MainActor
struct IPadNavigationVisibilityTests {
    @Test func hiddenPaneDisablesOnlyItsNavigationController() {
        let fixture = Fixture(isInteractive: false)
        let sibling = UINavigationController(rootViewController: UIViewController())
        let container = UIViewController()
        container.addChild(fixture.navigation)
        container.addChild(sibling)

        #expect(fixture.navigation.view.accessibilityElementsHidden)
        #expect(!fixture.navigation.view.isUserInteractionEnabled)
        #expect(!sibling.view.accessibilityElementsHidden)
        #expect(sibling.view.isUserInteractionEnabled)
        #expect(container.view.isUserInteractionEnabled)

        fixture.marker.isInteractive = true
        #expect(!fixture.navigation.view.accessibilityElementsHidden)
        #expect(fixture.navigation.view.isUserInteractionEnabled)
    }

    @Test func retainedRootControlsPushedDestinationsWithoutReplacingThem() {
        let fixture = Fixture()
        let destination = UIViewController()
        fixture.navigation.setViewControllers([fixture.root, destination], animated: false)

        fixture.marker.isInteractive = false
        #expect(fixture.navigation.view.accessibilityElementsHidden)
        #expect(!fixture.navigation.view.isUserInteractionEnabled)
        fixture.marker.isInteractive = true
        #expect(!fixture.navigation.view.accessibilityElementsHidden)
        #expect(fixture.navigation.view.isUserInteractionEnabled)
        #expect(fixture.navigation.topViewController === destination)
        #expect(fixture.navigation.viewControllers.first === fixture.root)
    }

    @Test(arguments: [false, true], [false, true])
    func teardownRestoresOriginalFlags(hidden: Bool, interactive: Bool) {
        let fixture = Fixture(originalHidden: hidden, originalInteractive: interactive)
        fixture.marker.isInteractive = false
        fixture.marker.restoreVisibility()
        fixture.marker.restoreVisibility()
        #expect(fixture.navigation.view.accessibilityElementsHidden == hidden)
        #expect(fixture.navigation.view.isUserInteractionEnabled == interactive)
    }

    @Test func detachingHiddenMarkerRestoresItsFormerController() {
        let fixture = Fixture(isInteractive: false)
        fixture.marker.willMove(toParent: nil)
        fixture.marker.removeFromParent()
        #expect(!fixture.navigation.view.accessibilityElementsHidden)
        #expect(fixture.navigation.view.isUserInteractionEnabled)

        let next = UINavigationController(rootViewController: UIViewController())
        let root = next.viewControllers[0]
        root.addChild(fixture.marker)
        fixture.marker.didMove(toParent: root)
        #expect(next.view.accessibilityElementsHidden)
        #expect(!next.view.isUserInteractionEnabled)
        #expect(fixture.navigation.view.isUserInteractionEnabled)
    }

    @Test func missingNavigationControllerLeavesEnclosingViewAlone() {
        let parent = UIViewController()
        let marker = IPadNavigationVisibilityBridge.Controller()
        marker.isInteractive = false
        parent.addChild(marker)
        marker.didMove(toParent: parent)
        marker.viewDidLayoutSubviews()
        #expect(!parent.view.accessibilityElementsHidden)
        #expect(parent.view.isUserInteractionEnabled)
    }

    @Test func layoutFindsNavigationAfterInitialParentAttachment() {
        let root = UIViewController()
        let marker = IPadNavigationVisibilityBridge.Controller()
        marker.isInteractive = false
        root.addChild(marker)
        marker.didMove(toParent: root)
        let navigation = UINavigationController(rootViewController: root)

        marker.viewDidLayoutSubviews()

        #expect(navigation.view.accessibilityElementsHidden)
        #expect(!navigation.view.isUserInteractionEnabled)
        marker.isInteractive = true
        #expect(!navigation.view.accessibilityElementsHidden)
        #expect(navigation.view.isUserInteractionEnabled)
    }

    private final class Fixture {
        let root = UIViewController()
        let navigation: UINavigationController
        let marker = IPadNavigationVisibilityBridge.Controller()

        init(isInteractive: Bool = true, originalHidden: Bool = false, originalInteractive: Bool = true) {
            navigation = UINavigationController(rootViewController: root)
            navigation.view.accessibilityElementsHidden = originalHidden
            navigation.view.isUserInteractionEnabled = originalInteractive
            let wrapper = UIViewController()
            root.addChild(wrapper)
            wrapper.didMove(toParent: root)
            marker.isInteractive = isInteractive
            wrapper.addChild(marker)
            marker.didMove(toParent: wrapper)
        }
    }
}

extension IPadNavigationVisibilityTests {
    @Test func retainedProducerHidingComparison() async throws {
        let state = ProducerVisibilityState()
        try await SyntheticBadgeHost.render(
            ProducerVisibilityFixture(state: state), width: ProducerVisibilityState.width, height: ProducerVisibilityState.height
        ) { host, _ in
            try await waitUntil("the diagnostic editor appears") { !IPadVisibilityDiagnostics.editors(in: host).isEmpty }
            let editor = try #require(IPadVisibilityDiagnostics.editors(in: host).first)
            let draft = state.draft
            let selectedText = try #require(draft.range(of: "this"))
            let selection = NSRange(selectedText, in: draft)
            editor.selectedRange = selection
            var hiddenLeaves: [String: [String]] = [:]
            for phase in ProducerVisibilityState.phases {
                state.phase = phase
                let snapshot = try await producerSnapshot(in: host, state: state, editor: editor)
                #expect(IPadVisibilityDiagnostics.editors(in: host).count == 1)
                #expect(IPadVisibilityDiagnostics.editors(in: host).first === editor)
                #expect(editor.text == draft)
                #expect(state.draft == draft)
                #expect(editor.selectedRange == selection)
                try #require(!snapshot.truncated, "A bounded provider walk must not silently omit evidence")
                if phase.visible {
                    try #require(
                        ProducerVisibilityState.sentinels.isSubset(of: Set(snapshot.leaves)),
                        "Invalid diagnostic: visible provider sentinels are missing; do not infer successful hiding"
                    )
                } else {
                    hiddenLeaves[phase.name] = snapshot.leaves
                }
            }
            // This compares observations, not a presumed fix. UI exclusion assertions remain separate.
            Attachment.record(try JSONEncoder().encode(hiddenLeaves), named: "ipad-producer-hiding-comparison.json")
        }
    }

    private func producerSnapshot(in host: UIView, state: ProducerVisibilityState, editor: UITextView) async throws -> ProducerProviderSnapshot {
        let phase = state.phase
        do {
            try await waitUntil("the diagnostic phase and native gate settle") {
                host.layoutIfNeeded()
                let snapshot = ProducerProviderSnapshot(host: host, editor: editor)
                let marker = ProducerVisibilityFixture.marker(in: host.window?.rootViewController)
                return snapshot.nodes.contains { $0.identifier == "visibility.phase" && $0.label == phase.name }
                    && (!phase.visible || ProducerVisibilityState.sentinels.isSubset(of: Set(snapshot.leaves)))
                    && marker?.isInteractive == phase.visible
                    && marker?.navigationController?.viewIfLoaded?.accessibilityElementsHidden == !phase.visible
                    && marker?.navigationController?.viewIfLoaded?.isUserInteractionEnabled == phase.visible
            }
        } catch {
            let snapshot = ProducerProviderSnapshot(host: host, editor: editor)
            Attachment.record(try JSONEncoder().encode(snapshot), named: "ipad-producer-\(phase.name)-invalid.json")
            throw error
        }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        host.layoutIfNeeded()
        let snapshot = ProducerProviderSnapshot(host: host, editor: editor)
        Attachment.record(try JSONEncoder().encode(snapshot), named: "ipad-producer-\(phase.name).json")
        return snapshot
    }
}

@MainActor @Observable
private final class ProducerVisibilityState {
    struct Phase {
        let name: String
        let visible: Bool
        let direct: Bool
    }

    static let width: CGFloat = 1000
    static let height: CGFloat = 700
    static let editorHeight: CGFloat = 100
    static let sentinels: Set<String> = ["visibility.row", "visibility.list.header", "visibility.content.header", "composer.textView"]
    static let phases = [
        Phase(name: "visible", visible: true, direct: false),
        Phase(name: "outer-hidden", visible: false, direct: false),
        Phase(name: "outer-restored", visible: true, direct: false),
        Phase(name: "producer-hidden", visible: false, direct: true),
        Phase(name: "producer-restored", visible: true, direct: false)
    ]
    var phase = ProducerVisibilityState.phases[0]
    var draft = "Keep this selected draft"
    var focused = false
}

private struct ProducerVisibilityFixture: View {
    @Bindable var state: ProducerVisibilityState

    var body: some View {
        VStack {
            Text(state.phase.name).accessibilityIdentifier("visibility.phase")
            HStack {
                listPane
                detailPane
            }
        }
        .transaction { $0.disablesAnimations = true }
    }

    private var listPane: some View {
        RetainedIPadPane(isVisible: state.phase.visible) {
            List {
                Section {
                    Text("List row")
                        .accessibilityIdentifier("visibility.row")
                        .accessibilityHidden(true, isEnabled: state.phase.direct)
                } header: {
                    Text("List header")
                        .accessibilityIdentifier("visibility.list.header")
                        .accessibilityHidden(true, isEnabled: state.phase.direct)
                }
            }
            .accessibilityIdentifier("visibility.list")
            .accessibilityHidden(true, isEnabled: state.phase.direct)
        }
        .modifier(IPadPaneBounds(identifier: "visibility.sidebar", isAccessible: state.phase.visible))
    }

    private var detailPane: some View {
        RetainedIPadPane(isVisible: state.phase.visible) {
            NavigationStack {
                VStack {
                    SubmittableTextView(text: $state.draft, isFocused: $state.focused) {}
                        .accessibilityHidden(true, isEnabled: state.phase.direct)
                        .frame(height: ProducerVisibilityState.editorHeight)
                }
                .modifier(IPadNavigationVisibility())
                .safeAreaInset(edge: .top) {
                    Text("Content header")
                        .accessibilityIdentifier("visibility.content.header")
                        .accessibilityHidden(true, isEnabled: state.phase.direct)
                }
            }
        }
        .modifier(IPadPaneBounds(identifier: "visibility.detail", isAccessible: state.phase.visible))
    }

    @MainActor static func marker(in controller: UIViewController?) -> IPadNavigationVisibilityBridge.Controller? {
        guard let controller else { return nil }
        if let marker = controller as? IPadNavigationVisibilityBridge.Controller { return marker }
        return controller.children.lazy.compactMap { marker(in: $0) }.first
    }
}

/// Provider edges only: never infer accessibility exposure from UIView.subviews.
private struct ProducerProviderSnapshot: Encodable {
    struct Node: Encodable {
        let identity: String
        let identifier: String?
        let label: String?
        let element: Bool
        let childrenHidden: Bool
    }

    struct Edge: Encodable {
        let parent: Int
        let child: Int
        let source: String
    }

    private static let capacity = 128
    private static let edgeCapacity = 256
    private(set) var nodes: [Node] = []
    private(set) var edges: [Edge] = []
    private(set) var truncated = false
    let editorAncestors: [String]
    let editorSelection: String
    let editorTextLength: Int
    @MainActor var leaves: [String] {
        nodes.compactMap { $0.element ? $0.identifier : nil }.filter { ProducerVisibilityState.sentinels.contains($0) }.sorted()
    }

    @MainActor init(host: UIView, editor: UITextView) {
        editorSelection = NSStringFromRange(editor.selectedRange)
        editorTextLength = editor.text.utf16.count
        var ancestors: [String] = []
        var ancestor: UIView? = editor
        while let view = ancestor {
            ancestors.append(
                "\(ObjectIdentifier(view)) axElement=\(view.isAccessibilityElement) childrenHidden=\(view.accessibilityElementsHidden) "
                    + "interaction=\(view.isUserInteractionEnabled) alpha=\(view.alpha)"
            )
            ancestor = view.superview
        }
        editorAncestors = ancestors
        var visited: [ObjectIdentifier: Int] = [:]
        visit(host, parent: nil, source: "root", visited: &visited)
    }

    @MainActor private mutating func visit(_ object: NSObject, parent: Int?, source: String, visited: inout [ObjectIdentifier: Int]) {
        guard edges.count < Self.edgeCapacity else { truncated = true; return }
        let identity = ObjectIdentifier(object)
        if let index = visited[identity] {
            if let parent { edges.append(Edge(parent: parent, child: index, source: source)) }
            return
        }
        guard nodes.count < Self.capacity else { truncated = true; return }
        let index = nodes.count
        visited[identity] = index
        nodes.append(Node(
            identity: String(describing: identity),
            identifier: SyntheticBadgeHost.accessibilityIdentifier(of: object),
            label: object.accessibilityLabel,
            element: object.isAccessibilityElement,
            childrenHidden: object.accessibilityElementsHidden
        ))
        if let parent { edges.append(Edge(parent: parent, child: index, source: source)) }
        visitChildren(of: object, parent: index, visited: &visited)
    }

    @MainActor private mutating func visitChildren(of object: NSObject, parent: Int, visited: inout [ObjectIdentifier: Int]) {
        let children = (object.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        if children.count > Self.capacity { truncated = true }
        for child in children.prefix(Self.capacity) {
            visit(child, parent: parent, source: "accessibilityElements", visited: &visited)
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            if count > Self.capacity { truncated = true }
            for offset in 0..<min(count, Self.capacity) {
                if let child = object.accessibilityElement(at: offset) as? NSObject {
                    visit(child, parent: parent, source: "accessibilityElement(at:)", visited: &visited)
                }
            }
        }
    }
}

/// Passive observations of the existing host; never force-load a controller view.
@MainActor
enum IPadVisibilityDiagnostics {
    static func record(_ phase: String, in host: UIView, coordinator: AppCoordinator, trace: SyntheticBadgeHostTrace) async {
        host.layoutIfNeeded()
        // Let queued SwiftUI bindings run before sampling the settled native flags.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        host.layoutIfNeeded()
        let markers = navigationMarkers(in: host.window?.rootViewController)
        var fields = [
            "section": coordinator.iPadNavigation.section.rawValue,
            "detail": String(describing: coordinator.iPadNavigation.detail),
            "focus": String(describing: coordinator.iPadNavigation.focusPresentation),
            "sidebarVisible": String(coordinator.iPadNavigation.isSidebarVisible),
            "host": describe(host),
            "markerCount": String(markers.count),
            "enumeration": "Structural host traversal includes hidden views; it is not XCTest.exists or VoiceOver navigation."
        ]
        recordMarkers(markers, fields: &fields)
        recordEditors(editors(in: host), markers: markers, fields: &fields)
        recordAccessibility(in: host, fields: &fields)
        trace.record("ipad.visibility.\(phase)", fields: fields)
    }

    private static func recordMarkers(_ markers: [IPadNavigationVisibilityBridge.Controller], fields: inout [String: String]) {
        for (index, marker) in markers.enumerated() {
            let prefix = "marker.\(index)"
            fields["\(prefix).id"] = identity(marker)
            fields["\(prefix).isInteractive"] = String(marker.isInteractive)
            fields["\(prefix).parent"] = identity(marker.parent)
            fields["\(prefix).navigationController"] = identity(marker.navigationController)
            fields["\(prefix).navigationView"] = describe(marker.navigationController?.viewIfLoaded)
            fields["\(prefix).view"] = describe(marker.viewIfLoaded)
        }
    }

    private static func recordEditors(
        _ composers: [UITextView], markers: [IPadNavigationVisibilityBridge.Controller], fields: inout [String: String]
    ) {
        fields["editorCount"] = String(composers.count)
        for (index, editor) in composers.enumerated() {
            let prefix = "editor.\(index)"
            fields["\(prefix).view"] = describe(editor)
            fields["\(prefix).firstResponder"] = String(editor.isFirstResponder)
            fields["\(prefix).selection"] = NSStringFromRange(editor.selectedRange)
            fields["\(prefix).textLength"] = String(editor.text.utf16.count)
            var ancestor: UIView? = editor
            var depth = 0
            while let current = ancestor {
                fields["\(prefix).ancestor.\(depth)"] = describe(current)
                ancestor = current.superview
                depth += 1
            }
            for (markerIndex, marker) in markers.enumerated() {
                let target = marker.navigationController?.viewIfLoaded
                fields["\(prefix).insideMarker.\(markerIndex)"] = target.map { String(editor.isDescendant(of: $0)) } ?? "unloaded"
            }
        }
    }

    static func editors(in host: UIView) -> [UITextView] {
        var result: [UITextView] = []
        if let editor = host as? UITextView, editor.accessibilityIdentifier == "composer.textView" { result.append(editor) }
        for child in host.subviews { result += editors(in: child) }
        return result
    }

    private static func navigationMarkers(in controller: UIViewController?) -> [IPadNavigationVisibilityBridge.Controller] {
        guard let controller else { return [] }
        var result: [IPadNavigationVisibilityBridge.Controller] = []
        if let marker = controller as? IPadNavigationVisibilityBridge.Controller { result.append(marker) }
        for child in controller.children { result += navigationMarkers(in: child) }
        return result
    }

    private static func identity(_ object: AnyObject?) -> String {
        object.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
    }

    private static func describe(_ view: UIView?) -> String {
        guard let view else { return "unloaded" }
        return "id=\(identity(view)) type=\(String(reflecting: type(of: view))) identifier=\(view.accessibilityIdentifier ?? "nil") "
            + "frame=\(view.frame) windowFrame=\(view.convert(view.bounds, to: view.window)) "
            + "hidden=\(view.isHidden) alpha=\(view.alpha) axElement=\(view.isAccessibilityElement) "
            + "axChildrenHidden=\(view.accessibilityElementsHidden) interaction=\(view.isUserInteractionEnabled)"
    }

    private static func recordAccessibility(in host: UIView, fields: inout [String: String]) {
        let identifiers: Set<String> = [
            "ipad.sidebar.panel", "ipad.detail.panel", "workspaces.menu", "workspaces.list",
            "workspaces.search.field", "settings.scroll", "composer.textView", "ipad.focus.close"
        ]
        let elements = SyntheticBadgeHost.accessibilityElements(in: host).filter { element in
            identifiers.contains(SyntheticBadgeHost.accessibilityIdentifier(of: element) ?? "")
        }
        for (index, element) in elements.enumerated() {
            fields["ax.\(index)"] = "id=\(identity(element)) identifier=\(SyntheticBadgeHost.accessibilityIdentifier(of: element) ?? "nil") "
                + "frame=\(element.accessibilityFrame) axElement=\(element.isAccessibilityElement) childrenHidden=\(element.accessibilityElementsHidden)"
            var current: NSObject? = element
            var visited: Set<ObjectIdentifier> = []
            var chain: [String] = []
            while let item = current, visited.insert(ObjectIdentifier(item)).inserted {
                chain.append(identity(item))
                current = (item as? UIAccessibilityElement)?.accessibilityContainer as? NSObject
            }
            fields["ax.\(index).publicContainerChain"] = chain.joined(separator: " -> ")
        }
    }
}
