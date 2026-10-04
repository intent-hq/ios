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
            Text(presentation.summary)
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .lineLimit(presentation.details == nil || isExpanded ? nil : Self.previewLineLimit)
                .textSelection(.enabled)
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
                    Text(details)
                        .interFont(Constants.Typography.bodyXS)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: detailsHeight)
        } label: {
            Text(isExpanded ? "Hide details" : "Show details")
                .interFont(Constants.Typography.subtextXXS.withFace(.semibold))
        }
        .tint(Theme.mutedForeground(for: colorScheme))
    }
}
