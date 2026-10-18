import SwiftUI

/// Values read from the live stores before handing rows to SwiftUI's renderer.
nonisolated struct AgentHistoryRowSnapshot: Identifiable, Sendable {
    let entry: AgentHistoryEntry
    let title: String
    let subtitle: String
    let timestamp: String
    let isCurrent: Bool
    var id: AgentHistoryEntry.ID { entry.id }
}

/// Constructing this value does not build its label or resolve live store state.
struct AgentHistoryRow: View {
    let snapshot: AgentHistoryRowSnapshot
    let colorScheme: ColorScheme
    let secondaryForeground: Color
    let onSelect: @MainActor () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: ConnectionSwitcherStyle.rowInset) {
                VStack(alignment: .leading, spacing: ConnectionSwitcherStyle.rowTextSpacing) {
                    Text(snapshot.title)
                        .interFont(Constants.Typography.bodySEmphasized)
                        .lineLimit(1)
                    if !snapshot.subtitle.isEmpty {
                        Text(snapshot.subtitle)
                            .interFont(Constants.Typography.bodyXS)
                            .foregroundStyle(secondaryForeground)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(snapshot.timestamp)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(secondaryForeground)
            }
            .padding(ConnectionSwitcherStyle.rowInset)
            .frame(maxWidth: .infinity, minHeight: ConnectionSwitcherStyle.rowHeight, alignment: .leading)
            .background(
                snapshot.isCurrent ? ConnectionSwitcherStyle.selection(for: colorScheme) : .clear,
                in: .rect(cornerRadius: ConnectionSwitcherStyle.cornerRadius)
            )
            .contentShape(.rect(cornerRadius: ConnectionSwitcherStyle.cornerRadius))
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(snapshot.isCurrent ? .isSelected : [])
        .accessibilityIdentifier("agent-history.entry.\(snapshot.id)")
    }
}
