import CoreText
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

/// Icon plus title and status lines for a wake card header. The text is
/// measured from the title's cap top to the last baseline so the card padding
/// reads evenly, and the icon centres on the title's first line.
struct WakeCardHeaderRow<Content: View>: View {
    private typealias Design = Constants.Conversation.Design
    private static var titleStyle: Constants.Typography.Style { Constants.Typography.bodyXSEmphasized }

    let icon: ImageResource
    let content: Content
    @ScaledMetric private var fontSize: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.legibilityWeight) private var legibilityWeight

    init(icon: ImageResource, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.content = content()
        _fontSize = ScaledMetric(wrappedValue: Self.titleStyle.size, relativeTo: Self.titleStyle.relativeTo)
    }

    var body: some View {
        let capHeight = titleCapHeight
        HStack(alignment: .top, spacing: Design.Watcher.rowSpacing) {
            Color.clear
                .frame(width: Design.toolIconSize, height: capHeight)
                .overlay {
                    Image(icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: Design.toolIconSize, height: Design.toolIconSize)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                }
                .accessibilityHidden(true)
            WorkspaceTextTrimLayout(capHeight: capHeight) {
                content
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var titleCapHeight: CGFloat {
        let style = Self.titleStyle
        let face = legibilityWeight == .bold ? style.face.legibleFace : style.face
        return CTFontGetCapHeight(CTFontCreateWithName(face.rawValue as CFString, fontSize, nil))
    }
}
