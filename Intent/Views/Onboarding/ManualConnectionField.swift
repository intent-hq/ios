import SwiftUI

/// A label and growing native editor surface, never a fixed-height text clip.
struct ManualConnectionField<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let label: LocalizedStringKey
    var verticalPadding = Constants.ConnectionSheet.fieldVerticalPadding
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.ManualTokenEntry.fieldSpacing) {
            ConnectionSheetText(
                label,
                style: Constants.Typography.eyebrow,
                tracking: Constants.ManualTokenEntry.labelTracking
            )
                .foregroundStyle(Constants.ManualTokenEntry.labelForeground(for: colorScheme))
                .accessibilityHidden(true)
            content
                .textFieldStyle(.plain)
                .tracking(Constants.Pairing.optionTitleTracking)
                .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
                .padding(.horizontal, Constants.ConnectionSheet.inset)
                .padding(.vertical, verticalPadding)
                .frame(minHeight: Constants.ConnectionSheet.fieldHeight)
                .background(Constants.Pairing.surface(for: colorScheme), in: .rect(
                    cornerRadius: Constants.ConnectionSheet.fieldCornerRadius
                ))
        }
    }
}
