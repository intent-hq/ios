import SwiftUI

/// For controls whose labels own their layout and enabled/disabled colors.
struct IntentContentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? Constants.ConnectionSheet.pressedOpacity : 1)
    }
}

struct IntentIconButton: View {
    let icon: ImageResource
    let label: LocalizedStringKey
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(icon)
                .resizable()
                .scaledToFit()
                .frame(width: WorkspaceDetailStyle.iconSize, height: WorkspaceDetailStyle.iconSize)
                .foregroundStyle(isEnabled
                    ? Constants.Pairing.foreground(for: colorScheme)
                    : CreateWorkspaceFormStyle.disabledForeground(for: colorScheme))
                .frame(width: WorkspaceDetailStyle.controlSize, height: WorkspaceDetailStyle.controlSize)
                .background { WorkspaceControlSurface() }
                .contentShape(.rect(cornerRadius: Constants.WorkspaceSearch.cornerRadius))
                .accessibilityHidden(true)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel(label)
    }
}

/// Filled actions from the Intent button palette, with explicit interaction states.
struct IntentButtonStyle: ButtonStyle {
    enum Variant {
        case muted
        case primary
        case secondary
    }

    var variant: Variant = .primary
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    private enum Layout {
        static let horizontalPadding: CGFloat = 20
        static let verticalPadding: CGFloat = 12
        static let minimumHeight: CGFloat = 44
        static let cornerRadius: CGFloat = 20
        static let pressedOpacity = 0.08
        static let disabledBackgroundOpacity = 0.08
        static let disabledForegroundOpacity = 0.3
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Constants.Typography.bodySEmphasized.font)
            .foregroundStyle(foreground)
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.vertical, Layout.verticalPadding)
            .frame(minHeight: Layout.minimumHeight)
            .background {
                RoundedRectangle(cornerRadius: Layout.cornerRadius)
                    .fill(background)
                    .overlay {
                        if isEnabled, configuration.isPressed {
                            RoundedRectangle(cornerRadius: Layout.cornerRadius)
                                .fill(pressedOverlay.opacity(Layout.pressedOpacity))
                        }
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
    }

    private var foreground: Color {
        guard isEnabled else {
            return Theme.foreground(for: colorScheme).opacity(Layout.disabledForegroundOpacity)
        }
        return variant == .primary ? .black : Theme.foreground(for: colorScheme)
    }

    private var background: Color {
        guard isEnabled else {
            return Theme.foreground(for: colorScheme).opacity(Layout.disabledBackgroundOpacity)
        }
        switch variant {
        case .muted: return Theme.muted(for: colorScheme)
        case .primary: return Color(.assistantAccent)
        case .secondary: return Theme.card(for: colorScheme)
        }
    }

    private var pressedOverlay: Color {
        variant == .primary ? .black : Theme.foreground(for: colorScheme)
    }
}
