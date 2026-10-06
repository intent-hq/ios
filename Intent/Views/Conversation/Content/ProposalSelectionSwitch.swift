import SwiftUI

struct ProposalSelectionSwitch: View {
    let isOn: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.workspaceTranscriptDesign) private var usesWorkspaceDesign

    private typealias Palette = Constants.Conversation.Design.Palette

    private enum Layout {
        static let width: CGFloat = 56
        static let height: CGFloat = 28
        static let thumbWidth: CGFloat = 28
        static let inset: CGFloat = 3
        static let animationDuration = 0.18
    }

    var body: some View {
        Capsule()
            .fill(trackColor)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(thumbColor)
                    .frame(width: Layout.thumbWidth, height: Layout.height - Layout.inset * 2)
                    .padding(.horizontal, Layout.inset)
            }
            .frame(width: Layout.width, height: Layout.height)
            .overlay {
                if usesWorkspaceDesign {
                    Capsule().strokeBorder(Palette.border(for: colorScheme, contrast: contrast))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: Layout.animationDuration), value: isOn)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private var trackColor: Color {
        if usesWorkspaceDesign {
            return isEnabled && isOn ? Palette.accent : Palette.raisedSurface(for: colorScheme)
        }
        guard isEnabled else { return Color(uiColor: .systemGray5) }
        guard isOn else { return Color(uiColor: .systemGray3) }
        return colorScheme == .dark ? .black : Color(.assistantAccent)
    }

    private var thumbColor: Color {
        if usesWorkspaceDesign {
            return isEnabled && isOn ? Palette.onAccent : Palette.secondaryForeground(for: colorScheme, contrast: contrast)
        }
        guard isEnabled else { return Theme.background(for: colorScheme) }
        guard isOn else { return .white }
        return colorScheme == .dark ? Color(.assistantAccent) : .black
    }
}
