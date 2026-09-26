import SwiftUI

/// Searchable GitHub repo picker (Create Workspace Step 1): recent repos
/// from the daemon's known-repo registry render immediately on top (no
/// GitHub round-trip), the first page of the user's GitHub repos blends in
/// below, both prefix-filtered client-side by the typed text, followed by
/// deduped debounced global search results. When GitHub is not connected
/// (`github.authStatus.isConfigured == false`) the screen shows
/// desktop-setup guidance instead — there is no fallback flow, so recents
/// are deliberately auth-gated at render time too: picking a repo needs
/// GitHub for branch listing and workspace creation either way.
///
/// `store` is the session-owned cache: on a reopen the cached lists render
/// immediately (no spinner) while `loadIfNeeded` revalidates silently.
/// Search state stays per-picker (the store is shared by every picker on
/// the session, so one picker's search must not surface in another).
struct GitHubRepoPickerView: View {
    var store: GitHubRepoStore
    @Binding var selectedRepo: GitHubRepo?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var searchText = ""
    @State private var searchResults: [GitHubRepo] = []
    /// The trimmed query the current `searchResults` answer; nil until a
    /// search completes, so stale results never surface.
    @State private var completedSearchQuery: String?
    /// The qualifying query currently in its debounce or remote-search phase.
    @State private var pendingSearchQuery: String?
    @State private var searchTask: Task<Void, Never>?

    private var suggestions: GitHubRepoSuggestions.Sections {
        GitHubRepoSuggestions.merged(
            recentRepos: store.recentRepos,
            ownRepos: store.ownRepos,
            searchResults: searchResults,
            searchQuery: completedSearchQuery,
            currentQuery: searchText
        )
    }

    var body: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()

            if !store.hasCheckedAuth {
                if store.lastError != nil {
                    // The cold auth read itself failed: surface the error
                    // rather than not-connected guidance or an endless spinner.
                    emptyState
                } else {
                    ProgressView {
                        Text("Checking GitHub connection...").interFont(Constants.Typography.bodyS)
                    }
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                }
            } else if !store.isConfigured {
                notConnectedPlaceholder
            } else {
                repoList
            }
        }
        .task {
            await store.loadIfNeeded()
        }
        .onChange(of: searchText) { _, newValue in
            scheduleSearch(for: newValue)
        }
    }

    // MARK: - Subviews

    private var repoList: some View {
        Group {
            if store.isLoading || pendingSearchQuery != nil, suggestions.isEmpty {
                ProgressView {
                    Text("Loading repositories...").interFont(Constants.Typography.bodyS)
                }
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            } else if suggestions.isEmpty {
                emptyState
            } else {
                List {
                    if !suggestions.recents.isEmpty {
                        Section {
                            ForEach(suggestions.recents) { repo in
                                repoRow(repo)
                            }
                        } header: {
                            Text("Recent").interFont(Constants.Typography.eyebrow)
                        }
                    }
                    if !suggestions.others.isEmpty {
                        Section {
                            ForEach(suggestions.others) { repo in
                                repoRow(repo)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search GitHub repositories"
        )
    }

    private func repoRow(_ repo: GitHubRepo) -> some View {
        Button {
            selectedRepo = repo
        } label: {
            HStack(spacing: Constants.GitHubRepoPicker.rowSpacing) {
                RepoOwnerAvatarView(owner: repo.owner)
                VStack(alignment: .leading, spacing: Constants.GitHubRepoPicker.rowTextSpacing) {
                    Text(repo.name)
                        .interFont(Constants.Typography.bodyM.withFace(.semibold))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : Constants.GitHubRepoPicker.repositoryNameLineLimit)
                    Text(repo.fullName)
                        .interFont(Constants.Typography.bodyXS)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .truncationMode(.middle)
                }
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                Spacer()
                if selectedRepo?.id == repo.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.primary(for: colorScheme))
                        .bold()
                        .accessibilityLabel("Selected")
                }
            }
            .padding(.vertical, Constants.GitHubRepoPicker.rowVerticalPadding)
        }
        .accessibilityAddTraits(selectedRepo?.id == repo.id ? .isSelected : [])
        .listRowBackground(Theme.card(for: colorScheme))
    }

    @ViewBuilder
    private var emptyState: some View {
        if let lastError = store.lastError {
            ContentUnavailableView {
                Label {
                    Text("Repositories Unavailable").interFont(Constants.Typography.bodyM.withFace(.semibold))
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                Text(lastError).interFont(Constants.Typography.bodyS)
            }
        } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search
        } else {
            ContentUnavailableView {
                Label {
                    Text("No Repositories").interFont(Constants.Typography.bodyM.withFace(.semibold))
                } icon: {
                    Image(systemName: "folder.badge.questionmark")
                }
            } description: {
                Text("No GitHub repositories are available for your account.").interFont(Constants.Typography.bodyS)
            }
        }
    }

    /// Guidance shown when GitHub is not connected; the GitHub connect flow
    /// runs on the desktop seat and is not available on iOS (same pattern as
    /// the "no providers signed in" placeholder).
    private var notConnectedPlaceholder: some View {
        ContentUnavailableView {
            Label {
                Text("GitHub Is Not Connected").interFont(Constants.Typography.bodyM.withFace(.semibold))
            } icon: {
                Image(systemName: "person.crop.circle.badge.xmark")
            }
        } description: {
            Text("Connect GitHub in the Intent desktop app, then come back and try again.")
                .interFont(Constants.Typography.bodyS)
        }
    }

    // MARK: - Debounced search

    /// Debounce global search ~300ms so rapid keystrokes coalesce into a
    /// single request (FE parity). Queries shorter than the minimum clear
    /// any previous results instead of searching.
    private func scheduleSearch(for text: String) {
        searchTask?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= GitHubRepoSuggestions.minSearchQueryLength else {
            pendingSearchQuery = nil
            completedSearchQuery = nil
            searchResults = []
            return
        }
        pendingSearchQuery = query
        searchTask = Task {
            try? await Task.sleep(for: Constants.GitHubRepoPicker.searchDebounce)
            guard !Task.isCancelled, pendingSearchQuery == query else { return }
            let results = await store.searchRepos(query: query)
            // Publish results + the query they answer together, only if this
            // task is still the latest — an out-of-order older response can't
            // overwrite a newer one's results.
            guard !Task.isCancelled, pendingSearchQuery == query else { return }
            if case let .results(results) = results {
                searchResults = results
                completedSearchQuery = query
            }
            pendingSearchQuery = nil
        }
    }
}
