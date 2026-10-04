import SwiftUI

struct WatcherMessageBodyView: View {
    let presentation: WatcherMessagePresentation
    @State private var isExpanded = false
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .callout) private var detailsHeight: CGFloat = 280
    private static let visibleCheckLimit = 4
    private static let previewLineLimit = 4

    init(text: String) {
        presentation = WatcherMessagePresentation(text: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Conversation.UserMessage.textRowSpacing) {
            prose(presentation.summary, isPreview: presentation.details != nil && !isExpanded)
            ForEach(Array(presentation.checks.prefix(Self.visibleCheckLimit).enumerated()), id: \.offset) { _, check in
                checkRow(check)
            }
            if presentation.checks.count > Self.visibleCheckLimit {
                Text("\(presentation.checks.count - Self.visibleCheckLimit) more checks in details")
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
            if let details = presentation.details {
                disclosure(details)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func prose(_ text: String, isPreview: Bool = false) -> some View {
        let rows = MessageView.userTextRows(text)
        return VStack(alignment: .leading, spacing: Constants.Conversation.UserMessage.textRowSpacing) {
            ForEach(Array(rows.prefix(isPreview ? Self.previewLineLimit : rows.count).enumerated()), id: \.offset) { _, row in
                switch row {
                case .text(let run):
                    Text(run)
                        .interFont(Constants.Typography.bodyXS)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .lineLimit(isPreview ? Self.previewLineLimit : nil)
                        .textSelection(.enabled)
                case .chips(let mentions):
                    ChipFlowLayout(spacing: Constants.Conversation.UserMessage.mentionChipSpacing) {
                        ForEach(Array(mentions.enumerated()), id: \.offset) { _, mention in
                            ContextMentionChipView(mention: mention)
                                .copyContextMenuPassthrough()
                        }
                    }
                }
            }
        }
    }

    private func checkRow(_ check: WatcherMessagePresentation.Check) -> some View {
        Label {
            Text("\(check.name) · \(check.label)")
                .interFont(Constants.Typography.subtextXXS)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: check.symbol)
                .accessibilityHidden(true)
        }
        .foregroundStyle(check.needsAttention
            ? Theme.destructive(for: colorScheme)
            : Theme.mutedForeground(for: colorScheme))
        .accessibilityElement(children: .combine)
    }

    private func disclosure(_ details: String) -> some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView(.vertical) {
                if presentation.isJSON {
                    CodeBlockView(code: details, language: "json")
                } else {
                    prose(details)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: detailsHeight)
        } label: {
            Text(isExpanded ? "Hide details" : "Show details")
                .interFont(Constants.Typography.subtextXXS.withFace(.semibold))
        }
        .tint(Theme.mutedForeground(for: colorScheme))
        .copyContextMenuPassthrough()
    }
}
