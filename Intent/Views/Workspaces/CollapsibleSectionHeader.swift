import SwiftUI

/// An eyebrow heading that collapses or expands the content below it, with a
/// trailing chevron. Callers style the label and set the foreground.
struct CollapsibleSectionHeader<Label: View>: View {
    let isExpanded: Bool
    /// Spacing around the heading that still belongs to the tap target.
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
            }
            .padding(insets)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: alignment)
            .contentShape(.rect)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Double-tap to collapse this section" : "Double-tap to expand this section")
        .accessibilityAddTraits(.isHeader)
    }
}
