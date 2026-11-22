import SwiftUI

struct GoalCommandNoticeView: View {
    let notice: GoalCommandNotice
    @Environment(\.colorScheme) var colorScheme
    @ScaledMetric(relativeTo: .caption2) private var iconSize: CGFloat = 11

    var body: some View {
        HStack(spacing: Constants.Conversation.DividerNotice.outerSpacing) {
            line
            HStack(alignment: .firstTextBaseline, spacing: Constants.Conversation.DividerNotice.labelSpacing) {
                Image(.pin)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityHidden(true)
                Text(notice.label)
                    .interFont(Constants.Typography.subtextXXS)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .layoutPriority(1)
            line
        }
        .padding(.vertical, Constants.Conversation.DividerNotice.verticalPadding)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notice.label)
        .accessibilityIdentifier("goalNotice")
    }

    private var line: some View {
        Rectangle()
            .fill(Theme.border(for: colorScheme))
            .frame(height: Constants.Conversation.DividerNotice.lineHeight)
            .frame(minWidth: Constants.Conversation.DividerNotice.minimumLineWidth, maxWidth: .infinity)
    }
}
