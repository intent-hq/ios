@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct SettingsViewTests {
    @Test(arguments: [CGFloat(272), CGFloat(552)])
    func connectionCardGrowsForLargeTextAndLongAddresses(width: CGFloat) {
        let card = SettingsConnectionCard(name: "Work computer", address: "work.local:5181", status: .connected)
        let standard = size(of: card.environment(\.dynamicTypeSize, .large), width: width)
        let accessible = size(of: card.environment(\.dynamicTypeSize, .accessibility5), width: width)
        let longCard = SettingsConnectionCard(
            name: "Work computer with a long descriptive name",
            address: "primary-work-computer.local, backup-work-computer.local:5181",
            status: .connected
        )
        let longSize = size(of: longCard.environment(\.dynamicTypeSize, .accessibility5), width: width)
        #expect(standard.width <= width)
        #expect(accessible.width <= width)
        #expect(longSize.width <= width)
        #expect(accessible.height > standard.height)
        #expect(longSize.height > accessible.height)
    }

    @Test func appearanceChoicesReflowAtAccessibilitySizes() {
        let width: CGFloat = 272
        let selector = SettingsAppearanceSelector(selection: .constant("system"))
        let standard = size(of: selector.environment(\.dynamicTypeSize, .large), width: width)
        let accessible = size(of: selector.environment(\.dynamicTypeSize, .accessibility5), width: width)
        #expect(accessible.width <= width)
        #expect(accessible.height > standard.height)
    }

    @Test(arguments: ["light", "dark", "system"], [ColorScheme.light, .dark])
    func appearanceExposesSelectedChoiceToVoiceOver(selection: String, scheme: ColorScheme) async throws {
        try await SyntheticBadgeHost.render(
            SettingsAppearanceSelector(selection: .constant(selection)).environment(\.colorScheme, scheme),
            width: 320,
            height: 300
        ) { view, _ in
            let elements = Self.descendants(of: view)
            let choices = elements.filter { $0.accessibilityTraits.contains(.button) }
            #expect(choices.count == 3)
            let selected = choices.filter { $0.accessibilityTraits.contains(.selected) }
            #expect(selected.count == 1)
            #expect(selected.first.map { SyntheticBadgeHost.accessibilityIdentifier(of: $0) }
                == "settings.appearance.\(selection)")
        }
    }

    private func size(of view: some View, width: CGFloat) -> CGSize {
        let controller = UIHostingController(rootView: view)
        return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    @Test(arguments: [ConnectionState.connected, .connecting, .reconnecting(attempt: 1), .disconnected])
    func savedCardsExposeStatusOnlyForThisWindow(status: ConnectionState) async throws {
        var bound = AppCoordinatorTests.makeConnection(port: 1)
        bound.displayName = "Studio Mac"
        let other = AppCoordinatorTests.makeConnection(port: 2)
        let section = SettingsConnectionsSection(
            connections: [other, bound],
            windowConnectionID: bound.id,
            status: status,
            mismatches: []
        ) { _ in }
        try await SyntheticBadgeHost.render(section, width: 390, height: 600) { view, _ in
            let buttons = Self.descendants(of: view).filter { $0.accessibilityTraits.contains(.button) }
            let current = try #require(buttons.first { element in
                SyntheticBadgeHost.accessibilityIdentifier(of: element) == "settings.connection.\(bound.id)"
            })
            let saved = try #require(buttons.first { element in
                SyntheticBadgeHost.accessibilityIdentifier(of: element) == "settings.connection.\(other.id)"
            })
            #expect(current.accessibilityTraits.contains(.selected))
            #expect(!saved.accessibilityTraits.contains(.selected))
            let expected: String
            switch status {
            case .connected: expected = "Connected"
            case .connecting: expected = "Connecting"
            case .reconnecting: expected = "Reconnecting"
            case .disconnected: expected = "Disconnected"
            }
            #expect(current.accessibilityLabel?.contains(expected) == true)
            #expect(saved.accessibilityLabel?.contains(expected) == false)
            #expect(current.accessibilityLabel?.contains("Studio Mac") == true)
            #expect(saved.accessibilityLabel?.contains("10.0.0.1:2") == true)
        }
    }

    private static func descendants(of object: NSObject) -> [NSObject] {
        let count = object.accessibilityElementCount()
        let children = count == NSNotFound
            ? (object.accessibilityElements ?? []).compactMap { $0 as? NSObject }
            : (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
        let subviews = (object as? UIView)?.subviews ?? []
        return (object.isAccessibilityElement ? [object] : [])
            + children.flatMap(descendants(of:)) + subviews.flatMap(descendants(of:))
    }
}
