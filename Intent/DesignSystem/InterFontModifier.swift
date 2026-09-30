import SwiftUI

extension View {
    /// Apply only to text / text inputs, never a screen or a Label's symbol.
    /// Custom fonts scale with Dynamic Type but need an explicit face for Bold Text.
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
