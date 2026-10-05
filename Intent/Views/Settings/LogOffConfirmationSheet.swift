import SwiftUI

struct LogOffConfirmationSheet: View {
    let onLogOff: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isConfirming = false

    private enum Layout {
        // ConnectionSheet replaces this estimate with measured, scrollable content.
        static let initialHeight: CGFloat = 400
        static let actionSpacing: CGFloat = 12
    }

    var body: some View {
        ConnectionSheet(
            initialHeight: Layout.initialHeight,
            backgroundColor: SettingsStyle.surface(for: colorScheme),
            closeForeground: SettingsStyle.foreground(for: colorScheme)
        ) {
            VStack(spacing: SettingsStyle.headingSpacing) {
                heading
                actions
            }
            .frame(maxWidth: SettingsStyle.maximumContentWidth)
        }
        .accessibilityAction(.escape) { dismiss() }
    }

    private var heading: some View {
        VStack(spacing: SettingsStyle.sectionHeaderSpacing) {
            ConnectionSheetText(
                "Disconnect?",
                style: Constants.Typography.heading2,
                tracking: Constants.Connections.headingTracking
            )
            .foregroundStyle(SettingsStyle.foreground(for: colorScheme))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("log-off.title")
            Text("Are you sure? You'll need to pair again to reconnect.")
                .interFont(Constants.Typography.bodyS)
                .foregroundStyle(SettingsStyle.sectionForeground(for: colorScheme, contrast: contrast))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("log-off.message")
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var actions: some View {
        VStack(spacing: Layout.actionSpacing) {
            Button(role: .cancel) { dismiss() } label: {
                actionLabel("Cancel")
            }
            .accessibilityIdentifier("log-off.cancel")

            Button(role: .destructive, action: confirmLogOff) {
                actionLabel("Disconnect", isDestructive: true)
            }
            .accessibilityIdentifier("log-off.confirm")
        }
        .buttonStyle(ConnectionSheetButtonStyle())
        .disabled(isConfirming)
    }

    private func actionLabel(_ title: LocalizedStringKey, isDestructive: Bool = false) -> some View {
        Text(title)
            .interFont(Constants.Typography.bodySEmphasized)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SettingsStyle.contentMargin)
            .padding(.vertical, SettingsStyle.rowVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: SettingsStyle.rowHeight)
            .foregroundStyle(isDestructive ? SettingsStyle.lightForeground : SettingsStyle.foreground(for: colorScheme))
            .background(
                isDestructive ? Theme.destructive(for: colorScheme) : SettingsStyle.card(for: colorScheme),
                in: .rect(cornerRadius: SettingsStyle.cardRadius)
            )
            .contentShape(.rect(cornerRadius: SettingsStyle.cardRadius))
    }

    private func confirmLogOff() {
        guard !isConfirming else { return }
        isConfirming = true
        dismiss()
        onLogOff()
    }
}

#Preview("Disconnect - Light") {
    LogOffConfirmationSheet {}
        .environment(\.colorScheme, .light)
}

#Preview("Disconnect - Dark") {
    LogOffConfirmationSheet {}
        .environment(\.colorScheme, .dark)
}
