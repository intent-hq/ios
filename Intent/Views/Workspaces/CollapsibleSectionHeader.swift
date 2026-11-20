import SwiftUI

struct CollapsibleSectionHeader<Label: View>: View {
    let isExpanded: Bool
    var insets = EdgeInsets()
    var minHeight = Constants.Accessibility.minimumTapTarget
    var alignment = Alignment.leading
    let onToggle: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var iconSize = WorkspaceChangesLayout.treeIconSize

    var body: some View {
        Button {
            withAnimation(WorkspaceFileTreeLayout.folderToggleAnimation(opening: !isExpanded, reduceMotion: reduceMotion), onToggle)
        } label: {
            HStack {
                label
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: CreateWorkspaceFormStyle.rowSpacing)
                Image(.chevronRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .rotationEffect(.radians(isExpanded ? .pi / 2 : 0))
                    .accessibilityHidden(true)
                    .visionGroupedHoverHint(padding: Constants.Accessibility.visionChevronHoverPadding)
            }
            .padding(insets)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: alignment)
            .contentShape(.rect)
            .visionHoverGroup()
        }
        .buttonStyle(IntentContentButtonStyle())
        .visionContainerDrawsHover()
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Double-tap to collapse this section" : "Double-tap to expand this section")
        .accessibilityAddTraits(.isHeader)
    }
}
