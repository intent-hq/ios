import SwiftUI

extension View {
    func toastBackground() -> some View {
        modifier(ToastBackground())
    }
}

private struct ToastBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    private let shape = RoundedRectangle(cornerRadius: Constants.Toast.cornerRadius, style: .continuous)

    func body(content: Content) -> some View {
        if colorScheme == .dark {
            content
                .background(.ultraThinMaterial)
                .clipShape(shape)
                .shadow(
                    color: .black.opacity(Constants.Toast.shadowOpacity),
                    radius: Constants.Toast.shadowRadius,
                    y: Constants.Toast.shadowYOffset
                )
        } else {
            frostedGlass(content)
                .shadow(
                    color: .black.opacity(Constants.Toast.glassShadowOpacity),
                    radius: Constants.Toast.glassShadowRadius,
                    y: Constants.Toast.glassShadowYOffset
                )
        }
    }

    @ViewBuilder
    private func frostedGlass(_ content: Content) -> some View {
        #if os(visionOS)
        content.glassBackgroundEffect(in: shape)
        #else
        if #available(iOS 26.0, *) {
            content.glassEffect(
                .regular.tint(Color(.systemBackground).opacity(Constants.Toast.frostOpacity)).interactive(),
                in: shape
            )
        } else {
            content.background(.regularMaterial, in: shape)
        }
        #endif
    }
}

struct ToastButtonStyle: ButtonStyle {
    let dimsOnPress: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(dimsOnPress && configuration.isPressed ? Constants.ConnectionSheet.pressedOpacity : 1)
    }
}
