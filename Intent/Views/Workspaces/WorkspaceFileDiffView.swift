import SwiftUI

struct WorkspaceFileDiffView: View {
    let loader: WorkspaceDiffLoader
    let path: String
    var staged = false
    var isBinary = false
    var commitHash: String?
    @State private var hunks: [WorkspaceDiffHunk] = []
    @State private var highlightedLines: [Int: WorkspaceDiffHighlighter.Lines] = [:]
    @State private var retryCount = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var viewportSize = CGSize.zero
    @Environment(\.colorScheme) private var colorScheme

    private struct LoadID: Hashable {
        let workspaceId: String
        let gitRootId: String?
        let path: String
        let staged: Bool
        let isBinary: Bool
        let commitHash: String?
        let retryCount: Int
    }

    private var loadID: LoadID {
        LoadID(
            workspaceId: loader.workspaceId,
            gitRootId: loader.gitRootId,
            path: path,
            staged: staged,
            isBinary: isBinary,
            commitHash: commitHash,
            retryCount: retryCount
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(path)
                .font(.subheadline.monospaced())
                .textSelection(.enabled)
                .padding()
            Divider()
            content
        }
        .background(WorkspaceDetailStyle.background(for: colorScheme))
        .task(id: loadID) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Diff Unavailable", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Retry") { retryCount += 1 }
                    .buttonStyle(IntentButtonStyle(variant: .secondary))
            }
        } else if hunks.isEmpty {
            ContentUnavailableView {
                Label("No Text Diff", systemImage: "doc.text")
            } description: {
                Text(isBinary
                     ? "Binary file. A text diff is not available."
                     : "This file may be binary, too large, empty, or no longer changed.")
            }
        } else {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(hunks.indices, id: \.self) { index in
                        let hunk = hunks[index]
                        Text(hunk.heading)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, WorkspaceChangesLayout.sectionSpacing)
                            .padding(.horizontal)
                        ForEach(Array(hunk.lines.enumerated()), id: \.element.id) { lineIndex, line in
                            diffLine(line, tokens: highlightedLines[index]?[lineIndex] ?? [])
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: true)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.bottom)
                .frame(minWidth: viewportSize.width, minHeight: viewportSize.height, alignment: .topLeading)
            }
            .defaultScrollAnchor(.topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
            .accessibilityIdentifier("changes.diff.scroll")
        }
    }

    private func diffLine(_ line: WorkspaceDiffLine, tokens: [WorkspaceSyntaxHighlighter.Token]) -> some View {
        HStack(alignment: .top, spacing: WorkspaceChangesLayout.sectionSpacing) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: WorkspaceChangesLayout.lineNumberWidth, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: WorkspaceChangesLayout.lineNumberWidth, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.type.marker).fixedSize()
            Text(highlightedText(line.content, tokens: tokens))
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
        .background(lineBackground(line.type))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(line.type.rawValue), line \(line.newNumber ?? line.oldNumber ?? 0): \(line.content)")
    }

    private func highlightedText(_ content: String, tokens: [WorkspaceSyntaxHighlighter.Token]) -> AttributedString {
        var text = AttributedString(WorkspaceDiffHighlighter.displayedText(content))
        for token in tokens {
            guard let range = Range(token.range, in: text) else { continue }
            text[range].foregroundColor = Color(uiColor: WorkspaceSyntaxTheme.color(for: token.scope))
        }
        return text
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
        hunks = []
        highlightedLines = [:]
        if isBinary {
            isLoading = false
            return
        }
        do {
            if let commitHash {
                hunks = try await loader.commitFile(path: path, hash: commitHash)
            } else {
                hunks = try await loader.workingFile(path: path, staged: staged)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
        // Display the plain diff immediately; parsing and range splitting happen off actor.
        for (index, hunk) in hunks.enumerated() {
            guard let tokens = try? await WorkspaceDiffHighlighter.highlight(hunk, path: path),
                  !Task.isCancelled else { return }
            if !tokens.isEmpty { highlightedLines[index] = tokens }
        }
    }
}
