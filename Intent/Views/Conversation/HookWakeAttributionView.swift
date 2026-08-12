import SwiftUI

/// Compact attribution header for background-hook wake messages
/// (`metadata.type == "hook_wake"`, PROTOCOL §5.40): bolt icon + hook name +
/// "woke the agent" state label. Non-interactive — the iOS counterpart of
/// cloudlands-fe's `HookWakeAttributionHeader`.
struct HookWakeAttributionView: View {
    let attribution: HookWakeAttribution
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(.caption2)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Text(attribution.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .lineLimit(1)
            Text(attribution.stateLabel)
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
    }
}
