@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct SettingsViewTests {
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

    private func size(of view: some View, width: CGFloat) -> CGSize {
        let controller = UIHostingController(rootView: view)
        return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
