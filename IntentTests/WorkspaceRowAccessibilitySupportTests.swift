import Foundation
@testable import Intent
import SwiftUI
import Testing
import UIKit

extension WorkspaceRowPresentationTests {
    private static let mergedPullRequestNumber = 123_456_789
    private static let additionalPullRequestCount = 100
    private static let renderedBadgeHostHeight: CGFloat = 300
    private static let runLoopObservationInterval = 0.01
    private static let maximumClassNameLength = 80

    static var badgeLabels: [String?] {
        [
            "Merged pull request #123456789", "100 additional pull requests"
        ]
    }

    static var badgeIdentifiers: [String] {
        [
            WorkspaceRowView.BadgeIdentifier.pullRequest,
            WorkspaceRowView.BadgeIdentifier.additionalPullRequests
        ]
    }

    struct RenderedBadge {
        let identifier: String
        let label: String?
        let frame: CGRect
    }

    struct RenderedBadges {
        let hostFrame: CGRect
        let badges: [RenderedBadge]
    }

    // Badges are located by their stable accessibility identifier; the spoken
    // label is asserted separately so a copy change cannot masquerade as a
    // missing element.
    func renderBadges(width: CGFloat) async throws -> RenderedBadges {
        let indicator = WorkspaceRowView.PrIndicatorModel(
            pill: .init(status: .merged, number: Self.mergedPullRequestNumber),
            otherMonitorCount: Self.additionalPullRequestCount
        )
        let rootView = WorkspaceRowView.PullRequestBadges(
            indicator: indicator,
            colorScheme: .light,
            colorSchemeContrast: .standard,
            expanded: true
        )
        .environment(\.dynamicTypeSize, .accessibility3)
        return try await SyntheticBadgeHost.render(
            rootView,
            width: width,
            height: Self.renderedBadgeHostHeight
        ) { hostView, window in
            let identifiers = Self.badgeIdentifiers
            let elements = SyntheticBadgeHost.accessibilityElements(in: hostView)
            let initialBadges = initialBadgeFrames(identifiers: identifiers, elements: elements)
            if initialBadges.contains(where: { $0 == nil }) {
                let immediate = accessibilityGraphSnapshot(
                    root: window,
                    expectedIdentifiers: identifiers
                )
                _ = RunLoop.current.run(
                    mode: .default,
                    before: Date(timeIntervalSinceNow: Self.runLoopObservationInterval)
                )
                let observed = accessibilityGraphSnapshot(
                    root: window,
                    expectedIdentifiers: identifiers
                )
                print("SYNTHETIC PR badge accessibility graph immediate:\n\(immediate)")
                print("SYNTHETIC PR badge accessibility graph after run-loop observation:\n\(observed)")
            }
            let badges = try initialBadges.map { initialBadge in
                try #require(initialBadge)
            }
            let hostFrame = hostView.convert(hostView.bounds, to: nil)
            return RenderedBadges(hostFrame: hostFrame, badges: badges)
        }
    }

    func initialBadgeFrames(
        identifiers: [String],
        elements: [NSObject]
    ) -> [RenderedBadge?] {
        identifiers.map { identifier in
            elements
                .first { element in
                    SyntheticBadgeHost.accessibilityIdentifier(of: element) == identifier
                }
                .map { element in
                    RenderedBadge(
                        identifier: identifier,
                        label: element.accessibilityLabel,
                        frame: element.accessibilityFrame
                    )
                }
        }
    }

    func accessibilityViewFacts(for object: NSObject) -> String {
        guard let view = object as? UIView else {
            return "attached=na hidden=na bounds=na"
        }
        return "attached=\(view.window != nil) hidden=\(view.isHidden) bounds=\(view.bounds)"
    }

    func accessibilityGraphSnapshot(
        root: NSObject,
        expectedIdentifiers: [String],
        maxNodes: Int = 64,
        maxDepth: Int = 8,
        maxOutputCharacters: Int = 32_768
    ) -> String {
        var visited: Set<ObjectIdentifier> = []
        var lines: [String] = []

        func visit(_ object: NSObject, path: String, depth: Int) {
            guard depth <= maxDepth, visited.count < maxNodes else { return }
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }

            let propertyChildren = (object.accessibilityElements ?? [])
                .prefix(maxNodes)
                .compactMap { $0 as? NSObject }
            let elementCount = object.accessibilityElementCount()
            let dynamicChildren: [NSObject]
            if elementCount == NSNotFound || elementCount < 0 {
                dynamicChildren = []
            } else {
                dynamicChildren = (0..<min(elementCount, maxNodes)).compactMap { index in
                    object.accessibilityElement(at: index) as? NSObject
                }
            }
            let subviews =
                (object as? UIView).map { view in
                    Array(view.subviews.prefix(maxNodes))
                } ?? []
            let label = object.accessibilityLabel
            let identifier = SyntheticBadgeHost.accessibilityIdentifier(of: object)
            let identifierMatches = expectedIdentifiers.map { identifier == $0 }
                .map { String($0) }
                .joined(separator: ",")
            let countDescription = elementCount == NSNotFound ? "NSNotFound" : "\(elementCount)"
            let className = String(String(describing: type(of: object)).prefix(Self.maximumClassNameLength))
            let viewFacts = accessibilityViewFacts(for: object)
            lines.append(
                "depth=\(depth) path=\(path) class=\(className) \(viewFacts) "
                    + "frame=\(object.accessibilityFrame) elementCount=\(countDescription) "
                    + "children=[property:\(propertyChildren.count),dynamic:\(dynamicChildren.count),"
                    + "subviews:\(subviews.count)] labelPresent=\(label != nil) "
                    + "identifierMatches=[\(identifierMatches)]"
            )

            guard depth < maxDepth else { return }
            for (index, child) in propertyChildren.enumerated() {
                visit(child, path: "\(path).property[\(index)]", depth: depth + 1)
            }
            for (index, child) in dynamicChildren.enumerated() {
                visit(child, path: "\(path).dynamic[\(index)]", depth: depth + 1)
            }
            for (index, child) in subviews.enumerated() {
                visit(child, path: "\(path).subview[\(index)]", depth: depth + 1)
            }
        }

        visit(root, path: "root", depth: 0)
        return String(lines.joined(separator: "\n").prefix(maxOutputCharacters))
    }

    final class DynamicAccessibilityContainer: UIView {
        private lazy var dynamicElement: UIAccessibilityElement = {
            let element = UIAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = "Dynamic container element"
            return element
        }()

        override func accessibilityElementCount() -> Int { 1 }

        override func accessibilityElement(at index: Int) -> Any? {
            index == 0 ? dynamicElement : nil
        }

        override func index(ofAccessibilityElement element: Any) -> Int {
            element as AnyObject === dynamicElement ? 0 : NSNotFound
        }
    }

    final class NonViewAccessibilityContainer: NSObject {
        lazy var dynamicElement = UIAccessibilityElement(accessibilityContainer: self)

        override func accessibilityElementCount() -> Int { 1 }

        override func accessibilityElement(at index: Int) -> Any? {
            index == 0 ? dynamicElement : nil
        }

        override func index(ofAccessibilityElement element: Any) -> Int {
            element as AnyObject === dynamicElement ? 0 : NSNotFound
        }
    }
}
