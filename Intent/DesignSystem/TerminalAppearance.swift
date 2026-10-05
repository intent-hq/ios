import SwiftUI
import UIKit

enum TerminalAppearance {
    private static let canvasWhite: CGFloat = 0.065
    private static let foregroundWhite: CGFloat = 0.88
    private static let accentRed: CGFloat = 0.25
    private static let accentGreen: CGFloat = 0.83
    private static let accentBlue: CGFloat = 0.61
    private static let mutedOpacity = 0.52
    private static let controlOpacity = 0.10
    private static let borderOpacity = 0.12
    private static let selectedOpacity = 0.20
    static let canvas = UIColor(white: canvasWhite, alpha: 1)
    static let foreground = UIColor(white: foregroundWhite, alpha: 1)
    static let accent = UIColor(red: accentRed, green: accentGreen, blue: accentBlue, alpha: 1)
    static let background = Color(uiColor: canvas)
    static let green = Color(uiColor: accent)
    static let muted = Color.white.opacity(mutedOpacity)
    static let controlFill = Color.white.opacity(controlOpacity)
    static let controlBorder = Color.white.opacity(borderOpacity)
    static let pressedFill = Color.white.opacity(selectedOpacity)
    static let activeFill = green.opacity(selectedOpacity)
    static let horizontalInset: CGFloat = 16
    static let headerSpacing: CGFloat = 14
    static let headerBottomInset: CGFloat = 28
    static let terminalInset: CGFloat = 12
    static let controlSize: CGFloat = 46
    static let keyWidth: CGFloat = 42
    static let keySpacing: CGFloat = 2
    static let groupSpacing: CGFloat = 8
    static let groupInset: CGFloat = 4
    static let keyFontSize: CGFloat = 15
    static let terminalFontSize: CGFloat = 15
    static let rowCornerRadius: CGFloat = 18
}

struct TerminalControlStyle: ButtonStyle {
    var isSelected = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? (isSelected ? TerminalAppearance.green : .white) : TerminalAppearance.muted)
            .background {
                Capsule()
                    .fill(configuration.isPressed ? TerminalAppearance.pressedFill : .clear)
            }
            .contentShape(Capsule())
    }
}

struct TerminalControlSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(TerminalAppearance.controlFill, in: Capsule())
            .overlay(Capsule().strokeBorder(TerminalAppearance.controlBorder, lineWidth: 1))
    }
}
