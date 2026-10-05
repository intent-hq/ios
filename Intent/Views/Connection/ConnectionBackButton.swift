import SwiftUI

struct ConnectionBackButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        #if os(visionOS)
        button
            .glassBackgroundEffect(in: Circle())
        #else
        if #available(iOS 26.0, *) {
            button
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            button
                .background(.regularMaterial, in: Circle())
        }
        #endif
    }

    private var button: some View {
        Button(action: action) {
            Image(.arrowLeft)
                .resizable()
                .scaledToFit()
                .frame(width: Constants.ConnectionSheet.glyphSize, height: Constants.ConnectionSheet.glyphSize)
                .frame(width: Constants.Accessibility.minimumTapTarget, height: Constants.Accessibility.minimumTapTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
        .accessibilityLabel("Back to Home")
        .accessibilityHint("Return to your saved machines without forgetting this connection.")
    }
}
