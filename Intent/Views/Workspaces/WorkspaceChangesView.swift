import SwiftUI

enum WorkspaceChangesLayout {
    static let treeIconSize: CGFloat = 16
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
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedFile: WorkspaceChange?
    @State private var selectedCommit: WorkspaceCommit?
    @State private var areCommitsExpanded = true

    var body: some View {
        LazyVStack(alignment: .leading, spacing: CreateWorkspaceRepoStyle.sectionSpacing) {
            repositorySection
            if let error = store.errorMessage {
                VStack(alignment: .leading, spacing: WorkspaceDetailStyle.headingSpacing) {
                    Text(error).interFont(Constants.Typography.bodyS).foregroundStyle(secondary)
                    Button("Retry") { Task { await store.refresh(workspaceId: workspaceId) } }
                        .buttonStyle(IntentButtonStyle(variant: .secondary))
                }
            }
            if store.isLoading, !store.hasLoaded {
                ProgressView {
                    Text("Loading changes…").interFont(Constants.Typography.bodyS)
                }
            } else if store.hasLoaded {
                fileSection("Unstaged", identifier: "unstaged", files: store.unstagedChanges)
                fileSection("Staged", identifier: "staged", files: store.stagedChanges)
                commitsSection
                if store.isTruncated {
                    Text("Some changed files could not be listed. Open the desktop app to see all changes.")
                        .interFont(Constants.Typography.bodyS)
                        .foregroundStyle(secondary)
                }
            }
        }
        .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
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
            VStack(alignment: .leading, spacing: CreateWorkspaceFormStyle.rowSpacing) {
                Text("Repository")
                    .interFont(Constants.Typography.bodyS)
                Menu {
                    Picker("Repository", selection: repositorySelection) {
                        Text("Main repository").tag("")
                        ForEach(store.roots) { root in
                            Text(root.displayName).tag(root.id)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    CreateWorkspaceChoiceLabel(title: repositoryName, surface: WorkspaceDetailStyle.surface(for: colorScheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Repository")
                .accessibilityValue(repositoryName)
                .accessibilityIdentifier("changes.repository")
                if let error = store.repositoryErrorMessage {
                    Text(error).interFont(Constants.Typography.bodyS).foregroundStyle(secondary)
                    Button("Reload repositories") { Task { await store.refresh(workspaceId: workspaceId) } }
                        .buttonStyle(IntentButtonStyle(variant: .secondary))
                }
            }
        }
    }

    private var repositoryName: String {
        store.roots.first { $0.id == store.selectedRootId }?.displayName ?? String(localized: "Main repository")
    }

    private var secondary: Color {
        WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast)
    }

    private var repositorySelection: Binding<String> {
        Binding(
            get: { store.selectedRootId ?? "" },
            set: { id in Task { await store.selectRoot(id: id.isEmpty ? nil : id) } }
        )
    }

    private func fileSection(_ title: String, identifier: String, files: [WorkspaceChange]) -> some View {
        WorkspaceChangesFileTree(
            title: title,
            identifier: identifier,
            files: files,
            scope: "\(workspaceId):\(store.selectedRootId ?? "")"
        ) { selectedFile = $0 }
    }

    private var commitsSection: some View {
        WorkspaceChangesSection(title: "Commits", count: store.commits.count, identifier: "commits", isExpanded: $areCommitsExpanded) {
            if store.commits.isEmpty {
                Text("No workspace commits yet")
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(secondary)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.commits) { commit in
                    commitRow(commit)
                        .overlay(alignment: .bottom) {
                            if commit.id != store.commits.last?.id { rowDivider }
                        }
                }
            }
            if store.hasMoreCommits {
                Button {
                    Task { await store.loadMoreCommits() }
                } label: {
                    HStack(spacing: CreateWorkspaceFormStyle.rowSpacing) {
                        if store.isLoadingMore { ProgressView() }
                        Text("Load more commits")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(IntentButtonStyle(variant: .secondary))
                .disabled(store.isLoadingMore)
            }
        }
    }

    private func commitRow(_ commit: WorkspaceCommit) -> some View {
        Button { selectedCommit = commit } label: {
            WorkspaceChangesRow(title: commit.message.components(separatedBy: "\n").first ?? commit.message) {
                metadataLayout {
                    HStack(spacing: WorkspaceChangesLayout.statsSpacing) {
                        Text(commit.author)
                            .fixedSize(horizontal: false, vertical: true)
                        if commit.agentId != nil {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .accessibilityLabel("Agent commit")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: WorkspaceChangesLayout.statsSpacing) {
                        Text(String(commit.hash.prefix(WorkspaceChangesLayout.shortHashLength))).monospaced()
                        if commit.isPushedKnown {
                            Text(commit.isPushed ? "Pushed" : "Local")
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the commit diff")
    }

    private var metadataLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WorkspaceChangesLayout.statsSpacing))
            : AnyLayout(HStackLayout(alignment: .top, spacing: CreateWorkspaceFormStyle.rowSpacing))
    }

    private var rowDivider: some View {
        CreateWorkspaceRepoStyle.divider(for: colorScheme)
            .frame(height: CreateWorkspaceRepoStyle.dividerHeight)
            .accessibilityHidden(true)
    }
}

private struct WorkspaceChangesRow<Detail: View>: View {
    let title: String
    @ViewBuilder let detail: () -> Detail
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var iconSize = CreateWorkspaceRepoStyle.iconSize

    var body: some View {
        HStack(spacing: CreateWorkspaceRepoStyle.rowSpacing) {
            text
            Image(.chevronRight)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast))
                .accessibilityHidden(true)
        }
        .multilineTextAlignment(.leading)
        .padding(CreateWorkspaceFormStyle.pagePadding)
        .frame(maxWidth: .infinity, minHeight: CreateWorkspaceRepoStyle.rowMinimumHeight, alignment: .leading)
        .contentShape(.rect)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: CreateWorkspaceRepoStyle.rowTextSpacing) {
            Text(title)
                .interFont(Constants.Typography.bodySEmphasized)
                .tracking(CreateWorkspaceRepoStyle.nameTracking)
                .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            detail()
                .font(Constants.Typography.subtextXXS.font)
                .tracking(CreateWorkspaceRepoStyle.fullNameTracking)
                .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
