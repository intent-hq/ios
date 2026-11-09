import SwiftUI

/// Header for script-monitor wake rows: terminal icon, script name and the
/// monitor outcome (FE parity: `AutomatedWakeCardHeader` script kind).
struct ScriptMonitorWakeAttributionView: View {
    private typealias Design = Constants.Conversation.Design

    let attribution: ScriptMonitorWakeAttribution
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        WakeCardHeaderRow(icon: .terminal) {
            VStack(alignment: .leading, spacing: Design.Watcher.attributionSpacing) {
                Text(scriptName)
                    .interFont(Constants.Typography.bodyXSEmphasized)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(attribution.statusLabel)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tracking(Design.Typography.smallTracking)
        }
        .accessibilityElement(children: .combine)
    }

    private var scriptName: String {
        let name = attribution.scriptName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Script" : name
    }
}
