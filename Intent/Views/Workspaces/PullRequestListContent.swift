import SwiftUI

/// Pull request rows for the workspace list page. A changed query reloads
/// (search text debounced); an unchanged query keeps the cached rows when
/// switching back from workspaces.
struct PullRequestListContent: View {
    let store: PullRequestListStore
    let query: PullRequestListStore.Query
    let workspaces: [Workspace]
    let onOpenWorkspace: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.openURL) private var openURL

    var body: some View {
        let links = PullRequestListItem.linkedWorkspaces(workspaces)
        let showsRepository = query.repositories.count != 1
        Group {
            if store.items.isEmpty {
                placeholder
            } else {
                ForEach(store.items) { item in
                    row(item, linkedWorkspace: links[item.id], showsRepository: showsRepository)
                }
                if store.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Constants.WorkspaceRow.spaciousPadding)
                }
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
        Button {
            if let linkedWorkspace {
                onOpenWorkspace(linkedWorkspace.id)
            } else if let url = item.url {
                openURL(url)
            }
        } label: {
            PullRequestRowView(item: item, showsRepository: showsRepository, linkedWorkspace: linkedWorkspace)
        }
        .buttonStyle(IntentContentButtonStyle())
        .padding(.horizontal, Constants.WorkspaceList.pageInset)
        .overlay(alignment: .bottom) {
            Divider().padding(.horizontal, Constants.WorkspaceList.pageInset)
        }
        .contextMenu {
            if let url = item.url {
                Button("Open on GitHub", systemImage: "safari") { openURL(url) }
                ShareLink(item: url)
            }
            if let linkedWorkspace {
                Button("Open workspace", systemImage: "arrow.right.circle") { onOpenWorkspace(linkedWorkspace.id) }
            }
        }
        .visionListRowHitTarget()
        .onAppear {
            if item.id == store.items.last?.id { Task { await store.loadMore() } }
        }
        .accessibilityIdentifier("pullRequests.row.\(item.id)")
    }

    @ViewBuilder private var placeholder: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                ProgressView {
                    Text("Loading pull requests...").interFont(Constants.Typography.bodyS)
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

    private func message(_ text: String) -> some View {
        Text(text)
            .interFont(Constants.Typography.bodyS)
            .foregroundStyle(Constants.WorkspaceList.secondaryText(for: colorScheme, contrast: contrast))
            .multilineTextAlignment(.center)
    }
}
