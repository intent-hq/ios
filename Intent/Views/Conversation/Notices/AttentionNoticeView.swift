import SwiftUI

/// Kind-flavored notice card for daemon-persisted attention-request rows
/// (PROTOCOL §5.5): amber for a discussion request, red for a blocker report
/// or a terminal turn failure. Visual sibling of cloudlands-fe's
/// DiscussionRequestNotice.svelte / BlockerReportNotice.svelte /
/// TurnFailureNotice.svelte.
struct AttentionNoticeView: View {
    let notice: AttentionNotice
    var onLayoutChange: (() -> Void)?
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.workspaceTranscriptDesign) private var workspaceDesign
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var disclosure = TranscriptDisclosure()
    private var isExpanded: Bool {
        get { disclosure.binding(for: .attentionNotice, default: true).wrappedValue }
        nonmutating set { disclosure.binding(for: .attentionNotice, default: true).wrappedValue = newValue }
    }

    private typealias Layout = Constants.Conversation.NoticeCard
    private typealias Design = Constants.Conversation.Design

    private var tint: Color {
        switch notice.kind {
        case .discussionRequest: return .orange
        case .blockerReport: return .red
        case .turnFailure: return .red
        }
    }

    private var iconName: String {
        switch notice.kind {
        case .discussionRequest: return "bubble.left.and.bubble.right.fill"
        case .blockerReport: return "exclamationmark.triangle.fill"
        case .turnFailure: return "xmark.circle.fill"
        }
    }

    private var title: String {
        switch notice.kind {
        case .discussionRequest: return "Discussion requested"
        case .blockerReport: return "Blocker reported"
        case .turnFailure: return "Turn failed"
        }
    }

    var body: some View {
        if workspaceDesign, notice.kind == .blockerReport {
            blockerReport
        } else {
            legacyNotice
        }
    }

    private var blockerReport: some View {
        VStack(alignment: .leading, spacing: Design.Transcript.toolRowSpacing) {
            blockerHeader
            if isExpanded, !notice.reason.isEmpty {
                Text(notice.reason)
                    .interFont(Constants.Typography.bodyS)
                    .tracking(Design.Typography.bodyTracking)
                    .foregroundStyle(Design.Palette.blockerBodyForeground(for: colorScheme, contrast: colorSchemeContrast))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Design.Transcript.expandedContentIndent)
            }
        }
    }

    private var blockerHeader: some View {
        Button {
            onLayoutChange?()
            withAnimation(reduceMotion ? nil : .easeInOut(duration: Constants.Conversation.ToolCall.expansionAnimationDuration)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: Design.Transcript.toolLabelSpacing) {
                Image(.attentionCircle)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Design.toolIconSize, height: Design.toolIconSize)
                    .accessibilityHidden(true)
                Text("Blocker Report")
                    .interFont(Constants.Typography.bodyS)
                    .tracking(Design.Typography.bodyTracking)
                    .frame(maxWidth: .infinity, alignment: .leading)
                WorkspaceTranscriptDisclosure(isExpanded: isExpanded)
            }
            .foregroundStyle(Design.Palette.blockerForeground(for: colorScheme, contrast: colorSchemeContrast))
            .frame(minHeight: Design.minimumTapTarget)
            .contentShape(Rectangle())
            .copyContextMenuPassthrough()
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private var legacyNotice: some View {
        HStack(alignment: .top, spacing: Constants.Conversation.NoticeCard.contentSpacing) {
            Image(systemName: iconName)
                .font(.subheadline)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
                .padding(.top, Constants.Conversation.NoticeCard.iconTopPadding)

            VStack(alignment: .leading, spacing: Layout.attentionTextSpacing) {
                Text(title)
                    .interFont(Constants.Typography.bodyXS.withFace(.semibold))
                    .foregroundStyle(Theme.foreground(for: colorScheme))

                if !notice.reason.isEmpty {
                    Text(notice.reason)
                        .interFont(Constants.Typography.bodyXS)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, Constants.Conversation.NoticeCard.horizontalPadding)
        .padding(.vertical, Constants.Conversation.NoticeCard.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(
            colorSchemeContrast == .increased
                ? Constants.Conversation.NoticeCard.backgroundOpacity * Layout.increasedContrastBackgroundMultiplier
                : Constants.Conversation.NoticeCard.backgroundOpacity
        ))
        .clipShape(RoundedRectangle(cornerRadius: Constants.Conversation.NoticeCard.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Constants.Conversation.NoticeCard.cornerRadius)
                .strokeBorder(
                    tint.opacity(colorSchemeContrast == .increased
                        ? 1
                        : Constants.Conversation.NoticeCard.borderOpacity),
                    lineWidth: colorSchemeContrast == .increased
                        ? Constants.Conversation.NoticeCard.borderWidth * Layout.increasedContrastBorderWidthMultiplier
                        : Constants.Conversation.NoticeCard.borderWidth
                )
        )
    }
}
