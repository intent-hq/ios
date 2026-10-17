import SwiftUI

struct WorkspaceFileTreeLabel<Detail: View>: View {
    let name: String
    var isDirectory = false
    var isExpanded = false
    var count: Int?
    @ViewBuilder let detail: () -> Detail
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var iconSize = WorkspaceChangesLayout.treeIconSize

    private var secondary: Color {
        WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast)
    }

    var body: some View {
        HStack(alignment: isDirectory ? .center : .top, spacing: CreateWorkspaceFormStyle.rowSpacing) {
            Image(isDirectory ? .folder : .file)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CreateWorkspaceFormStyle.rowSpacing) {
                Text(name)
                    .interFont(Constants.Typography.bodySEmphasized)
                    .tracking(isDirectory ? 0 : CreateWorkspaceRepoStyle.nameTracking)
                    .fixedSize(horizontal: false, vertical: true)
                detail()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let count {
                Text("\(count)")
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(secondary)
            }
            if isDirectory {
                Image(isExpanded ? .chevronDown : .chevronRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .foregroundStyle(secondary)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
        .multilineTextAlignment(.leading)
        .padding(.vertical, CreateWorkspaceFormStyle.controlVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: CreateWorkspaceFormStyle.controlHeight, alignment: .leading)
        .contentShape(.rect)
    }
}

enum WorkspaceFileTreeLayout {
    static let maximumIndentationDepth = 3
    static let indentation: CGFloat = 16

    static func indentation(for depth: Int, accessibility: Bool) -> CGFloat {
        let step = accessibility ? WorkspaceDetailStyle.accessibilityIndentation : indentation
        return CGFloat(min(depth, maximumIndentationDepth)) * step
    }
}
