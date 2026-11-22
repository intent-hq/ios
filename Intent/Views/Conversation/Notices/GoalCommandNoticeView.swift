import SwiftUI

struct GoalCommandNoticeView: View {
    private typealias Design = Constants.Conversation.Design

    let notice: GoalCommandNotice
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: Design.Transcript.toolLabelSpacing) {
            Image(.pin)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: Design.toolIconSize, height: Design.toolIconSize)
                .accessibilityHidden(true)
            Text(notice.label)
                .interFont(Constants.Typography.bodyS)
                .tracking(Design.Typography.bodyTracking)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
        .frame(minHeight: Design.minimumTapTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notice.label)
        .accessibilityIdentifier("goalNotice")
    }
}
