import Foundation
import Testing
@testable import Intent

struct GitHubRepoSuggestionsTests {

    private func repo(_ owner: String, _ name: String) -> GitHubRepo {
        GitHubRepo(owner: owner, name: name, htmlUrl: nil, defaultBranch: nil, updatedAt: nil)
    }

    // MARK: - Prefix filtering

    @Test func emptyQueryKeepsAllReposInOrder() {
        let repos = [repo("intent-hq", "intentd"), repo("intent-hq", "ios"), repo("panghy", "tools")]
        #expect(GitHubRepoSuggestions.prefixFiltered(repos, query: "") == repos)
        #expect(GitHubRepoSuggestions.prefixFiltered(repos, query: "   ") == repos)
    }

    @Test func prefixFiltersCaseInsensitivelyOnNameAndFullName() {
        let repos = [repo("intent-hq", "intentd"), repo("intent-hq", "ios"), repo("panghy", "tools")]
        #expect(GitHubRepoSuggestions.prefixFiltered(repos, query: "IOS") == [repo("intent-hq", "ios")])
        #expect(GitHubRepoSuggestions.prefixFiltered(repos, query: "intent")
            == [repo("intent-hq", "intentd"), repo("intent-hq", "ios")])
        #expect(GitHubRepoSuggestions.prefixFiltered(repos, query: "PANGHY/") == [repo("panghy", "tools")])
        #expect(GitHubRepoSuggestions.prefixFiltered(repos, query: "nomatch").isEmpty)
    }

    @Test func prefixFilterDoesNotMatchMidStringSubstrings() {
        let repos = [repo("panghy", "tools")]
        #expect(GitHubRepoSuggestions.prefixFiltered(repos, query: "ools").isEmpty)
        #expect(GitHubRepoSuggestions.prefixFiltered(repos, query: "anghy").isEmpty)
    }

    @Test func trimsQueryBeforeFiltering() {
        let repos = [repo("intent-hq", "intentd")]
        #expect(GitHubRepoSuggestions.prefixFiltered(repos, query: "  intentd  ") == repos)
    }

    // MARK: - Merged sections

    @Test func mergedPinsRecentsAboveOwnReposDeduped() {
        let recents = [repo("intent-hq", "monorepo"), repo("intent-hq", "intentd")]
        let own = [repo("Intent-HQ", "IntentD"), repo("intent-hq", "ios")]
        let sections = GitHubRepoSuggestions.merged(
            recentRepos: recents,
            ownRepos: own,
            searchResults: [],
            searchQuery: nil,
            currentQuery: ""
        )
        #expect(sections.recents == recents)
        #expect(sections.others == [repo("intent-hq", "ios")])
    }

    @Test func mergedDropsDuplicatesWithinRecents() {
        // The registry is keyed by path, so two local clones of the same
        // repo yield two entries with the same owner/name.
        let recents = [repo("intent-hq", "intentd"), repo("Intent-HQ", "IntentD")]
        let sections = GitHubRepoSuggestions.merged(
            recentRepos: recents,
            ownRepos: [],
            searchResults: [],
            searchQuery: nil,
            currentQuery: ""
        )
        #expect(sections.recents == [repo("intent-hq", "intentd")])
    }

    @Test func mergedPrefixFiltersBothRecentsAndOwnRepos() {
        let recents = [repo("intent-hq", "intentd"), repo("panghy", "tools")]
        let own = [repo("intent-hq", "ios"), repo("other", "unrelated")]
        let sections = GitHubRepoSuggestions.merged(
            recentRepos: recents,
            ownRepos: own,
            searchResults: [],
            searchQuery: nil,
            currentQuery: "intent"
        )
        #expect(sections.recents == [repo("intent-hq", "intentd")])
        #expect(sections.others == [repo("intent-hq", "ios")])
    }

    @Test func mergedListsSearchResultsAfterOwnReposDedupedAgainstBoth() {
        let recents = [repo("intent-hq", "intentd")]
        let own = [repo("intent-hq", "ios")]
        let search = [repo("Intent-HQ", "IntentD"), repo("intent-hq", "IOS"), repo("other", "intentd")]
        let sections = GitHubRepoSuggestions.merged(
            recentRepos: recents,
            ownRepos: own,
            searchResults: search,
            searchQuery: "intent",
            currentQuery: "intent"
        )
        #expect(sections.recents == [repo("intent-hq", "intentd")])
        #expect(sections.others == [repo("intent-hq", "ios"), repo("other", "intentd")])
    }

    @Test func dropsDuplicatesWithinSearchResultsPreservingOrder() {
        let search = [repo("a", "xx"), repo("b", "yy"), repo("A", "XX"), repo("c", "zz")]
        let sections = GitHubRepoSuggestions.merged(
            recentRepos: [],
            ownRepos: [],
            searchResults: search,
            searchQuery: "xx",
            currentQuery: "xx"
        )
        #expect(sections.others == [repo("a", "xx"), repo("b", "yy"), repo("c", "zz")])
    }

    @Test func searchSurfacesOwnRepoHiddenByPrefixFilter() {
        // Dedupe runs against the *displayed* rows, so a repo the local
        // prefix filter hides can still come back via server-side search.
        let own = [repo("intent-hq", "intentd")]
        let search = [repo("intent-hq", "intentd")]
        let sections = GitHubRepoSuggestions.merged(
            recentRepos: [],
            ownRepos: own,
            searchResults: search,
            searchQuery: "hq",
            currentQuery: "hq"
        )
        #expect(sections.recents.isEmpty)
        #expect(sections.others == [repo("intent-hq", "intentd")])
    }

    @Test func excludesStaleSearchResults() {
        let sections = GitHubRepoSuggestions.merged(
            recentRepos: [],
            ownRepos: [repo("intent-hq", "intentd")],
            searchResults: [repo("other", "intentd")],
            searchQuery: "old-query",
            currentQuery: "intent"
        )
        #expect(sections.others == [repo("intent-hq", "intentd")])
    }

    @Test func excludesSearchResultsWhenNoSearchCompleted() {
        let sections = GitHubRepoSuggestions.merged(
            recentRepos: [],
            ownRepos: [repo("intent-hq", "intentd")],
            searchResults: [repo("other", "intentd")],
            searchQuery: nil,
            currentQuery: "intent"
        )
        #expect(sections.others == [repo("intent-hq", "intentd")])
    }

    @Test func emptyQueryShowsOnlyRecentsAndOwnRepos() {
        let recents = [repo("intent-hq", "monorepo")]
        let own = [repo("intent-hq", "intentd"), repo("intent-hq", "ios")]
        let sections = GitHubRepoSuggestions.merged(
            recentRepos: recents,
            ownRepos: own,
            searchResults: [repo("other", "intentd")],
            searchQuery: "",
            currentQuery: ""
        )
        #expect(sections.recents == recents)
        #expect(sections.others == own)
    }

    @Test func trimsCurrentQueryWhenMatchingSearchQuery() {
        let sections = GitHubRepoSuggestions.merged(
            recentRepos: [],
            ownRepos: [repo("intent-hq", "intentd")],
            searchResults: [repo("other", "intentd")],
            searchQuery: "intentd",
            currentQuery: "  intentd  "
        )
        #expect(sections.others == [repo("intent-hq", "intentd"), repo("other", "intentd")])
    }

    @Test func sectionsIsEmptyOnlyWhenBothSectionsAreEmpty() {
        #expect(GitHubRepoSuggestions.Sections().isEmpty)
        #expect(!GitHubRepoSuggestions.Sections(recents: [repo("a", "b")], others: []).isEmpty)
        #expect(!GitHubRepoSuggestions.Sections(recents: [], others: [repo("a", "b")]).isEmpty)
    }
}
