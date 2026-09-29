import SwiftUI

/// Shared pairing actions; each presenting screen owns pairing and dismissal.
struct ConnectionPairingButtons: View {
    @Environment(\.colorScheme) private var colorScheme
    let qrTitle: LocalizedStringKey
    let accessibilityPrefix: String
    let onScan: () -> Void
    let onManualEntry: () -> Void

    var body: some View {
        let options = PairingOption.available(showsSavedConnections: false)
        VStack(spacing: 0) {
            if options.contains(.qrScan) {
                Button(action: onScan) {
                    ConnectionActionLabel(title: qrTitle, image: .connectQR)
                }
                .accessibilityIdentifier("\(accessibilityPrefix).scan")
            }
            if options.contains(.qrScan), options.contains(.manualEntry) {
                Rectangle()
                    .fill(Constants.Connections.background(for: colorScheme))
                    .frame(height: Constants.Connections.dividerWidth)
                    .accessibilityHidden(true)
            }
            if options.contains(.manualEntry) {
                Button(action: onManualEntry) {
                    ConnectionActionLabel(title: "Manual Connection", image: .connectManual)
                }
                .accessibilityIdentifier("\(accessibilityPrefix).manual")
            }
        }
        .buttonStyle(ConnectionSheetButtonStyle())
        .foregroundStyle(Constants.Connections.foreground(for: colorScheme))
        .background(Constants.Connections.surface(for: colorScheme))
        .clipShape(.rect(cornerRadius: Constants.ConnectionSheet.fieldCornerRadius))
    }
}

struct ConnectionActionLabel: View {
    @ScaledMetric(relativeTo: .body) private var iconSize = Constants.ConnectionSheet.glyphSize
    @ScaledMetric(relativeTo: .body) private var tracking = Constants.Connections.nameTracking
    let title: LocalizedStringKey
    let image: ImageResource

    var body: some View {
        HStack(spacing: Constants.ConnectionSheet.inset) {
            Image(image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
            Text(title)
                .interFont(Constants.Typography.bodySEmphasized)
                .tracking(tracking)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Constants.ConnectionSheet.inset)
        .padding(.vertical, Constants.ConnectionSheet.fieldVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: Constants.Connections.pairingRowMinimumHeight, alignment: .leading)
        .contentShape(.rect)
    }
}
