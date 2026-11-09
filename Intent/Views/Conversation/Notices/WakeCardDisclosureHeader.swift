import SwiftUI

/// Collapsible header for hook, PR-monitor and script-monitor wake cards: the
/// body stays hidden until the chevron is tapped (FE parity:
/// `AutomatedWakeCardHeader`, collapsed by default). Buttons inside `header`,
/// such as the PR chip, keep their own taps.
struct WakeCardDisclosureHeader<Header: View>: View {
    private typealias Design = Constants.Conversation.Design

    @Binding var isExpanded: Bool
    @ViewBuilder let header: Header
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: Design.Watcher.rowSpacing) {
            header
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: toggle) {
                Image(isExpanded ? .chevronDown : .chevronRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Design.toolIconSize, height: Design.toolIconSize)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .frame(width: Design.minimumTapTarget, height: Design.minimumTapTarget, alignment: .trailing)
                    .contentShape(Rectangle())
                    .copyContextMenuPassthrough()
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityLabel(isExpanded ? "Collapse section" : "Expand section")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        }
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeInOut(
            duration: Constants.Conversation.Attribution.expansionAnimationDuration
        )) {
            isExpanded.toggle()
        }
    }
}
