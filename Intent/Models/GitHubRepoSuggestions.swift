import Foundation

enum GitHubRepoSuggestions {
    static let minSearchQueryLength = 2

    struct Sections: Equatable {
        var recents: [GitHubRepo] = []
        var others: [GitHubRepo] = []

        var isEmpty: Bool { recents.isEmpty && others.isEmpty }
    }

    static func prefixFiltered(_ repos: [GitHubRepo], query: String) -> [GitHubRepo] {
        let queryPrefix = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !queryPrefix.isEmpty else { return repos }
        return repos.filter { repo in
            repo.fullName.lowercased().hasPrefix(queryPrefix)
                || repo.name.lowercased().hasPrefix(queryPrefix)
        }
    }

    private static func deduped(_ repos: [GitHubRepo], seen: inout Set<String>) -> [GitHubRepo] {
        var deduped: [GitHubRepo] = []
        for repo in repos where seen.insert(repo.id.lowercased()).inserted {
            deduped.append(repo)
        }
        return deduped
    }

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
