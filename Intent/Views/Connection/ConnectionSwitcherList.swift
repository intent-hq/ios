import SwiftUI

struct ConnectionSwitcherList: View {
    let connections: [StoredConnection]
    let selectedID: UUID?
    let onSelect: (UUID) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var iconSize = ConnectionSwitcherStyle.iconSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConnectionSwitcherStyle.headingSpacing) {
                ConnectionSheetText(
                    "Connections",
                    style: Constants.Typography.eyebrow,
                    tracking: Constants.ManualTokenEntry.labelTracking
                )
                .textCase(.uppercase)
                .foregroundStyle(Constants.Connections.sectionForeground(for: colorScheme, contrast: contrast))
                .accessibilityAddTraits(.isHeader)

                if connections.isEmpty {
                    Text("No saved connections.")
                        .interFont(Constants.Typography.bodyS)
                } else {
                    VStack(spacing: ConnectionSwitcherStyle.rowSpacing) {
                        ForEach(connections) { connection in
                            connectionRow(connection)
                        }
                    }
                }
            }
            .padding(.vertical, ConnectionSwitcherStyle.inset)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center, for: .alignment)
        .foregroundStyle(Constants.Connections.foreground(for: colorScheme))
        .padding(.leading, ConnectionSwitcherStyle.inset)
        .padding(.trailing, ConnectionSwitcherStyle.trailingInset)
        .accessibilityIdentifier("connection-switcher.list")
    }

    private func connectionRow(_ connection: StoredConnection) -> some View {
        Button { onSelect(connection.id) } label: {
            HStack(spacing: ConnectionSwitcherStyle.rowInset) {
                Image(.connectionLaptop)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityHidden(true)
                ConnectionSheetText(
                    "\(connection.displayName)",
                    style: Constants.Typography.bodySEmphasized,
                    tracking: Constants.Connections.nameTracking
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(ConnectionSwitcherStyle.rowInset)
            .frame(maxWidth: .infinity, minHeight: ConnectionSwitcherStyle.rowHeight, alignment: .leading)
            .background(
                connection.id == selectedID ? ConnectionSwitcherStyle.selection(for: colorScheme) : .clear,
                in: .rect(cornerRadius: ConnectionSwitcherStyle.cornerRadius)
            )
            .contentShape(.rect(cornerRadius: ConnectionSwitcherStyle.cornerRadius))
        }
        .buttonStyle(ConnectionSheetButtonStyle())
        .accessibilityLabel(connection.displayName)
        .accessibilityAddTraits(connection.id == selectedID ? .isSelected : [])
        .accessibilityIdentifier("connection-switcher.connection.\(connection.id)")
    }
}
