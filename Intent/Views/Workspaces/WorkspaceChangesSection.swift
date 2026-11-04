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

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? CreateWorkspaceRepoStyle.sectionHeaderSpacing : 0) {
            header
            if isExpanded { content() }
        }
    }

    private var header: some View {
        CollapsibleSectionHeader(isExpanded: isExpanded, minHeight: CreateWorkspaceFormStyle.controlHeight) {
            isExpanded.toggle()
        } label: {
            Text(count.map { "\(title) (\($0))" } ?? title)
                .interFont(Constants.Typography.eyebrow)
                .textCase(.uppercase)
                .tracking(CreateWorkspaceRepoStyle.sectionTracking)
        }
        .foregroundStyle(CreateWorkspaceRepoStyle.sectionForeground(for: colorScheme, contrast: contrast))
        .accessibilityIdentifier("\(accessibilityPrefix).section.\(identifier)")
    }
}
