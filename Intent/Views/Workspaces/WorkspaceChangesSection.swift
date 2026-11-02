import SwiftUI

struct WorkspaceChangesSection<Content: View>: View {
    let title: String
    var count: Int?
    let identifier: String
    var accessibilityPrefix = "changes"
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var iconSize = WorkspaceChangesLayout.treeIconSize

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? CreateWorkspaceRepoStyle.sectionHeaderSpacing : 0) {
            header
            if isExpanded { content() }
        }
    }

    private var header: some View {
        Button {
            withAnimation(WorkspaceFileTreeLayout.folderToggleAnimation(opening: !isExpanded, reduceMotion: reduceMotion)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Text(count.map { "\(title) (\($0))" } ?? title)
                    .interFont(Constants.Typography.eyebrow)
                    .textCase(.uppercase)
                    .tracking(CreateWorkspaceRepoStyle.sectionTracking)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: CreateWorkspaceFormStyle.rowSpacing)
                Image(.chevronRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .rotationEffect(.radians(isExpanded ? .pi / 2 : 0))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(CreateWorkspaceRepoStyle.sectionForeground(for: colorScheme, contrast: contrast))
            .frame(maxWidth: .infinity, minHeight: CreateWorkspaceFormStyle.controlHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityIdentifier("\(accessibilityPrefix).section.\(identifier)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Double-tap to collapse this section" : "Double-tap to expand this section")
        .accessibilityAddTraits(.isHeader)
    }
}
