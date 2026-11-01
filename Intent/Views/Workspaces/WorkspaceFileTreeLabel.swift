import SwiftUI

struct WorkspaceFileTreeLabel<Detail: View>: View {
    let name: String
    var isDirectory = false
    var isExpanded = false
    /// Draws the start of the guide that runs down to this folder's children.
    var showsChildGuide = false
    var showsChevron = true
    var count: Int?
    var lineStats: (additions: Int, deletions: Int)?
    @ViewBuilder let detail: () -> Detail
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var iconSize = WorkspaceChangesLayout.treeIconSize
    @ScaledMetric(relativeTo: .body) private var fileIconSize = WorkspaceFileTreeLayout.fileIconSize
    @ScaledMetric(relativeTo: .body) private var nameSize = WorkspaceFileTreeLayout.nameSize

    private var secondary: Color {
        WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast)
    }

    var body: some View {
        HStack(alignment: isDirectory ? .center : .top, spacing: CreateWorkspaceFormStyle.rowSpacing) {
            Image(isDirectory ? .folder : .file)
                .resizable()
                .scaledToFit()
                .frame(width: isDirectory ? iconSize : fileIconSize, height: isDirectory ? iconSize : fileIconSize)
                .padding(isDirectory ? 0 : (iconSize - fileIconSize) / 2)
                .foregroundStyle(secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CreateWorkspaceFormStyle.rowSpacing) {
                nameLine
                detail()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let count {
                Text("\(count)")
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(secondary)
            }
            if isDirectory, showsChevron {
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
        .padding(.vertical, WorkspaceFileTreeLayout.rowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: WorkspaceFileTreeLayout.rowHeight, alignment: .leading)
        .background {
            if showsChildGuide {
                FileTreeGuideShape(offsets: [], ownGuide: (iconSize / 2, iconSize / 2 + WorkspaceFileTreeLayout.guideIconGap))
                    .fileTreeGuideStroke(colorScheme: colorScheme, contrast: contrast)
            }
        }
        .contentShape(.rect)
    }

    private var nameLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: CreateWorkspaceFormStyle.rowSpacing) {
            Text(name)
                .font(.system(size: nameSize, weight: .medium, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
            if let lineStats {
                Spacer(minLength: 0)
                WorkspaceChangeStats(additions: lineStats.additions, deletions: lineStats.deletions)
                    .font(Constants.Typography.subtextXXS.font)
                    .fixedSize()
            }
        }
    }
}

enum WorkspaceFileTreeLayout {
    static let maximumIndentationDepth = 5
    static let indentation: CGFloat = 22
    static let rowHeight: CGFloat = 36
    static let rowVerticalPadding: CGFloat = 7
    static let fileIconSize: CGFloat = 13
    static let nameSize: CGFloat = 14
    /// Trees sit closer to the screen edge than page text to fit deeper nesting.
    static let leadingOutdent: CGFloat = 12

    static let folderOpenDuration = 0.25
    /// Closing runs a little faster than opening so collapsing feels immediate.
    static let folderCloseDuration = 0.18

    static func folderToggleAnimation(opening: Bool, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: opening ? folderOpenDuration : folderCloseDuration)
    }

    /// Rows past the deepest indentation keep the path below their last indented ancestor.
    static func displayName(path: String, depth: Int) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)

        return components.suffix(max(depth - maximumIndentationDepth, 0) + 1).joined(separator: "/")
    }

    static let guideOpacity = 0.3
    static let guideWidth: CGFloat = 1
    /// Measured from the icon frame; the folder glyph sits about 2pt inside it.
    static let guideIconGap: CGFloat = 3

    /// Whether an open folder's children sit deeper than it, so a guide can lead to them.
    static func showsChildGuide(depth: Int, isExpanded: Bool) -> Bool {
        isExpanded && depth < maximumIndentationDepth
    }

    static func indentation(for depth: Int, accessibility: Bool) -> CGFloat {
        let step = accessibility ? WorkspaceDetailStyle.accessibilityIndentation : indentation
        return CGFloat(min(depth, maximumIndentationDepth)) * step
    }
}

extension View {
    func fileTreeOutdent() -> some View {
        padding(.leading, -WorkspaceFileTreeLayout.leadingOutdent)
    }

    /// Draws a vertical guide under each ancestor folder's icon. Rows stack
    /// without spacing, so the guides join into one line per open folder;
    /// the folder's own label starts the line just below its icon.
    func fileTreeGuides(depth: Int) -> some View {
        modifier(FileTreeGuides(depth: depth))
    }
}

private extension Shape {
    func fileTreeGuideStroke(colorScheme: ColorScheme, contrast: ColorSchemeContrast) -> some View {
        stroke(
            WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast)
                .opacity(WorkspaceFileTreeLayout.guideOpacity),
            lineWidth: WorkspaceFileTreeLayout.guideWidth
        )
        .accessibilityHidden(true)
    }
}

private struct FileTreeGuides: ViewModifier {
    let depth: Int
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var iconSize = WorkspaceChangesLayout.treeIconSize

    func body(content: Content) -> some View {
        content.background {
            FileTreeGuideShape(offsets: offsets)
                .fileTreeGuideStroke(colorScheme: colorScheme, contrast: contrast)
        }
    }

    private var offsets: [CGFloat] {
        let accessibility = dynamicTypeSize.isAccessibilitySize
        return (0..<min(depth, WorkspaceFileTreeLayout.maximumIndentationDepth)).map { level in
            WorkspaceFileTreeLayout.indentation(for: level, accessibility: accessibility) + iconSize / 2
        }
    }
}

/// `ownGuide` is an x offset and a distance below the vertical center where
/// a folder's line starts.
nonisolated private struct FileTreeGuideShape: Shape {
    let offsets: [CGFloat]
    var ownGuide: (x: CGFloat, belowCenter: CGFloat)?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for offset in offsets {
            path.move(to: CGPoint(x: rect.minX + offset, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
        }
        if let ownGuide, rect.midY + ownGuide.belowCenter < rect.maxY {
            path.move(to: CGPoint(x: rect.minX + ownGuide.x, y: rect.midY + ownGuide.belowCenter))
            path.addLine(to: CGPoint(x: rect.minX + ownGuide.x, y: rect.maxY))
        }
        return path
    }
}
