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
    let connectionManager: ConnectionManagerRouting
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var store: WorkspaceChangesStore
    @State private var selectedFile: WorkspaceChange?
    @State private var selectedCommit: WorkspaceCommit?

    init(workspaceId: String, connectionManager: ConnectionManagerRouting) {
        self.workspaceId = workspaceId
        self.connectionManager = connectionManager
        _store = State(initialValue: WorkspaceChangesStore(connectionManager: connectionManager))
    }

    var body: some View {
        List {
            if let error = store.errorMessage {
                Section {
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
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background(for: colorScheme))
        .refreshable { await store.refresh(workspaceId: workspaceId) }
        .task {
            await store.startObserving(workspaceId: workspaceId)
        }
        .onDisappear { store.stopObserving() }
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
        WorkspaceDiffLoader(connectionManager: connectionManager, workspaceId: workspaceId)
    }

    private func fileSection(_ title: String, files: [WorkspaceChange]) -> some View {
        Section {
            if files.isEmpty {
                Text("No \(title.lowercased()) files").foregroundStyle(.secondary)
            }
            ForEach(files) { file in
                Button { selectedFile = file } label: {
                    VStack(alignment: .leading, spacing: WorkspaceChangesLayout.rowSpacing) {
                        Text(file.path).interFont(Constants.Typography.bodyXS).foregroundStyle(.primary)
                        HStack {
                            Text(file.status.capitalized)
                            if let agentName = file.agentName { Text("· \(agentName)") }
                            Spacer()
                            if file.isBinary {
                                Text("Binary")
                            } else {
                                WorkspaceChangeStats(additions: file.additions, deletions: file.deletions)
                            }
                        }
                        .font(Constants.Typography.subtextXXS.font)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, WorkspaceChangesLayout.rowSpacing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the file diff")
            }
        } header: {
            Text("\(title) (\(files.count))")
        }
    }

    private var commitsSection: some View {
        Section("Commits") {
            if store.commits.isEmpty {
                Text("No workspace commits yet").foregroundStyle(.secondary)
            }
            ForEach(store.commits) { commit in
                commitRow(commit)
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
                    .interFont(Constants.Typography.bodyXS).foregroundStyle(.primary)
                HStack {
                    Text(String(commit.hash.prefix(WorkspaceChangesLayout.shortHashLength))).monospaced()
                    Text(commit.author)
                    if commit.agentId != nil {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .accessibilityLabel("Agent commit")
                    }
                    Spacer()
                    Text(commit.isPushed ? "Pushed" : "Local")
                }
                .font(Constants.Typography.subtextXXS.font).foregroundStyle(.secondary)
            }
            .padding(.vertical, WorkspaceChangesLayout.rowSpacing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the commit diff")
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
