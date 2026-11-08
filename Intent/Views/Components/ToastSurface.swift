import SwiftUI

/// Background treatment for the agent-completion toast. Several are kept while the
/// sandbox (`--demo-toast-sandbox`) compares them; collapse to one once chosen.
enum ToastSurface: String, Identifiable {
    case frostedGlass
    case glass
    case glassCapsule
    case liftedGlass
    case material
    case thickMaterial

    static let sandboxOrder: [Self] = [.material, .glass, .liftedGlass, .frostedGlass, .thickMaterial, .glassCapsule]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .material: "Current material"
        case .glass: "Liquid Glass"
        case .liftedGlass: "Liquid Glass + shadow"
        case .frostedGlass: "Frosted Liquid Glass"
        case .thickMaterial: "Thick material + edge"
        case .glassCapsule: "Liquid Glass capsule"
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .material: Constants.Toast.cornerRadius
        case .glass, .liftedGlass, .frostedGlass, .thickMaterial: Constants.Toast.nativeCornerRadius
        case .glassCapsule: .infinity
        }
    }

    var usesGlass: Bool {
        switch self {
        case .glass, .liftedGlass, .frostedGlass, .glassCapsule: true
        case .material, .thickMaterial: false
        }
    }
}

extension View {
    func toastSurface(_ surface: ToastSurface) -> some View {
        modifier(ToastSurfaceModifier(surface: surface))
    }
}

private struct ToastSurfaceModifier: ViewModifier {
    let surface: ToastSurface
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: surface.cornerRadius, style: .continuous)
        switch surface {
        case .material:
            content
                .background(.ultraThinMaterial)
                .clipShape(shape)
                .shadow(
                    color: .black.opacity(Constants.Toast.shadowOpacity),
                    radius: Constants.Toast.shadowRadius,
                    y: Constants.Toast.shadowYOffset
                )
        case .thickMaterial:
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(Constants.Toast.edgeOpacity)))
                .shadow(color: liftShadow, radius: Constants.Toast.liftShadowRadius, y: Constants.Toast.liftShadowYOffset)
        case .glass, .glassCapsule:
            glass(content, in: shape)
        case .liftedGlass:
            glass(content, in: shape)
                .shadow(color: liftShadow, radius: Constants.Toast.liftShadowRadius, y: Constants.Toast.liftShadowYOffset)
        case .frostedGlass:
            glass(content, in: shape, frost: Constants.Toast.frostOpacity)
                .shadow(color: liftShadow, radius: Constants.Toast.liftShadowRadius, y: Constants.Toast.liftShadowYOffset)
        }
    }

    /// Light mode needs the stronger lift; dark backgrounds already separate the banner.
    private var liftShadow: Color {
        .black.opacity(colorScheme == .light ? Constants.Toast.liftShadowOpacity : Constants.Toast.shadowOpacity)
    }

    @ViewBuilder
    private func glass(_ content: Content, in shape: RoundedRectangle, frost: Double = 0) -> some View {
        #if os(visionOS)
        content.glassBackgroundEffect(in: shape)
        #else
        if #available(iOS 26.0, *) {
            content.glassEffect(
                .regular.tint(frost > 0 ? Color(.systemBackground).opacity(frost) : nil).interactive(),
                in: shape
            )
        } else {
            content.background(.regularMaterial, in: shape)
        }
        #endif
    }
}

/// Glass surfaces give their own press feedback, so only material surfaces dim.
struct ToastButtonStyle: ButtonStyle {
    let dimsOnPress: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(dimsOnPress && configuration.isPressed ? Constants.ConnectionSheet.pressedOpacity : 1)
    }
}
