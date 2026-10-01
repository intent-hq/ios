import SwiftUI

struct WorkspaceChangesSection<Content: View>: View {
    let title: String
    let count: Int
    let identifier: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var iconSize = CreateWorkspaceRepoStyle.iconSize

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? CreateWorkspaceRepoStyle.sectionHeaderSpacing : 0) {
            header
            if isExpanded { content() }
        }
    }

    private var header: some View {
        Button { isExpanded.toggle() } label: {
            HStack {
                Text("\(title) (\(count))")
                    .interFont(Constants.Typography.eyebrow)
                    .textCase(.uppercase)
                    .tracking(CreateWorkspaceRepoStyle.sectionTracking)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: CreateWorkspaceFormStyle.rowSpacing)
                Image(isExpanded ? .chevronDown : .chevronRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(CreateWorkspaceRepoStyle.sectionForeground(for: colorScheme, contrast: contrast))
            .frame(maxWidth: .infinity, minHeight: CreateWorkspaceFormStyle.controlHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("changes.section.\(identifier)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Double-tap to collapse this section" : "Double-tap to expand this section")
        .accessibilityAddTraits(.isHeader)
    }
}
