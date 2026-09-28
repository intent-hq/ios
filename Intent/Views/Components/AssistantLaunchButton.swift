import SwiftUI

struct AssistantLaunchButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Layout {
        static let diameter: CGFloat = 80
        static let closeSize: CGFloat = 48
        static let closeCornerRadius: CGFloat = 20
        static let iconSize: CGFloat = 22
        static let iconRotation = 90.0
        static let hiddenIconScale = 0.6
        static let horizontalInset: CGFloat = 24
        static let bottomInset: CGFloat = 12
        static let shadowRadius: CGFloat = 16
        static let shadowOffset: CGFloat = 4
        static let shadowOpacity = 0.15
    }

    static let scrollClearance: CGFloat = 104
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            icon
                .foregroundStyle(.black)
                .accessibilityHidden(true)
                .frame(width: size, height: size)
                .background(Color(.assistantAccent), in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(isOpen ? 0 : Layout.shadowOpacity), radius: Layout.shadowRadius, y: Layout.shadowOffset)
        .accessibilityLabel(isOpen ? "Close Intent menu" : "Intent menu")
        .accessibilityIdentifier(isOpen ? "intent.menu.close" : "intent.menu.open")
        .padding(.horizontal, Layout.horizontalInset)
        .padding(.bottom, Layout.bottomInset)
    }

    private var size: CGFloat { isOpen ? Layout.closeSize : Layout.diameter }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isOpen ? Layout.closeCornerRadius : Layout.diameter / 2, style: .continuous)
    }

    private var icon: some View {
        ZStack {
            Image(.intentDandelion)
                .resizable()
                .scaledToFit()
                .rotationEffect(.degrees(isOpen && !reduceMotion ? Layout.iconRotation : 0))
                .scaleEffect(isOpen && !reduceMotion ? Layout.hiddenIconScale : 1)
                .opacity(isOpen ? 0 : 1)
                .accessibilityHidden(true)
            Image(.close)
                .resizable()
                .scaledToFit()
                .rotationEffect(.degrees(isOpen || reduceMotion ? 0 : -Layout.iconRotation))
                .scaleEffect(isOpen || reduceMotion ? 1 : Layout.hiddenIconScale)
                .opacity(isOpen ? 1 : 0)
                .accessibilityHidden(true)
        }
        .frame(width: Layout.iconSize, height: Layout.iconSize)
    }
}
