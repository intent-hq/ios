import SwiftUI

struct HookWakeAttributionView: View {
    let attribution: HookWakeAttribution
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Constants.Conversation.Attribution.spacing) {
            Image(systemName: "bolt.fill")
                .font(.caption2)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Constants.Conversation.Attribution.spacing) {
                Text(displayName)
                    .interFont(Constants.Typography.subtextXXS.withFace(.semibold))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(attribution.stateLabel)
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var displayName: String {
        let name = attribution.rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? attribution.displayName : name
    }
}
