import SwiftUI

struct ConnectionBackButton: View {
    let action: () -> Void

    var body: some View {
        IntentIconButton(icon: .arrowLeft, label: "Back to Home", action: action)
            .accessibilityHint("Return to your saved machines without forgetting this connection.")
    }
}
