@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
struct WorkspaceStatusPillWidthTests {
    private let cap = Constants.Conversation.Design.Status.pillMaximumWidth

    @Test func longLabelsTruncateAtTheSharedCapInAnUnboundedRow() {
        let name = String(repeating: "Build verification with a long script name ", count: 4)
        let pill = WorkspaceStatusPill(icon: .eye, text: Text(verbatim: "Watching \(name)"), truncates: true)
        #expect(width(of: pill) <= cap + 1)
    }

    @Test func shortLabelsKeepTheirNaturalWidth() {
        let pill = WorkspaceStatusPill(icon: .eye, text: Text(verbatim: "Watching"), truncates: true)
        #expect(width(of: pill) < cap)
    }

    private func width(of view: some View) -> CGFloat {
        let controller = UIHostingController(rootView: view.environment(\.dynamicTypeSize, .large))
        return controller.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width
    }
}
