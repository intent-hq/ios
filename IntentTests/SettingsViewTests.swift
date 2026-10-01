@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct SettingsViewTests {
    @Test func appearanceChoicesReflowAtAccessibilitySizes() {
        let width: CGFloat = 272
        let selector = SettingsAppearanceSelector(selection: .constant("system"))
        let standard = size(of: selector.environment(\.dynamicTypeSize, .large), width: width)
        let accessible = size(of: selector.environment(\.dynamicTypeSize, .accessibility5), width: width)
        #expect(accessible.width <= width)
        #expect(accessible.height > standard.height)
    }

    @Test(arguments: [CGFloat(272), CGFloat(552)])
    func actionLabelGrowsWithoutOverflowingAtAccessibilitySizes(width: CGFloat) {
        let label = SettingsActionLabel(title: "Manual Connection", image: .connectManual)
        let standard = size(of: label.environment(\.dynamicTypeSize, .large), width: width)
        let accessible = size(of: label.environment(\.dynamicTypeSize, .accessibility5), width: width)
        #expect(standard.width <= width)
        #expect(accessible.width <= width)
        #expect(standard.height >= SettingsStyle.rowHeight)
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
