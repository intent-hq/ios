import SwiftUI

struct WorkspaceFilesView: View {
    let workspaceId: String
    let store: WorkspaceFilesStore
    @Environment(BackendSession.self) private var session
    @State private var selectedFile: WorkspaceFileEntry?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var secondary: Color {
        WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            directoryState(path: ".")
            ForEach(store.rows) { row in
                VStack(alignment: .leading, spacing: 0) {
                    entryButton(row)
                    if row.isDirectory, store.expandedPaths.contains(row.path) {
                        directoryState(path: row.path)
                            .padding(.leading, indentation(for: row.depth + 1) - indentation(for: row.depth))
                    }
                }
                .padding(.leading, indentation(for: row.depth))
                .fileTreeGuides(depth: row.depth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fullScreenCover(item: $selectedFile) { file in
            WorkspaceFilePreview(link: .init(workspaceId: workspaceId, path: file.path), connection: session.connection)
        }
        .onChange(of: workspaceId) { _, _ in selectedFile = nil }
    }

    private func entryButton(_ row: WorkspaceFileTreeRow) -> some View {
        let isExpanded = store.expandedPaths.contains(row.path)
        return Button {
            if row.isDirectory {
                Task { await store.toggleDirectory(path: row.path) }
            } else {
                selectedFile = row.entry
            }
        } label: {
            WorkspaceFileTreeLabel(
                name: row.depth >= WorkspaceFileTreeLayout.maximumIndentationDepth ? row.path : row.name,
                isDirectory: row.isDirectory,
                isExpanded: isExpanded,
                showsChildGuide: WorkspaceFileTreeLayout.showsChildGuide(depth: row.depth, isExpanded: isExpanded)
            ) { EmptyView() }
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel(row.isDirectory ? "Folder \(row.path)" : row.path)
        .accessibilityValue(row.isDirectory ? (isExpanded ? "Expanded" : "Collapsed") : "")
        .accessibilityHint(row.isDirectory ? "Double-tap to \(isExpanded ? "collapse" : "expand") this folder" : "Opens the file")
        .accessibilityIdentifier("files.\(row.isDirectory ? "folder" : "file").\(row.path)")
    }

    @ViewBuilder
    private func directoryState(path: String) -> some View {
        if let error = store.errorsByPath[path] {
            VStack(alignment: .leading, spacing: WorkspaceDetailStyle.headingSpacing) {
                Text(error)
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(secondary)
                Button("Retry") { Task { await store.retry(path: path) } }
                    .buttonStyle(IntentButtonStyle(variant: .secondary))
                    .accessibilityIdentifier("files.retry.\(path)")
            }
        } else if store.loadingPaths.contains(path) || (path == "." && !store.hasLoaded) {
            ProgressView("Loading files…")
                .interFont(Constants.Typography.bodyS)
                .padding(.vertical, CreateWorkspaceFormStyle.controlVerticalPadding)
        } else if store.entriesByPath[path]?.isEmpty == true {
            Text(path == "." ? "No files yet" : "Empty folder")
                .interFont(Constants.Typography.bodyS)
                .foregroundStyle(secondary)
                .padding(.vertical, CreateWorkspaceFormStyle.controlVerticalPadding)
        }
    }

    private func indentation(for depth: Int) -> CGFloat {
        WorkspaceFileTreeLayout.indentation(for: depth, accessibility: dynamicTypeSize.isAccessibilitySize)
    }
}
