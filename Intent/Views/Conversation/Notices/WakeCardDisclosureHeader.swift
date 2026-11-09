import SwiftUI

/// Collapsible header for hook, PR-monitor and script-monitor wake cards; the
/// body stays hidden until expanded (FE parity: `AutomatedWakeCardHeader`,
/// collapsed by default). Headers without their own controls make the whole
/// row one button. A header with its own control (the PR chip) keeps it and
/// gets a separate chevron button, since buttons cannot nest.
struct WakeCardDisclosureHeader<Header: View>: View {
    private typealias Design = Constants.Conversation.Design

    @Binding var isExpanded: Bool
    var headerHasControls = false
    @ViewBuilder let header: Header
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if headerHasControls {
            HStack(alignment: .center, spacing: Design.Watcher.rowSpacing) {
                header
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: toggle) {
                    chevron
                        .frame(width: Design.minimumTapTarget, height: Design.minimumTapTarget, alignment: .trailing)
                        .contentShape(Rectangle())
                        .copyContextMenuPassthrough()
                }
                .buttonStyle(IntentContentButtonStyle())
                .accessibilityLabel(isExpanded ? "Collapse section" : "Expand section")
                .accessibilityValue(stateValue)
            }
        } else {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: Design.Watcher.rowSpacing) {
                    header
                        .frame(maxWidth: .infinity, alignment: .leading)
                    chevron
                }
                .frame(minHeight: Design.minimumTapTarget)
                .contentShape(Rectangle())
                .copyContextMenuPassthrough()
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityValue(stateValue)
        }
    }

    private var chevron: some View {
        Image(isExpanded ? .chevronDown : .chevronRight)
            .resizable()
            .scaledToFit()
            .frame(width: Design.toolIconSize, height: Design.toolIconSize)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .accessibilityHidden(true)
    }

    private var stateValue: String { isExpanded ? "Expanded" : "Collapsed" }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeInOut(
            duration: Constants.Conversation.Attribution.expansionAnimationDuration
        )) {
            isExpanded.toggle()
        }
    }
}
