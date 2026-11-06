import SwiftUI

struct WorkspaceFileDiffView: View {
    @ScaledMetric(relativeTo: .title) private var emptyStateIconSize: CGFloat = 48
    @ScaledMetric(relativeTo: .subheadline) private var statusIconSize: CGFloat = 15
    /// Nil when `patch` supplies the diff (a pull request file's GitHub patch).
    let loader: WorkspaceDiffLoader?
    let path: String
    var staged = false
    var isBinary = false
    var commitHash: String?
    var embedded = false
    var patch: String?
    /// Off when the page's own header already names the file.
    var showsPath = true
    @State private var presentation: WorkspaceDiffPresentation?
    @State private var diffRows: WorkspaceDiffRows?
    @State private var showsFullDiff = false
    @State private var syntax: [WorkspaceDiffPresentation.RowID: [FileSyntaxRun]] = [:]
    @State private var syntaxIsDark = false
    @State private var retry = 0
    @State private var phase = LoadPhase.loading
    @State private var viewportSize = CGSize.zero
    @State private var diffContentHeight: CGFloat?
    @Environment(\.workspaceViewerUsesPanel) private var usesPanel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum LoadPhase: Equatable {
        case loading
        case failed(String)
        case loaded
    }

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
            if !embedded, showsPath {
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
            workspace: loader?.workspaceId ?? "",
            root: loader?.gitRootId,
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
        if phase == .loading {
            if embedded {
                ProgressView("Loading diff…")
                    .padding()
                    .frame(maxWidth: .infinity)
            } else {
                ProgressView("Loading diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if case let .failed(errorMessage) = phase {
            if embedded {
                compactStatus("Diff Unavailable", message: errorMessage) {
                    Image(systemName: "doc.text.magnifyingglass")
                }
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
                compactStatus("No Text Diff", message: emptyMessage) {
                    Image(.fileList)
                        .resizable()
                        .scaledToFit()
                        .frame(width: statusIconSize, height: statusIconSize)
                }
            } else {
                ContentUnavailableView {
                    Label {
                        Text("No Text Diff")
                    } icon: {
                        Image(.fileList)
                            .resizable()
                            .scaledToFit()
                            .frame(width: emptyStateIconSize, height: emptyStateIconSize)
                    }
                } description: {
                    Text(emptyMessage)
                }
            }
        } else {
            if embedded {
                VStack(alignment: .leading, spacing: 0) {
                    diffScrollView
                        .fixedSize(horizontal: false, vertical: true)
                    if let diffRows, diffRows.lineCount > WorkspaceDiffRows.embeddedLineLimit {
                        // Expanding inline would rebuild every row; the full-page diff builds rows lazily.
                        Button("Show All \(diffRows.lineCount.formatted()) Lines") { showsFullDiff = true }
                            .buttonStyle(IntentButtonStyle(variant: .secondary))
                            .padding([.horizontal, .bottom])
                            .accessibilityIdentifier("changes.diff.showAll")
                    }
                }
                .sheet(isPresented: $showsFullDiff) { fullDiff }
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

    private func compactStatus<Icon: View>(_ title: String, message: String, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(alignment: .leading, spacing: WorkspaceChangesLayout.sectionSpacing) {
            Label {
                Text(title)
            } icon: {
                icon()
            }
            .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            if case .failed = phase { retryButton }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var visibleRows: ArraySlice<WorkspaceDiffRow> {
        diffRows?.rows(limit: embedded ? WorkspaceDiffRows.embeddedLineLimit : nil) ?? []
    }

    @ViewBuilder
    private var diffScrollView: some View {
        if embedded {
            // The commit view's outer scroll view drives vertical scrolling, so rows cannot be lazy here.
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) { diffRowViews }
                    .frame(minWidth: viewportSize.width, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: true)
                    .modifier(DiffTextStyle())
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { diffContentHeight = $0 }
            }
            .defaultScrollAnchor(.topLeading)
            // Keep lazy section measurements stable when the horizontal scroller moves offscreen.
            .frame(height: diffContentHeight)
            .modifier(DiffViewport(viewportSize: $viewportSize))
        } else {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) { diffRowViews }
                    // A fixed width from the widest line keeps horizontal scrolling stable as rows load.
                    .frame(width: max(contentWidth, viewportSize.width), alignment: .leading)
                    .modifier(DiffTextStyle())
                    .frame(minHeight: viewportSize.height, alignment: .topLeading)
            }
            .defaultScrollAnchor(.topLeading)
            .modifier(DiffViewport(viewportSize: $viewportSize))
        }
    }

    private var diffRowViews: some View {
        ForEach(visibleRows) { row in
            switch row {
            case let .heading(_, text):
                Text(text)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, WorkspaceChangesLayout.sectionSpacing)
                    .padding(.horizontal, WorkspaceDiffRows.horizontalPadding)
            case let .line(id, line):
                diffLine(line, row: id)
            }
        }
    }

    private var fullDiff: some View {
        NavigationStack {
            Self(
                loader: loader, path: path, staged: staged, isBinary: isBinary, commitHash: commitHash, patch: patch
            )
            .navigationTitle("All Changes")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    IntentIconButton(icon: .close, label: "Done") { showsFullDiff = false }
                }
                .intentToolbarSurface()
            }
        }
    }

    private var contentWidth: CGFloat {
        diffRows?.contentWidth(font: WorkspaceDiffRows.font(for: dynamicTypeSize)) ?? 0
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
        .padding(.horizontal, WorkspaceDiffRows.horizontalPadding)
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
        phase = .loading
        presentation = nil
        diffRows = nil
        syntax = [:]
        defer { if !Task.isCancelled, phase == .loading { phase = .loaded } }
        if isBinary { return }
        if let patch {
            await show(WorkspaceDiffPresentation(hunks: WorkspaceDiffBuilder.hunks(patch: patch)))
            return
        }
        guard let loader else { return }
        do {
            let loaded: WorkspaceDiffPresentation
            if let commitHash {
                loaded = try await loader.commitPresentation(path: path, hash: commitHash)
            } else {
                let hunks = try await loader.workingFile(path: path, staged: staged)
                loaded = WorkspaceDiffPresentation(hunks: hunks)
            }
            try Task.checkCancellation()
            await show(loaded)
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { phase = .failed(error.localizedDescription) }
        }
    }

    private func show(_ loaded: WorkspaceDiffPresentation) async {
        let rows = await Task.detached(priority: .userInitiated) { WorkspaceDiffRows(hunks: loaded.hunks) }.value
        guard !Task.isCancelled else { return }
        diffRows = rows
        presentation = loaded
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

private struct DiffTextStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(.bottom)
    }
}

private struct DiffViewport: ViewModifier {
    @Binding var viewportSize: CGSize

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
            .accessibilityIdentifier("changes.diff.scroll")
    }
}
