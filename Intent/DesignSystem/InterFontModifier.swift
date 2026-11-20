import SwiftUI

extension View {
    func interFont(_ style: Constants.Typography.Style) -> some View {
        modifier(InterFontModifier(style: style))
    }
}

private struct InterFontModifier: ViewModifier {
    @Environment(\.legibilityWeight) private var legibilityWeight
    let style: Constants.Typography.Style

    func body(content: Content) -> some View {
        content.font(style.font(legibilityWeight: legibilityWeight))
    }
}
