import SwiftUI

struct ManualConnectionHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: Constants.ManualTokenEntry.headerSpacing) {
            ConnectionSheetText(
                "Manual Connection",
                style: Constants.Typography.heading2,
                tracking: Constants.Pairing.headingTracking
            )
                .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("manual.title")
            ConnectionSheetText(
                "Enter IP, port, and token",
                style: Constants.Typography.bodyS,
                tracking: Constants.Pairing.bodyTracking
            )
                .foregroundStyle(Constants.Pairing.mutedForeground(for: colorScheme))
                .accessibilityIdentifier("manual.subtitle")
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}
