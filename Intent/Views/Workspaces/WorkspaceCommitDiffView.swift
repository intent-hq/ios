import SwiftUI

enum WorkspaceCommitLayout {
    static let padding: CGFloat = 16
    static let rowPadding: CGFloat = 12
    static let spacing: CGFloat = 8
    static let textSpacing: CGFloat = 4
    static let sectionSpacing: CGFloat = 24
    static let iconSize: CGFloat = 16
    static let floatingShadowOpacity = 0.16
    static let floatingShadowRadius: CGFloat = 8
    static let floatingShadowOffset: CGFloat = 4
}

struct WorkspaceCommitDiffView: View {
    let loader: WorkspaceDiffLoader
    let commit: WorkspaceCommit
    @State private var files: [WorkspaceCommitFile] = []
    @State private var showsDetails = false
    @State private var showsFiles = false
    @State private var jumpPath: String?
    @State private var collapsedPaths: Set<String> = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var retry = 0
    @State private var jumpControlHeight: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            IntentContentSwitcher(
                selection: $showsDetails,
                options: [.init(value: false, title: "Changes"), .init(value: true, title: "Details")],
                accessibilityLabel: "Commit view",
                identifierPrefix: "commit.view"
            )
            .padding(.horizontal, WorkspaceCommitLayout.padding)
            .padding(.bottom, WorkspaceCommitLayout.rowPadding)
            .background(Theme.sidebar(for: colorScheme))
            ZStack {
                changes
                    .opacity(showsDetails ? 0 : 1)
                    .allowsHitTesting(!showsDetails)
                    .accessibilityHidden(showsDetails)
                if showsDetails { WorkspaceCommitDetailsView(commit: commit) }
            }
        }
        .foregroundStyle(Theme.foreground(for: colorScheme))
        .background(Theme.background(for: colorScheme))
        .navigationTitle("Commit Changes")
        .toolbarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar(for: colorScheme), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task(id: retry) { await load() }
    }

    private var changes: some View {
        ScrollViewReader { proxy in
            changesContent
            .accessibilityIdentifier("commit.changes.scroll")
            .overlay(alignment: .bottomTrailing) {
                if !files.isEmpty {
                    jumpButton
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { jumpControlHeight = $0 }
                }
            }
            .sheet(
                isPresented: $showsFiles,
                onDismiss: {
                    guard let jumpPath else { return }
                    proxy.scrollTo(jumpPath, anchor: .top)
                    self.jumpPath = nil
                },
                content: {
                    WorkspaceCommitFilePicker(files: files) { path in
                        collapsedPaths.remove(path)
                        jumpPath = path
                        showsFiles = false
                    }
                    .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            )
        }
    }

    private var changesContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                commitHeader
                fileContent
            }
            .padding(.bottom, jumpControlHeight + WorkspaceCommitLayout.padding)
        }
    }

    @ViewBuilder
    private var fileContent: some View {
        if isLoading {
            ProgressView("Loading commit…")
                .frame(maxWidth: .infinity).padding(WorkspaceCommitLayout.sectionSpacing)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Commit Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Retry") { retry += 1 }
                    .buttonStyle(IntentButtonStyle(variant: .secondary))
            }
        } else if files.isEmpty {
            ContentUnavailableView("No Changed Files", systemImage: "doc.text")
        } else {
            summary
            ForEach(files) { file in fileSection(file).id(file.path) }
        }
    }

    private var jumpButton: some View {
        Button { showsFiles = true } label: {
            Label("Jump to file", image: "FileList")
        }
        .buttonStyle(IntentButtonStyle(variant: .secondary))
        .shadow(
            color: .black.opacity(WorkspaceCommitLayout.floatingShadowOpacity),
            radius: WorkspaceCommitLayout.floatingShadowRadius,
            y: WorkspaceCommitLayout.floatingShadowOffset
        )
        .padding(.horizontal, WorkspaceCommitLayout.padding)
        .padding(.vertical, WorkspaceCommitLayout.padding)
        .accessibilityIdentifier("commit.jump")
    }

    private var commitHeader: some View {
        VStack(alignment: .leading, spacing: WorkspaceCommitLayout.spacing) {
            Text(commit.author)
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Text(commit.message)
                .interFont(Constants.Typography.bodyM)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WorkspaceCommitLayout.padding)
    }

    private var summary: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WorkspaceCommitLayout.spacing))
            : AnyLayout(HStackLayout(spacing: WorkspaceCommitLayout.spacing))
        return layout {
            Text(files.count == 1 ? "1 file changed" : "\(files.count) files changed")
                .interFont(Constants.Typography.bodySEmphasized)
                .frame(maxWidth: .infinity, alignment: .leading)
            WorkspaceChangeStats(
                additions: files.reduce(0) { $0 + $1.additions },
                deletions: files.reduce(0) { $0 + $1.deletions }
            )
        }
        .padding(.horizontal, WorkspaceCommitLayout.padding)
        .padding(.vertical, WorkspaceCommitLayout.rowPadding)
    }

    private func fileSection(_ file: WorkspaceCommitFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if collapsedPaths.contains(file.path) {
                    collapsedPaths.remove(file.path)
                } else {
                    collapsedPaths.insert(file.path)
                }
            } label: {
                HStack(spacing: WorkspaceCommitLayout.spacing) {
                    Image(collapsedPaths.contains(file.path) ? .chevronRight : .chevronDown)
                        .resizable()
                        .scaledToFit()
                        .frame(width: WorkspaceCommitLayout.iconSize, height: WorkspaceCommitLayout.iconSize)
                        .accessibilityHidden(true)
                    WorkspaceCommitFileLabel(file: file)
                }
                .padding(.horizontal, WorkspaceCommitLayout.rowPadding)
                .padding(.vertical, WorkspaceCommitLayout.rowPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(IntentContentButtonStyle())
            .background(Theme.sidebar(for: colorScheme))
            .accessibilityIdentifier("commit.file.\(file.path)")
            .accessibilityValue(collapsedPaths.contains(file.path) ? "Collapsed" : "Expanded")
            if !collapsedPaths.contains(file.path) {
                WorkspaceFileDiffView(loader: loader, path: file.path, commitHash: commit.hash, embedded: true)
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            let loaded = try await loader.commitFiles(hash: commit.hash)
            try Task.checkCancellation()
            files = loaded
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}
