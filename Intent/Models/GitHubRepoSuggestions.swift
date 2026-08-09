import Foundation

/// Pure suggestion assembly for the GitHub repo picker, mirroring the
/// desktop RepoSelector: the user's own repos filtered client-side by the
/// typed text, followed by global search results deduped against them.
enum GitHubRepoSuggestions {
    /// Global search only runs for trimmed queries at least this long
    /// (FE parity: github-repo-search saga's MIN_QUERY_LENGTH).
    static let minSearchQueryLength = 2

    /// Own repos filtered by a case-insensitive substring match against the
    /// `owner/name` form; an empty query keeps them all. Order is preserved.
    static func filteredOwnRepos(_ ownRepos: [GitHubRepo], query: String) -> [GitHubRepo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return ownRepos }
        return ownRepos.filter { $0.fullName.lowercased().contains(q) }
    }

    /// Search results with anything already in the own-repos list removed
    /// (case-insensitive `owner/name` identity) and internal duplicates
    /// dropped. Order is preserved.
    static func dedupedSearchResults(
        _ searchResults: [GitHubRepo],
        ownRepos: [GitHubRepo]
    ) -> [GitHubRepo] {
        var seen = Set(ownRepos.map { $0.id.lowercased() })
        var deduped: [GitHubRepo] = []
        for repo in searchResults where seen.insert(repo.id.lowercased()).inserted {
            deduped.append(repo)
        }
        return deduped
    }

    /// The combined suggestion list: filtered own repos first, then deduped
    /// global search results. Search results are included only when they
    /// answer the currently typed query (`searchQuery` is the trimmed query
    /// the results were fetched for), so stale in-flight results never
    /// surface — FE parity with the RepoSelector's last-query guard.
    static func merged(
        ownRepos: [GitHubRepo],
        searchResults: [GitHubRepo],
        searchQuery: String?,
        currentQuery: String
    ) -> [GitHubRepo] {
        let own = filteredOwnRepos(ownRepos, query: currentQuery)
        let current = currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let searchQuery, !current.isEmpty, searchQuery == current else { return own }
        return own + dedupedSearchResults(searchResults, ownRepos: ownRepos)
    }
}
