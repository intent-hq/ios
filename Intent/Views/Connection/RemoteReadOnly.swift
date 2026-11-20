import SwiftUI

extension EnvironmentValues {
    @Entry var isRemoteReadOnly = false
}

extension View {
    func requiresLiveConnection(_ hint: LocalizedStringResource = "Reconnect to make changes") -> some View {
        modifier(RequiresLiveConnection(hint: hint))
    }

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
