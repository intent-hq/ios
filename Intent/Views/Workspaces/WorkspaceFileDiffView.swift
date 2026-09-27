import SwiftUI

struct WorkspaceFileDiffView: View {
    let loader: WorkspaceDiffLoader
    let path: String
    var staged = false
    var isBinary = false
    var commitHash: String?
    @State private var hunks: [WorkspaceDiffHunk] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(path)
                .font(.subheadline.monospaced())
                .textSelection(.enabled)
                .padding()
            Divider()
            content
        }
        .background(Theme.background(for: colorScheme))
        .task { await load() }
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
                Button("Retry") { Task { await load() } }
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
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(hunks.indices, id: \.self) { index in
                        let hunk = hunks[index]
                        Text(hunk.heading)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, WorkspaceChangesLayout.sectionSpacing)
                            .padding(.horizontal)
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                            diffLine(line)
                        }
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.bottom)
            }
            .defaultScrollAnchor(.topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func diffLine(_ line: WorkspaceDiffLine) -> some View {
        HStack(alignment: .top, spacing: WorkspaceChangesLayout.sectionSpacing) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: WorkspaceChangesLayout.lineNumberWidth, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: WorkspaceChangesLayout.lineNumberWidth, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.type.marker).fixedSize()
            Text(line.content.hasSuffix("\n") ? String(line.content.dropLast()) : line.content)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
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
        defer { isLoading = false }
        if isBinary { return }
        do {
            if let commitHash {
                hunks = try await loader.commitFile(path: path, hash: commitHash)
            } else {
                hunks = try await loader.workingFile(path: path, staged: staged)
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
