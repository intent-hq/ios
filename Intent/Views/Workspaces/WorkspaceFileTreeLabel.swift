import SwiftUI

struct WorkspaceFileTreeLabel<Detail: View>: View {
    let name: String
    var isDirectory = false
    var isExpanded = false
    var count: Int?
    var lineStats: (additions: Int, deletions: Int)?
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
                HStack(alignment: .firstTextBaseline, spacing: CreateWorkspaceFormStyle.rowSpacing) {
                    Text(name)
                        .interFont(Constants.Typography.bodySEmphasized)
                        .tracking(isDirectory ? 0 : CreateWorkspaceRepoStyle.nameTracking)
                        .fixedSize(horizontal: false, vertical: true)
                    if let lineStats {
                        WorkspaceChangeStats(additions: lineStats.additions, deletions: lineStats.deletions)
                            .font(Constants.Typography.subtextXXS.font)
                            .fixedSize()
                    }
                }
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
    static let guideOpacity = 0.3
    static let guideWidth: CGFloat = 1
    static let guideLeadingShift: CGFloat = 5
    /// Reaches into the row above so the first child's guide meets its folder icon.
    static let guideTopExtension: CGFloat = 6

    /// Rows that open a folder's children, i.e. sit deeper than the row above.
    static func firstChildIDs<Row: Identifiable>(_ rows: [Row], depth: (Row) -> Int) -> Set<Row.ID> {
        Set(zip(rows.dropFirst(), rows).filter { depth($0) > depth($1) }.map(\.0.id))
    }

    static func indentation(for depth: Int, accessibility: Bool) -> CGFloat {
        let step = accessibility ? WorkspaceDetailStyle.accessibilityIndentation : indentation
        return CGFloat(min(depth, maximumIndentationDepth)) * step
    }
}

extension View {
    /// Draws a vertical guide under each ancestor folder's icon. Rows stack
    /// without spacing, so the guides join into one line per open folder.
    /// `isFirstChild` reaches the parent's guide up to its folder icon.
    func fileTreeGuides(depth: Int, isFirstChild: Bool) -> some View {
        modifier(FileTreeGuides(depth: depth, isFirstChild: isFirstChild))
    }
}

private struct FileTreeGuides: ViewModifier {
    let depth: Int
    let isFirstChild: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var iconSize = WorkspaceChangesLayout.treeIconSize

    func body(content: Content) -> some View {
        content.background {
            FileTreeGuideShape(
                offsets: offsets,
                topExtension: isFirstChild && depth <= WorkspaceFileTreeLayout.maximumIndentationDepth
                    ? WorkspaceFileTreeLayout.guideTopExtension : 0
            )
                .stroke(
                    WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast)
                        .opacity(WorkspaceFileTreeLayout.guideOpacity),
                    lineWidth: WorkspaceFileTreeLayout.guideWidth
                )
                .accessibilityHidden(true)
        }
    }

    private var offsets: [CGFloat] {
        let accessibility = dynamicTypeSize.isAccessibilitySize
        return (0..<min(depth, WorkspaceFileTreeLayout.maximumIndentationDepth)).map {
            WorkspaceFileTreeLayout.indentation(for: $0, accessibility: accessibility)
                + iconSize / 2 - WorkspaceFileTreeLayout.guideLeadingShift
        }
    }
}

nonisolated private struct FileTreeGuideShape: Shape {
    let offsets: [CGFloat]
    let topExtension: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, offset) in offsets.enumerated() {
            let top = index == offsets.count - 1 ? rect.minY - topExtension : rect.minY
            path.move(to: CGPoint(x: rect.minX + offset, y: top))
            path.addLine(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
        }
        return path
    }
}
