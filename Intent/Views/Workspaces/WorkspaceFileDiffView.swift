import SwiftUI

struct WorkspaceFileDiffView: View {
    let loader: WorkspaceDiffLoader
    let path: String
    var staged = false
    var isBinary = false
    var commitHash: String?
    var embedded = false
    @State private var presentation: WorkspaceDiffPresentation?
    @State private var syntax: [WorkspaceDiffPresentation.RowID: [FileSyntaxRun]] = [:]
    @State private var syntaxIsDark = false
    @State private var retry = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var viewportSize = CGSize.zero
    @Environment(\.workspaceViewerUsesPanel) private var usesPanel
    @Environment(\.colorScheme) private var colorScheme

    private struct LoadID: Hashable {
        let workspace: String
        let root: String?
        let path: String
        let staged: Bool
        let binary: Bool
        let commit: String?
        let retry: Int
    }

    private struct SyntaxID: Hashable {
        let presentation: UUID?
        let dark: Bool
    }

    private var hunks: [WorkspaceDiffHunk] { presentation?.hunks ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded {
                Text(path)
                    .font(.subheadline.monospaced())
                    .textSelection(.enabled)
                    .padding()
                Divider()
            }
            content
        }
        .background(usesPanel ? IPadShellStyle.panel(for: colorScheme) : WorkspaceDetailStyle.background(for: colorScheme))
        .task(id: LoadID(
            workspace: loader.workspaceId,
            root: loader.gitRootId,
            path: path,
            staged: staged,
            binary: isBinary,
            commit: commitHash,
            retry: retry
        )) { await load() }
        .task(id: SyntaxID(presentation: presentation?.id, dark: colorScheme == .dark)) {
            await highlight()
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            if embedded {
                ProgressView("Loading diff…")
                    .padding()
                    .frame(maxWidth: .infinity)
            } else {
                ProgressView("Loading diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let errorMessage {
            if embedded {
                compactStatus("Diff Unavailable", systemImage: "doc.text.magnifyingglass", message: errorMessage)
            } else {
                ContentUnavailableView {
                    Label("Diff Unavailable", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text(errorMessage)
                } actions: {
                    retryButton
                }
            }
        } else if hunks.isEmpty {
            if embedded {
                compactStatus("No Text Diff", systemImage: "doc.text", message: emptyMessage)
            } else {
                ContentUnavailableView {
                    Label("No Text Diff", systemImage: "doc.text")
                } description: {
                    Text(emptyMessage)
                }
            }
        } else {
            if embedded {
                diffScrollView
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                diffScrollView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var emptyMessage: String {
        isBinary
            ? "Binary file. A text diff is not available."
            : "This file may be binary, too large, empty, or no longer changed."
    }

    private var retryButton: some View {
        Button("Retry") { retry += 1 }
            .buttonStyle(IntentButtonStyle(variant: .secondary))
    }

    private func compactStatus(_ title: String, systemImage: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: WorkspaceChangesLayout.sectionSpacing) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            if errorMessage != nil { retryButton }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var diffScrollView: some View {
        ScrollView(embedded ? .horizontal : [.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(hunks.indices, id: \.self) { index in
                    let hunk = hunks[index]
                    Text(hunk.heading)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, WorkspaceChangesLayout.sectionSpacing)
                        .padding(.horizontal)
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { lineIndex, line in
                        diffLine(line, row: .init(hunk: index, line: lineIndex))
                    }
                }
            }
            .frame(minWidth: viewportSize.width, alignment: .leading)
            .fixedSize(horizontal: true, vertical: true)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(.bottom)
            .frame(minHeight: embedded ? nil : viewportSize.height, alignment: .topLeading)
        }
        .defaultScrollAnchor(.topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
        .accessibilityIdentifier("changes.diff.scroll")
    }

    private func diffLine(_ line: WorkspaceDiffLine, row: WorkspaceDiffPresentation.RowID) -> some View {
        HStack(alignment: .top, spacing: WorkspaceChangesLayout.sectionSpacing) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: WorkspaceChangesLayout.lineNumberWidth, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: WorkspaceChangesLayout.lineNumberWidth, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.type.marker).fixedSize()
            Text(WorkspaceDiffSyntax.text(
                line, runs: syntaxIsDark == (colorScheme == .dark) ? syntax[row] ?? [] : []
            ))
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(lineBackground(line.type))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(line.type.rawValue), line \(line.newNumber ?? line.oldNumber ?? 0): \(line.content)")
    }

    private func lineBackground(_ kind: WorkspaceDiffLine.Kind) -> Color {
        switch kind {
        case .addition: Color.green.opacity(WorkspaceChangesLayout.diffTintOpacity)
        case .deletion: Color.red.opacity(WorkspaceChangesLayout.diffTintOpacity)
        case .context: .clear
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        presentation = nil
        syntax = [:]
        defer { if !Task.isCancelled { isLoading = false } }
        if isBinary { return }
        do {
            let loaded: WorkspaceDiffPresentation
            if let commitHash {
                loaded = try await loader.commitPresentation(path: path, hash: commitHash)
            } else {
                let hunks = try await loader.workingFile(path: path, staged: staged)
                loaded = WorkspaceDiffPresentation(hunks: hunks)
            }
            try Task.checkCancellation()
            presentation = loaded
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    private func highlight() async {
        syntax = [:]
        guard let presentation else { return }
        let dark = colorScheme == .dark
        let runs = await WorkspaceDiffSyntax.highlight(presentation, path: path, dark: dark)
        guard !Task.isCancelled, self.presentation?.id == presentation.id, dark == (colorScheme == .dark) else { return }
        syntaxIsDark = dark
        syntax = runs
    }
}
