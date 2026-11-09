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
    var showsBackground = true
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
                .background {
                    if showsBackground { WorkspaceControlSurface() }
                }
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
    /// Puts a copy passthrough marker behind the whole pill, so taps on its
    /// padding reach the Button inside a transcript row's copy overlay (see
    /// `copyContextMenuPassthrough()`). Use it on every Button in a row.
    var passesThroughCopyMenu = false
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
            .foregroundStyle(foreground(for: configuration.role))
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.vertical, Layout.verticalPadding)
            .frame(minHeight: Layout.minimumHeight)
            .background {
                if passesThroughCopyMenu { CopyContextMenuPassthroughMarker() }
            }
            .background {
                RoundedRectangle(cornerRadius: Layout.cornerRadius)
                    .fill(background(for: configuration.role))
                    .overlay {
                        if isEnabled, configuration.isPressed {
                            RoundedRectangle(cornerRadius: Layout.cornerRadius)
                                .fill(pressedOverlay.opacity(Layout.pressedOpacity))
                        }
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
    }

    private func foreground(for role: ButtonRole?) -> Color {
        guard isEnabled else {
            return Theme.foreground(for: colorScheme).opacity(Layout.disabledForegroundOpacity)
        }
        if role == .destructive {
            return variant == .primary ? .white : Theme.destructive(for: colorScheme)
        }
        return variant == .primary ? .black : Theme.foreground(for: colorScheme)
    }

    private func background(for role: ButtonRole?) -> Color {
        guard isEnabled else {
            return Theme.foreground(for: colorScheme).opacity(Layout.disabledBackgroundOpacity)
        }
        switch variant {
        case .muted: return Theme.muted(for: colorScheme)
        case .primary: return role == .destructive ? Theme.destructive(for: colorScheme) : Color(.assistantAccent)
        case .secondary: return Theme.card(for: colorScheme)
        }
    }

    private var pressedOverlay: Color {
        variant == .primary ? .black : Theme.foreground(for: colorScheme)
    }
}
