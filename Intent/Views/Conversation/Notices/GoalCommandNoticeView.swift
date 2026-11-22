import SwiftUI

struct GoalCommandNoticeView: View {
    private typealias Design = Constants.Conversation.Design

    let notice: GoalCommandNotice
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        WakeCardHeaderRow(icon: .pin) {
            Text(notice.label)
                .interFont(Constants.Typography.bodyXS)
                .tracking(Design.Typography.smallTracking)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notice.label)
        .accessibilityIdentifier("goalNotice")
    }
}
