import SwiftUI

/// Pull request rows for the workspace list page. A changed query reloads
/// (search text debounced); an unchanged query keeps the cached rows when
/// switching back from workspaces.
struct PullRequestListContent: View {
    let store: PullRequestListStore
    let query: PullRequestListStore.Query
    let workspaces: [Workspace]
    let groupsByProject: Bool
    let onOpenWorkspace: (String) -> Void
    let onOpenDetail: (PullRequestListItem) -> Void
    let onOpenAgent: (String) -> Void
    let onCreateWorkspace: (PullRequestListItem) -> Void
    @State private var revealedTarget: WorkspaceSwipeTarget?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.openURL) private var openURL
    @Environment(\.isRemoteReadOnly) private var isRemoteReadOnly

    var body: some View {
        let links = PullRequestListItem.linkedWorkspaces(workspaces)
        let showsRepository = query.repositories.count != 1
        Group {
            if store.items.isEmpty {
                placeholder
            } else {
                if groupsByProject {
                    ForEach(PullRequestListItem.groupedByProject(store.items)) { group in
                        groupHeading(group.title)
                        ForEach(group.items) { item in
                            // Distinct from the flat list's ids so the lazy
                            // stack cannot reuse a row that shows the repository.
                            row(item, linkedWorkspace: links[item.id], showsRepository: false)
                                .id("grouped:\(item.id)")
                        }
                    }
                } else {
                    ForEach(store.items) { item in
                        row(item, linkedWorkspace: links[item.id], showsRepository: showsRepository)
                    }
                }
                if store.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Constants.WorkspaceRow.spaciousPadding)
                } else if isRemoteReadOnly {
                    // A drop is not an error; the list reloads on reconnect.
                } else if case .failed(let error) = store.phase {
                    failureRow(error) { await store.load(query) }
                } else if let error = store.loadMoreError {
                    failureRow(error) { await store.loadMore() }
                }
            }
        }
        .onChange(of: isRemoteReadOnly) { _, readOnly in
            guard !readOnly else { return }
            if case .failed = store.phase {
                Task { await store.load(query) }
            } else if store.loadMoreError != nil {
                Task { await store.loadMore() }
            }
        }
    }

    /// Run from `.task(id: query)` on the page; rows are lazy, so the
    /// trigger cannot live on them.
    static func sync(_ store: PullRequestListStore, to query: PullRequestListStore.Query) async {
        guard store.loadedQuery != query || store.phase != .ready else { return }
        if let loaded = store.loadedQuery, loaded.text != query.text {
            try? await Task.sleep(for: Constants.GitHubRepoPicker.searchDebounce)
            guard !Task.isCancelled else { return }
        }
        await store.load(query)
    }

    private func row(_ item: PullRequestListItem, linkedWorkspace: Workspace?, showsRepository: Bool) -> some View {
        PullRequestSwipeRow(
            item: item,
            showsRepository: showsRepository,
            linkedWorkspace: linkedWorkspace,
            revealedTarget: $revealedTarget
        ) {
            onOpenDetail(item)
        } onSwipe: {
            startWork(on: item, linkedWorkspace: linkedWorkspace)
        } menuItems: {
            if let url = item.url {
                Button { openURL(url) } label: { Label("Open on GitHub", image: "Github") }
                ShareLink(item: url) { Label("Share", image: "Upload") }
            }
            if let linkedWorkspace {
                Button { onOpenWorkspace(linkedWorkspace.id) } label: { Label("Open workspace", image: "Spaces") }
                Button { onOpenAgent(linkedWorkspace.id) } label: { Label("Open agent", image: "Agents") }
            } else {
                Button { onCreateWorkspace(item) } label: { Label("New workspace", image: "AddIcon") }
                    .disabledWhileReadOnly()
            }
        }
        .visionListRowHitTarget()
        .onAppear {
            // After a failed page, only Retry asks again.
            if item.id == store.items.last?.id, store.loadMoreError == nil, !isRemoteReadOnly { Task { await store.loadMore() } }
        }
    }

    private func startWork(on item: PullRequestListItem, linkedWorkspace: Workspace?) {
        if let linkedWorkspace {
            onOpenAgent(linkedWorkspace.id)
        } else {
            onCreateWorkspace(item)
        }
    }

    @ViewBuilder private var placeholder: some View {
        Group {
            switch store.phase {
            case .idle, .loading, .failed where isRemoteReadOnly:
                if isRemoteReadOnly {
                    AvailableWhenReconnectedView()
                } else {
                    ProgressView {
                        Text("Loading pull requests...").interFont(Constants.Typography.bodyS)
                    }
                }
            case .disconnected:
                message("Connect GitHub on the computer running Intent to see pull requests.")
            case .failed(let error):
                VStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
                    message(error)
                    Button("Retry") { Task { await store.load(query) } }
                        .buttonStyle(IntentButtonStyle(variant: .muted))
                        .accessibilityIdentifier("pullRequests.retry")
                }
            case .ready:
                message(query.repositories.isEmpty
                    ? "Pull requests appear here once a workspace uses a GitHub repository."
                    : (query.text.isEmpty ? "No pull requests" : "No matching pull requests"))
            }
        }
        .frame(maxWidth: .infinity, minHeight: Constants.WorkspaceList.emptyStateHeight)
        .padding(.horizontal, Constants.WorkspaceList.pageInset)
        .accessibilityIdentifier("pullRequests.placeholder")
    }

    /// Inline error under rows that stay visible, with its own Retry.
    private func failureRow(_ error: String, retry: @escaping @MainActor () async -> Void) -> some View {
        VStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
            message(error)
            Button("Retry") { Task { await retry() } }
                .buttonStyle(IntentButtonStyle(variant: .muted))
                .accessibilityIdentifier("pullRequests.loadMore.retry")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Constants.WorkspaceRow.spaciousPadding)
        .padding(.horizontal, Constants.WorkspaceList.pageInset)
        .accessibilityIdentifier("pullRequests.loadMore.failure")
    }

    private func groupHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .interFont(Constants.Typography.eyebrow)
            .foregroundStyle(Constants.WorkspaceList.secondaryText(for: colorScheme, contrast: contrast))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Constants.WorkspaceList.groupTopSpacing)
            .padding(.horizontal, Constants.WorkspaceList.pageInset)
            .accessibilityAddTraits(.isHeader)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .interFont(Constants.Typography.bodyS)
            .foregroundStyle(Constants.WorkspaceList.secondaryText(for: colorScheme, contrast: contrast))
            .multilineTextAlignment(.center)
    }
}
