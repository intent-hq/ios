import SwiftUI

/// Searchable GitHub repo picker (Create Workspace Step 1): recent repos
/// from the daemon's known-repo registry render immediately on top (no
/// GitHub round-trip), the first page of the user's GitHub repos blends in
/// below, both prefix-filtered client-side by the typed text, followed by
/// deduped debounced global search results. When GitHub is not connected
/// (`github.authStatus.isConfigured == false`) the screen shows
/// desktop-setup guidance instead — there is no fallback flow.
struct GitHubRepoPickerView: View {
    @ObservedObject var store: GitHubRepoStore
    @Binding var selectedRepo: GitHubRepo?

    @Environment(\.colorScheme) private var colorScheme

    @State private var searchText = ""
    /// The trimmed query the current `store.searchResults` answer; nil until
    /// a search completes, so stale results never surface.
    @State private var completedSearchQuery: String?
    @State private var searchTask: Task<Void, Never>?
    /// False until the first `github.authStatus` read completes, so the
    /// not-connected guidance doesn't flash while the status is unknown.
    @State private var authChecked = false

    private var suggestions: GitHubRepoSuggestions.Sections {
        GitHubRepoSuggestions.merged(
            recentRepos: store.recentRepos,
            ownRepos: store.ownRepos,
            searchResults: store.searchResults,
            searchQuery: completedSearchQuery,
            currentQuery: searchText
        )
    }

    var body: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()

            if !authChecked {
                ProgressView("Checking GitHub connection...")
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            } else if !store.isConfigured {
                notConnectedPlaceholder
            } else {
                repoList
            }
        }
        .task {
            // Recents come from the daemon registry (no GitHub round-trip),
            // so fetch them concurrently with the auth-gated GitHub list —
            // they render as soon as they arrive.
            async let recents: Void = store.fetchRecentRepos()
            let configured = await store.fetchAuthStatus()
            authChecked = true
            if configured {
                await store.fetchOwnRepos()
            }
            await recents
        }
        .onChange(of: searchText) { _, newValue in
            scheduleSearch(for: newValue)
        }
    }

    // MARK: - Subviews

    private var repoList: some View {
        Group {
            if store.isLoading && suggestions.isEmpty {
                ProgressView("Loading repositories...")
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            } else if suggestions.isEmpty {
                emptyState
            } else {
                List {
                    if !suggestions.recents.isEmpty {
                        Section("Recent") {
                            ForEach(suggestions.recents) { repo in
                                repoRow(repo)
                            }
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
            HStack(spacing: 12) {
                RepoOwnerAvatarView(owner: repo.owner)
                VStack(alignment: .leading, spacing: 4) {
                    Text(repo.name)
                        .font(.headline)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                    Text(repo.fullName)
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .lineLimit(1)
                }
                Spacer()
                if selectedRepo?.id == repo.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.primary(for: colorScheme))
                        .fontWeight(.semibold)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Theme.card(for: colorScheme))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Text("No repositories found")
                .font(.headline)
                .foregroundStyle(Theme.foreground(for: colorScheme))
            Text(store.lastError
                ?? (searchText.isEmpty
                    ? "No GitHub repositories are available for your account."
                    : "Try a different search."))
                .font(.subheadline)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    /// Guidance shown when GitHub is not connected; the GitHub connect flow
    /// runs on the desktop seat and is not available on iOS (same pattern as
    /// the "no providers signed in" placeholder).
    private var notConnectedPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.largeTitle)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Text("GitHub is not connected")
                .font(.headline)
                .foregroundStyle(Theme.foreground(for: colorScheme))
            Text("Connect GitHub in the Intent desktop app, then come back and try again.")
                .font(.subheadline)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
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
            completedSearchQuery = nil
            store.searchResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            guard let results = await store.searchRepos(query: query) else { return }
            // Publish results + the query they answer together, only if this
            // task is still the latest — an out-of-order older response can't
            // overwrite a newer one's results.
            guard !Task.isCancelled else { return }
            store.searchResults = results
            completedSearchQuery = query
        }
    }
}
