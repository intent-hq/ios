import SwiftUI

struct PrMonitorWakeAttributionView: View {
    private typealias Design = Constants.Conversation.Design

    let attribution: PrMonitorWakeAttribution
    let workspaceRepo: String?
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.openURL) private var openURL

    var body: some View {
        WakeCardHeaderRow(icon: .gitPr) {
            VStack(alignment: .leading, spacing: Design.Watcher.attributionSpacing) {
                prLink
                Text("woke the agent")
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
            .tracking(Design.Typography.smallTracking)
        }
    }

    private var prLink: some View {
        Button {
            if let url = ExternalLink.url(from: attribution.resolvedUrl) {
                openURL(url)
            }
        } label: {
            Text(attribution.chipLabel(workspaceRepo: workspaceRepo))
                .interFont(Constants.Typography.bodyXSEmphasized)
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .underline()
                .fixedSize(horizontal: false, vertical: true)
                .copyContextMenuPassthrough()
        }
        .buttonStyle(IntentContentButtonStyle())
    }
}
