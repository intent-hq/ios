import SwiftUI

enum WorkspaceChangesLayout {
    static let rowSpacing: CGFloat = 4
    static let sectionSpacing: CGFloat = 8
    static let statsSpacing: CGFloat = 6
    static let lineNumberWidth: CGFloat = 32
    static let diffTintOpacity = 0.12
    static let shortHashLength = 7
}

struct WorkspaceChangesView: View {
    let workspaceId: String
    let store: WorkspaceChangesStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedFile: WorkspaceChange?
    @State private var selectedCommit: WorkspaceCommit?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: WorkspaceDetailStyle.sectionSpacing) {
            repositorySection
            if let error = store.errorMessage {
                VStack(alignment: .leading, spacing: WorkspaceDetailStyle.headingSpacing) {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { Task { await store.refresh(workspaceId: workspaceId) } }
                }
            }
            if store.isLoading, !store.hasLoaded {
                ProgressView("Loading changes…")
            } else if store.hasLoaded {
                fileSection("Unstaged", files: store.unstagedChanges)
                fileSection("Staged", files: store.stagedChanges)
                commitsSection
                if store.isTruncated {
                    Text("Some changed files could not be listed. Open the desktop app to see all changes.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, WorkspaceDetailStyle.pageInset)
        .padding(.bottom, WorkspaceDetailStyle.pageInset)
        .task(id: workspaceId) {
            await store.startObserving(workspaceId: workspaceId)
        }
        .onDisappear { store.stopObserving() }
        .onChange(of: store.selectedRootId) { _, _ in
            selectedFile = nil
            selectedCommit = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.refresh(workspaceId: workspaceId) }
            }
        }
        .sheet(item: $selectedFile) { file in
            NavigationStack {
                WorkspaceFileDiffView(
                    loader: loader,
                    path: file.path,
                    staged: file.stage == "staged",
                    isBinary: file.isBinary
                )
                .navigationTitle(file.stage == "staged" ? "Staged Changes" : "Unstaged Changes")
                .toolbarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedFile = nil } } }
            }
        }
        .sheet(item: $selectedCommit) { commit in
            NavigationStack {
                WorkspaceCommitDiffView(loader: loader, commit: commit)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedCommit = nil } } }
            }
        }
    }

    private var loader: WorkspaceDiffLoader {
        WorkspaceDiffLoader(connectionManager: store.connectionManager, workspaceId: workspaceId, gitRootId: store.selectedRootId)
    }

    @ViewBuilder
    private var repositorySection: some View {
        if !store.roots.isEmpty || store.repositoryErrorMessage != nil {
            VStack(alignment: .leading, spacing: WorkspaceDetailStyle.headingSpacing) {
                Picker("Repository", selection: repositorySelection) {
                    Text("Main repository").tag("")
                    ForEach(store.roots) { root in
                        Text(root.displayName).tag(root.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("changes.repository")
                if let error = store.repositoryErrorMessage {
                    Text(error).foregroundStyle(.secondary)
                    Button("Reload repositories") { Task { await store.refresh(workspaceId: workspaceId) } }
                }
            }
        }
    }

    private var repositorySelection: Binding<String> {
        Binding(
            get: { store.selectedRootId ?? "" },
            set: { id in Task { await store.selectRoot(id: id.isEmpty ? nil : id) } }
        )
    }

    private func fileSection(_ title: String, files: [WorkspaceChange]) -> some View {
        VStack(alignment: .leading, spacing: WorkspaceDetailStyle.sectionHeadingSpacing) {
            sectionHeading("\(title) (\(files.count))")
            if files.isEmpty {
                Text("No \(title.lowercased()) files").foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: WorkspaceDetailStyle.rowSpacing) {
                ForEach(files) { file in
                    fileRow(file)
                }
            }
        }
    }

    private func fileRow(_ file: WorkspaceChange) -> some View {
        Button { selectedFile = file } label: {
            VStack(alignment: .leading, spacing: WorkspaceChangesLayout.rowSpacing) {
                Text(file.path).interFont(Constants.Typography.bodyS).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(file.status.capitalized)
                    if let agentName = file.agentName { Text("· \(agentName)") }
                    Spacer()
                    if file.isBinary {
                        Text("Binary")
                    } else if file.hasLineStats {
                        WorkspaceChangeStats(additions: file.additions, deletions: file.deletions)
                    }
                }
                .font(Constants.Typography.subtextXXS.font)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: WorkspaceDetailStyle.controlSize, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the file diff")
    }

    private var commitsSection: some View {
        VStack(alignment: .leading, spacing: WorkspaceDetailStyle.sectionHeadingSpacing) {
            sectionHeading("Commits")
            if store.commits.isEmpty {
                Text("No workspace commits yet").foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: WorkspaceDetailStyle.rowSpacing) {
                ForEach(store.commits) { commit in
                    commitRow(commit)
                }
            }
            if store.hasMoreCommits {
                Button {
                    Task { await store.loadMoreCommits() }
                } label: {
                    if store.isLoadingMore { ProgressView() } else { Text("Load more commits") }
                }
                .disabled(store.isLoadingMore)
            }
        }
    }

    private func commitRow(_ commit: WorkspaceCommit) -> some View {
        Button { selectedCommit = commit } label: {
            VStack(alignment: .leading, spacing: WorkspaceChangesLayout.rowSpacing) {
                Text(commit.message.components(separatedBy: "\n").first ?? commit.message)
                    .interFont(Constants.Typography.bodyS).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(String(commit.hash.prefix(WorkspaceChangesLayout.shortHashLength))).monospaced()
                    Text(commit.author)
                    if commit.agentId != nil {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .accessibilityLabel("Agent commit")
                    }
                    Spacer()
                    if commit.isPushedKnown {
                        Text(commit.isPushed ? "Pushed" : "Local")
                    }
                }
                .font(Constants.Typography.subtextXXS.font).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: WorkspaceDetailStyle.controlSize, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the commit diff")
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .interFont(Constants.Typography.bodyM)
            .tracking(WorkspaceDetailStyle.rowTitleTracking)
            .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
            .accessibilityAddTraits(.isHeader)
    }
}

struct WorkspaceChangeStats: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: WorkspaceChangesLayout.statsSpacing) {
            Text("+\(additions)").foregroundStyle(.green)
            Text("−\(deletions)").foregroundStyle(.red)
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(additions) additions, \(deletions) deletions")
    }
}
