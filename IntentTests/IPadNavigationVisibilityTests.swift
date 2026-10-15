@testable import Intent
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
        let elements = SyntheticBadgeHost.accessibilityElements(in: host).filter {
            identifiers.contains(SyntheticBadgeHost.accessibilityIdentifier(of: $0) ?? "")
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
