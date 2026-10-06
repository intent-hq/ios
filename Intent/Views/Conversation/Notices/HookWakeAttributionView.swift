import SwiftUI

struct HookWakeAttributionView: View {
    private typealias Design = Constants.Conversation.Design

    let attribution: HookWakeAttribution
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Watcher.rowSpacing) {
            Image(systemName: "bolt.fill")
                .font(.subheadline)
                .frame(width: Design.toolIconSize)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .accessibilityHidden(true)
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
    }

    private var displayName: String {
        let name = attribution.rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? attribution.displayName : name
    }
}
