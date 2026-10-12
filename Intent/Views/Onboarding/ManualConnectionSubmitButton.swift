import SwiftUI

/// Shared form action reflects whether validation is running and remains cancellable.
struct ManualConnectionSubmitButton: View {
    let isValidating: Bool
    let canConnect: Bool
    let onSubmit: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onSubmit) {
            Group {
                if isValidating {
                    HStack(spacing: Constants.ManualTokenEntry.progressSpacing) {
                        ProgressView().tint(Constants.Pairing.onAccent)
                        Text("Cancel")
                            .interFont(Constants.Typography.bodySEmphasized)
                    }
                } else {
                    Text("Connect")
                        .interFont(Constants.Typography.bodySEmphasized)
                }
            }
            .tracking(Constants.Pairing.optionTitleTracking)
            .foregroundStyle(
                !isValidating && !canConnect
                    ? Constants.ConnectionSheet.disabledForeground(for: colorScheme) : Constants.Pairing.onAccent
            )
            .padding(.vertical, Constants.ConnectionSheet.fieldVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: Constants.ConnectionSheet.fieldHeight)
            .background(
                !isValidating && !canConnect
                    ? Constants.ConnectionSheet.disabledBackground(for: colorScheme) : Constants.Pairing.accent,
                in: .rect(cornerRadius: Constants.ConnectionSheet.fieldCornerRadius)
            )
        }
        .buttonStyle(IntentContentButtonStyle())
        .disabled(!isValidating && !canConnect)
        .accessibilityIdentifier("manual.connect")
    }
}
