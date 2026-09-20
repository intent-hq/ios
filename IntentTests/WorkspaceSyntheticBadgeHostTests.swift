@testable import Intent
import SwiftUI
import Testing
import UIKit

/// Hosts a SwiftUI view in a synthetic window for the rendered badge tests and
/// for the accessibility-tree probe that gates them.
@MainActor
enum SyntheticBadgeHost {
    static let probeIdentifier = "workspaceRow.syntheticHost.probe"
    private static let probeWidth: CGFloat = 200
    private static let probeHeight: CGFloat = 100

    static func render<Content: View, Result>(
        _ content: Content,
        width: CGFloat,
        height: CGFloat,
        inspect: (_ hostView: UIView, _ window: UIWindow) throws -> Result
    ) throws -> Result {
        try autoreleasepool {
            let rootView = content.frame(width: width, height: height, alignment: .topLeading)
            let controller = UIHostingController(rootView: rootView)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
            window.rootViewController = controller
            window.isHidden = false
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            return try inspect(controller.view, window)
        }
    }

    /// Whether a hosted SwiftUI view exposes its accessibility elements at all.
    /// The simulator lane always enables accessibility (scripts/xcodebuild.sh), so
    /// the probe is only consulted on a physical device; a simulator regression
    /// must surface as a failing badge test, not a skip.
    static func publishesAccessibilityTree() -> Bool {
        #if targetEnvironment(simulator)
            return true
        #else
            let probe = Text("probe").accessibilityIdentifier(probeIdentifier)
            let found = try? render(probe, width: probeWidth, height: probeHeight) { hostView, _ in
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
    @Test func renderUsesRootViewControllerContainment() throws {
        try SyntheticBadgeHost.render(Text("content"), width: 200, height: 100) { hostView, window in
            let controller = try #require(window.rootViewController)
            #expect(controller.view === hostView)
            #expect(hostView.window === window)
            #expect(hostView.frame == window.bounds)
        }
    }
}
