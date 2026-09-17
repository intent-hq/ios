import Foundation

/// Pure suggestion assembly for the GitHub repo picker: recent repos (the
/// daemon's known-repo registry, MRU-first) pinned on top, the first page of
/// the user's GitHub repos below them, both prefix-filtered by the typed
/// text, followed by global search results deduped against everything shown.
enum GitHubRepoSuggestions {
    /// Global search only runs for trimmed queries at least this long
    /// (FE parity: github-repo-search saga's MIN_QUERY_LENGTH).
    static let minSearchQueryLength = 2

    /// The assembled picker sections: `recents` renders under a "Recent"
    /// header on top, `others` (own repos + search results) below.
    struct Sections: Equatable {
        var recents: [GitHubRepo] = []
        var others: [GitHubRepo] = []

        var isEmpty: Bool { recents.isEmpty && others.isEmpty }
    }

    /// Repos filtered by a case-insensitive prefix match against either the
    /// `owner/name` form or the bare repo name (so typing "intentd" matches
    /// "intent-hq/intentd"); an empty query keeps them all. Order is
    /// preserved.
    static func prefixFiltered(_ repos: [GitHubRepo], query: String) -> [GitHubRepo] {
        let queryPrefix = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !queryPrefix.isEmpty else { return repos }
        return repos.filter { repo in
            repo.fullName.lowercased().hasPrefix(queryPrefix)
                || repo.name.lowercased().hasPrefix(queryPrefix)
        }
    }

    /// Repos not already in `seen` (case-insensitive `owner/name` identity),
    /// order preserved; kept repos are added to `seen`.
    private static func deduped(_ repos: [GitHubRepo], seen: inout Set<String>) -> [GitHubRepo] {
        var deduped: [GitHubRepo] = []
        for repo in repos where seen.insert(repo.id.lowercased()).inserted {
            deduped.append(repo)
        }
        return deduped
    }

    /// The combined suggestion sections: prefix-filtered recents first, then
    /// prefix-filtered own repos deduped against them (recents win), then
    /// deduped global search results. Search results are included only when
    /// they answer the currently typed query (`searchQuery` is the trimmed
    /// query the results were fetched for), so stale in-flight results never
    /// surface — FE parity with the RepoSelector's last-query guard.
    static func merged(
        recentRepos: [GitHubRepo],
        ownRepos: [GitHubRepo],
        searchResults: [GitHubRepo],
        searchQuery: String?,
        currentQuery: String
    ) -> Sections {
        var seen = Set<String>()
        let recents = deduped(prefixFiltered(recentRepos, query: currentQuery), seen: &seen)
        var others = deduped(prefixFiltered(ownRepos, query: currentQuery), seen: &seen)
        let current = currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if let searchQuery, !current.isEmpty, searchQuery == current {
            others += deduped(searchResults, seen: &seen)
        }
        return Sections(recents: recents, others: others)
    }
}
