import SwiftUI

struct WorkspaceChangesFileTree: View {
    let title: String
    let identifier: String
    let files: [WorkspaceChange]
    let scope: String
    let onSelect: (WorkspaceChange) -> Void
    @State private var isExpanded = true
    @State private var collapsedDirectories: Set<String> = []
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var iconSize = WorkspaceChangesLayout.treeIconSize

    private enum Layout {
        static let indentation: CGFloat = 16
        static let maximumIndentationDepth = 3
    }

    var body: some View {
        WorkspaceChangesSection(title: title, count: files.count, identifier: identifier, isExpanded: $isExpanded) {
            if files.isEmpty {
                Text("No \(title.lowercased()) files")
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(secondary)
            } else {
                tree
            }
        }
        .onChange(of: scope) { _, _ in collapsedDirectories.removeAll() }
    }

    private var secondary: Color {
        WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast)
    }

    private var tree: some View {
        let rows = WorkspaceChangeTree(files: files).visibleRows(collapsedPaths: collapsedDirectories)
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                Group {
                    switch row.node {
                    case .directory:
                        directoryRow(row)
                    case .file(let file):
                        fileRow(file, name: row.node.name)
                    }
                }
                .padding(.leading, indentation(for: row.depth))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func directoryRow(_ row: WorkspaceChangeTree.TreeRow) -> some View {
        let node = row.node
        let isCollapsed = collapsedDirectories.contains(node.path)
        return Button { toggleDirectory(node.path) } label: {
            directoryLabel(row, isCollapsed: isCollapsed)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Folder \(node.path), \(node.fileCount) files")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(isCollapsed ? "Double-tap to expand this folder" : "Double-tap to collapse this folder")
        .accessibilityIdentifier("changes.folder.\(identifier).\(node.path)")
    }

    private func directoryLabel(_ row: WorkspaceChangeTree.TreeRow, isCollapsed: Bool) -> some View {
        HStack(spacing: CreateWorkspaceFormStyle.rowSpacing) {
            Image(.folder)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(secondary)
                .accessibilityHidden(true)
            Text(row.depth >= Layout.maximumIndentationDepth ? row.node.path : row.node.name)
                .interFont(Constants.Typography.bodySEmphasized)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(row.node.fileCount)")
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(secondary)
            Image(isCollapsed ? .chevronRight : .chevronDown)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(secondary)
                .accessibilityHidden(true)
        }
        .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
        .multilineTextAlignment(.leading)
        .padding(.vertical, CreateWorkspaceFormStyle.controlVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: CreateWorkspaceFormStyle.controlHeight, alignment: .leading)
        .contentShape(.rect)
    }

    private func fileRow(_ file: WorkspaceChange, name: String) -> some View {
        Button { onSelect(file) } label: {
            fileLabel(file, name: name)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityHint("Opens the diff for \(file.path)")
        .accessibilityIdentifier("changes.file.\(identifier).\(file.path)")
    }

    private func fileLabel(_ file: WorkspaceChange, name: String) -> some View {
        HStack(alignment: .top, spacing: CreateWorkspaceFormStyle.rowSpacing) {
            Image(.file)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CreateWorkspaceFormStyle.rowSpacing) {
                Text(name)
                    .interFont(Constants.Typography.bodySEmphasized)
                    .tracking(CreateWorkspaceRepoStyle.nameTracking)
                    .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                fileMetadata(file)
                    .font(Constants.Typography.subtextXXS.font)
                    .foregroundStyle(secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .multilineTextAlignment(.leading)
        .padding(.vertical, CreateWorkspaceFormStyle.controlVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: CreateWorkspaceFormStyle.controlHeight, alignment: .leading)
        .contentShape(.rect)
    }

    @ViewBuilder
    private func fileMetadata(_ file: WorkspaceChange) -> some View {
        let status = file.status == "modified" ? nil : file.status.capitalized
        let label = [status, file.agentName].compactMap { $0 }.joined(separator: " · ")
        if !label.isEmpty || file.isBinary || file.hasLineStats {
            metadataLayout {
                if !label.isEmpty {
                    Text(label)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if file.isBinary {
                    Text("Binary")
                } else if file.hasLineStats {
                    WorkspaceChangeStats(additions: file.additions, deletions: file.deletions)
                        .fixedSize()
                }
            }
        }
    }

    private var metadataLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WorkspaceChangesLayout.statsSpacing))
            : AnyLayout(HStackLayout(alignment: .top, spacing: CreateWorkspaceFormStyle.rowSpacing))
    }

    private func indentation(for depth: Int) -> CGFloat {
        let step = dynamicTypeSize.isAccessibilitySize ? WorkspaceDetailStyle.accessibilityIndentation : Layout.indentation
        return CGFloat(min(depth, Layout.maximumIndentationDepth)) * step
    }

    private func toggleDirectory(_ path: String) {
        if collapsedDirectories.contains(path) {
            collapsedDirectories.remove(path)
        } else {
            collapsedDirectories.insert(path)
        }
    }
}
