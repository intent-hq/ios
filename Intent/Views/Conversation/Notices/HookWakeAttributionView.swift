import SwiftUI

struct HookWakeAttributionView: View {
    private typealias Design = Constants.Conversation.Design

    let attribution: HookWakeAttribution
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        WakeCardHeaderRow(icon: .bolt1) {
            VStack(alignment: .leading, spacing: Design.Watcher.attributionSpacing) {
                Text(displayName)
                    .interFont(Constants.Typography.bodyXSEmphasized)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(attribution.stateLabel)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tracking(Design.Typography.smallTracking)
        }
        .accessibilityElement(children: .combine)
    }

    private var displayName: String {
        let name = attribution.rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? attribution.displayName : name
    }
}
