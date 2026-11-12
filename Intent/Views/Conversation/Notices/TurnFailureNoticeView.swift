import SwiftUI

/// The `turn-failure` attention card: a friendly title and message from
/// `TurnFailureSummary`, an optional retry hint and provider link, and the
/// untouched reason behind a collapsed "Details" disclosure with Copy.
/// Rendered the same way by the legacy and workspace transcript designs;
/// only the body type size follows the active design.
struct TurnFailureNoticeView: View {
    let summary: TurnFailureSummary
    var onLayoutChange: (() -> Void)?
    var disclosure = TranscriptDisclosure()
    @State private var copied = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.workspaceTranscriptDesign) private var workspaceDesign
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption) private var actionIconSize: CGFloat = 12

    private typealias Card = Constants.Conversation.NoticeCard
    private typealias Design = Constants.Conversation.Design

    /// Details start collapsed. A row holds one notice, so the row's shared
    /// `.attentionNotice` slot is free for this card.
    private var isExpanded: Bool {
        get { disclosure.binding(for: .attentionNotice, default: false).wrappedValue }
        nonmutating set { disclosure.binding(for: .attentionNotice, default: false).wrappedValue = newValue }
    }

    /// Amber for a usage limit (the user did nothing wrong and can wait it
    /// out); red for every real failure, matching the blocker card.
    private var tint: Color {
        summary.category == .usageLimit ? .orange : .red
    }

    private var bodyStyle: Constants.Typography.Style {
        workspaceDesign ? Constants.Typography.bodyS : Constants.Typography.bodyXS
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Card.turnFailureSectionSpacing) {
            summaryRow
            VStack(alignment: .leading, spacing: Card.turnFailureSectionSpacing) {
                if let url = summary.linkURL {
                    linkButton(url)
                }
                detailsButton
                if isExpanded {
                    details
                }
            }
            .padding(.leading, iconSize + Card.contentSpacing)
        }
        .padding(.horizontal, Card.horizontalPadding)
        .padding(.vertical, Card.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(
            contrast == .increased
                ? Card.backgroundOpacity * Card.increasedContrastBackgroundMultiplier
                : Card.backgroundOpacity
        ))
        .clipShape(RoundedRectangle(cornerRadius: Card.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Card.cornerRadius)
                .strokeBorder(
                    tint.opacity(contrast == .increased ? 1 : Card.borderOpacity),
                    lineWidth: contrast == .increased
                        ? Card.borderWidth * Card.increasedContrastBorderWidthMultiplier
                        : Card.borderWidth
                )
        )
    }

    // MARK: - Summary

    private var summaryRow: some View {
        HStack(alignment: .top, spacing: Card.contentSpacing) {
            Image(.closeCircle)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
                .padding(.top, Card.iconTopPadding)

            VStack(alignment: .leading, spacing: Card.attentionTextSpacing) {
                Text(summary.title)
                    .interFont(bodyStyle.withFace(.semibold))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .accessibilityAddTraits(.isHeader)

                if let message = summary.message {
                    Text(message)
                        .interFont(bodyStyle)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let retryHint = summary.retryHint {
                    Text(Self.sentenceCased(retryHint))
                        .interFont(bodyStyle.withFace(.medium))
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme, contrast: contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("turnFailure.summary")
    }

    // MARK: - Link

    private func linkButton(_ url: URL) -> some View {
        let host = url.host(percentEncoded: false) ?? url.absoluteString
        return Button {
            openURL(url)
        } label: {
            HStack(spacing: Card.turnFailureActionSpacing) {
                Text(host)
                    .interFont(bodyStyle.withFace(.medium))
                    .underline()
                Image(.external)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: actionIconSize, height: actionIconSize)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Theme.foreground(for: colorScheme))
            .frame(minHeight: Design.minimumTapTarget)
            .contentShape(Rectangle())
            .copyContextMenuPassthrough()
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Open \(host)")
        .accessibilityAddTraits(.isLink)
        .accessibilityRemoveTraits(.isButton)
        .accessibilityIdentifier("turnFailure.link")
    }

    // MARK: - Details

    private var detailsButton: some View {
        Button {
            onLayoutChange?()
            withAnimation(reduceMotion ? nil : .easeInOut(duration: Constants.Conversation.ToolCall.expansionAnimationDuration)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: Design.Transcript.toolLabelSpacing) {
                Text("Details")
                    .interFont(bodyStyle)
                    .tracking(Design.Typography.bodyTracking)
                WorkspaceTranscriptDisclosure(isExpanded: isExpanded)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.mutedForeground(for: colorScheme, contrast: contrast))
            .frame(minHeight: Design.minimumTapTarget)
            .contentShape(Rectangle())
            .copyContextMenuPassthrough()
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Details")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Hides the original error" : "Shows the original error")
        .accessibilityIdentifier("turnFailure.details")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Card.turnFailureActionSpacing) {
            Text(summary.rawDetails)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("turnFailure.rawDetails")
            copyButton
        }
        .padding(Card.turnFailureDetailsPadding)
        .background(
            Theme.foreground(for: colorScheme).opacity(contrast == .increased
                ? Card.turnFailureDetailsIncreasedOpacity
                : Card.turnFailureDetailsBackgroundOpacity),
            in: RoundedRectangle(cornerRadius: Card.turnFailureDetailsCornerRadius)
        )
    }

    private var copyButton: some View {
        Button {
            copyDetails()
        } label: {
            HStack(spacing: Card.turnFailureActionSpacing) {
                Image(copied ? .check : .copy)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: actionIconSize, height: actionIconSize)
                    .accessibilityHidden(true)
                Text(copied ? "Copied" : "Copy")
                    .interFont(Constants.Typography.subtextXXS)
            }
            .foregroundStyle(Theme.mutedForeground(for: colorScheme, contrast: contrast))
            .frame(minHeight: Design.minimumTapTarget)
            .contentShape(Rectangle())
            .copyContextMenuPassthrough()
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel(copied ? "Copied" : "Copy details")
        .accessibilityIdentifier("turnFailure.copy")
    }

    private func copyDetails() {
        HapticManager.impact(.light)
        UIPasteboard.general.string = summary.rawDetails
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Conversation.CodeBlock.copyConfirmationDuration) {
            copied = false
        }
    }

    /// "try again at 8:07 AM" → "Try again at 8:07 AM" for its own line.
    private static func sentenceCased(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
