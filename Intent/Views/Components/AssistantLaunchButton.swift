import SwiftUI

struct AssistantLaunchButton: View {
    private enum Layout {
        static let diameter: CGFloat = 80
        static let iconSize: CGFloat = 22
        static let trailingInset: CGFloat = 24
        static let bottomInset: CGFloat = 12
        static let shadowRadius: CGFloat = 16
        static let shadowOffset: CGFloat = 4
        static let shadowOpacity = 0.15
    }

    static let scrollClearance: CGFloat = 104
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(.intentDandelion)
                .resizable()
                .scaledToFit()
                .frame(width: Layout.iconSize, height: Layout.iconSize)
                .foregroundStyle(.black)
                .accessibilityHidden(true)
                .frame(width: Layout.diameter, height: Layout.diameter)
                .background(Color(.assistantAccent), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(Layout.shadowOpacity), radius: Layout.shadowRadius, y: Layout.shadowOffset)
        .accessibilityLabel("Intent menu")
        .accessibilityIdentifier("intent.menu.open")
        .padding(.trailing, Layout.trailingInset)
        .padding(.bottom, Layout.bottomInset)
    }
}
