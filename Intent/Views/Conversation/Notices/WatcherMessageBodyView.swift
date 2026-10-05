import SwiftUI

struct WatcherMessageBodyView: View {
    private typealias Design = Constants.Conversation.Design

    let presentation: WatcherMessagePresentation
    var onLayoutChange: (() -> Void)?
    @State private var isExpanded = false
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .callout) private var detailsHeight: CGFloat = 280
    private static let visibleCheckLimit = 4
    private static let previewLineLimit = 4

    init(text: String, onLayoutChange: (() -> Void)? = nil) {
        presentation = WatcherMessagePresentation(text: text)
        self.onLayoutChange = onLayoutChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Watcher.sectionSpacing) {
            prose(presentation.summary, isPreview: presentation.details != nil && !isExpanded)
            if !presentation.checks.isEmpty {
                checks
            }
            if let details = presentation.details {
                disclosure(details)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: Design.Watcher.rowSpacing) {
            ForEach(Array(presentation.checks.prefix(Self.visibleCheckLimit).enumerated()), id: \.offset) { _, check in
                checkRow(check)
            }
            if presentation.checks.count > Self.visibleCheckLimit {
                Text("\(presentation.checks.count - Self.visibleCheckLimit) more checks in details")
                    .interFont(Constants.Typography.bodyXS)
                    .tracking(Design.Typography.smallTracking)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
        }
    }

    private func prose(_ text: String, isPreview: Bool = false) -> some View {
        let rows = MessageView.userTextRows(text)
        return VStack(alignment: .leading, spacing: Design.Watcher.rowSpacing) {
            ForEach(Array(rows.prefix(isPreview ? Self.previewLineLimit : rows.count).enumerated()), id: \.offset) { _, row in
                switch row {
                case .text(let run):
                    Text(run)
                        .interFont(Constants.Typography.bodyS)
                        .tracking(Design.Typography.bodyTracking)
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
        HStack(alignment: .firstTextBaseline, spacing: Design.Watcher.rowSpacing) {
            Image(systemName: check.symbol)
                .font(.subheadline)
                .frame(width: Design.toolIconSize)
                .foregroundStyle(check.needsAttention
                    ? Theme.destructive(for: colorScheme)
                    : Theme.mutedForeground(for: colorScheme))
                .accessibilityHidden(true)
            Text("\(check.name) · \(check.label)")
                .interFont(Constants.Typography.bodyS)
                .tracking(Design.Typography.bodyTracking)
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func disclosure(_ details: String) -> some View {
        VStack(alignment: .leading, spacing: Design.Watcher.sectionSpacing) {
            disclosureButton
            if isExpanded {
                ScrollView(.vertical) {
                    if presentation.isJSON {
                        CodeBlockView(code: details, language: "json")
                    } else {
                        prose(details)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(height: detailsHeight)
            }
        }
    }

    private var disclosureButton: some View {
        Button {
            onLayoutChange?()
            isExpanded.toggle()
        } label: {
            HStack(spacing: Design.Transcript.disclosureSpacing) {
                Text(isExpanded ? "Hide details" : "Show details")
                    .interFont(Constants.Typography.bodyS)
                    .tracking(Design.Typography.bodyTracking)
                Spacer(minLength: 0)
                Image(isExpanded ? .chevronUp : .chevronDown)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Design.toolIconSize, height: Design.toolIconSize)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .padding(.vertical, Design.Watcher.disclosureHitInset)
            .frame(minHeight: Design.minimumTapTarget)
            .contentShape(Rectangle())
            .copyContextMenuPassthrough()
        }
        .buttonStyle(.plain)
        .padding(.vertical, -Design.Watcher.disclosureHitInset)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}
