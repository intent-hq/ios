import SwiftUI

extension EnvironmentValues {
    /// True while this window's Mac connection is lost (read-only or stopped).
    /// Set per window by RootView; sheets and covers inherit it.
    @Entry var isRemoteReadOnly = false
}

extension View {
    /// Disables a control that sends a change to the Mac while the connection is
    /// lost, and explains itself on tap. Adds to, never replaces, permission
    /// checks: pass those through `.disabled` as before.
    func requiresLiveConnection(_ hint: LocalizedStringResource = "Reconnect to make changes") -> some View {
        modifier(RequiresLiveConnection(hint: hint))
    }

    /// For controls inside menus, toolbars and swipe actions, where a tap hint
    /// cannot attach: disabled only.
    func disabledWhileReadOnly() -> some View {
        modifier(DisabledWhileReadOnly())
    }
}

private struct DisabledWhileReadOnly: ViewModifier {
    @Environment(\.isRemoteReadOnly) private var isReadOnly

    func body(content: Content) -> some View {
        content.disabled(isReadOnly)
    }
}

private struct RequiresLiveConnection: ViewModifier {
    private static let hintPadding: CGFloat = 12
    @Environment(\.isRemoteReadOnly) private var isReadOnly
    @State private var showsHint = false
    let hint: LocalizedStringResource

    func body(content: Content) -> some View {
        content
            .disabled(isReadOnly)
            .overlay {
                if isReadOnly {
                    // A disabled control ignores taps; this catches them so the
                    // control can say why instead of doing nothing.
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { showsHint = true }
                        .accessibilityHidden(true)
                }
            }
            .popover(isPresented: $showsHint) {
                Text(hint)
                    .interFont(Constants.Typography.bodyXS)
                    .padding(Self.hintPadding)
                    .presentationCompactAdaptation(.popover)
                    .accessibilityIdentifier("read-only.hint")
            }
            .onChange(of: isReadOnly) { _, readOnly in
                if !readOnly { showsHint = false }
            }
    }
}

extension View {
    /// Runs `action` when this window's Mac connection comes back, so screens
    /// that failed during a drop reload by themselves.
    func onReconnect(_ action: @escaping () -> Void) -> some View {
        modifier(OnReconnect(action: action))
    }
}

private struct OnReconnect: ViewModifier {
    @Environment(\.isRemoteReadOnly) private var isReadOnly
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: isReadOnly) { _, readOnly in
            if !readOnly { action() }
        }
    }
}
