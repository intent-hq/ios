import Foundation
import Testing
@testable import Intent

struct GitHubRepoSuggestionsTests {

    private func repo(_ owner: String, _ name: String) -> GitHubRepo {
        GitHubRepo(owner: owner, name: name, htmlUrl: nil, defaultBranch: nil, updatedAt: nil)
    }

    // MARK: - Own-repo filtering

    @Test func emptyQueryKeepsAllOwnReposInOrder() {
        let own = [repo("intent-hq", "intentd"), repo("intent-hq", "ios"), repo("panghy", "tools")]
        #expect(GitHubRepoSuggestions.filteredOwnRepos(own, query: "") == own)
        #expect(GitHubRepoSuggestions.filteredOwnRepos(own, query: "   ") == own)
    }

    @Test func filtersOwnReposCaseInsensitivelyAcrossOwnerSlashName() {
        let own = [repo("intent-hq", "intentd"), repo("intent-hq", "ios"), repo("panghy", "tools")]
        #expect(GitHubRepoSuggestions.filteredOwnRepos(own, query: "IOS") == [repo("intent-hq", "ios")])
        #expect(GitHubRepoSuggestions.filteredOwnRepos(own, query: "hq/int") == [repo("intent-hq", "intentd")])
        #expect(GitHubRepoSuggestions.filteredOwnRepos(own, query: "PANGHY") == [repo("panghy", "tools")])
        #expect(GitHubRepoSuggestions.filteredOwnRepos(own, query: "nomatch").isEmpty)
    }

    @Test func trimsQueryBeforeFiltering() {
        let own = [repo("intent-hq", "intentd")]
        #expect(GitHubRepoSuggestions.filteredOwnRepos(own, query: "  intentd  ") == own)
    }

    // MARK: - Search-result dedup

    @Test func dropsSearchResultsAlreadyOwned() {
        let own = [repo("intent-hq", "intentd")]
        let search = [repo("Intent-HQ", "IntentD"), repo("other", "intentd")]
        let deduped = GitHubRepoSuggestions.dedupedSearchResults(search, ownRepos: own)
        #expect(deduped == [repo("other", "intentd")])
    }

    @Test func dropsDuplicatesWithinSearchResultsPreservingOrder() {
        let search = [repo("a", "x"), repo("b", "y"), repo("A", "X"), repo("c", "z")]
        let deduped = GitHubRepoSuggestions.dedupedSearchResults(search, ownRepos: [])
        #expect(deduped == [repo("a", "x"), repo("b", "y"), repo("c", "z")])
    }

    // MARK: - Merged ordering

    @Test func mergedListsFilteredOwnReposBeforeSearchResults() {
        let own = [repo("intent-hq", "intentd"), repo("intent-hq", "ios")]
        let search = [repo("other", "intentd"), repo("intent-hq", "intentd")]
        let merged = GitHubRepoSuggestions.merged(
            ownRepos: own,
            searchResults: search,
            searchQuery: "intent",
            currentQuery: "intent"
        )
        #expect(merged == [
            repo("intent-hq", "intentd"),
            repo("intent-hq", "ios"),
            repo("other", "intentd")
        ])
    }

    @Test func excludesStaleSearchResults() {
        let own = [repo("intent-hq", "intentd")]
        let search = [repo("other", "intentd")]
        let merged = GitHubRepoSuggestions.merged(
            ownRepos: own,
            searchResults: search,
            searchQuery: "old-query",
            currentQuery: "intent"
        )
        #expect(merged == [repo("intent-hq", "intentd")])
    }

    @Test func excludesSearchResultsWhenNoSearchCompleted() {
        let search = [repo("other", "intentd")]
        let merged = GitHubRepoSuggestions.merged(
            ownRepos: [repo("intent-hq", "intentd")],
            searchResults: search,
            searchQuery: nil,
            currentQuery: "intent"
        )
        #expect(merged == [repo("intent-hq", "intentd")])
    }

    @Test func emptyQueryShowsOnlyOwnRepos() {
        let own = [repo("intent-hq", "intentd"), repo("intent-hq", "ios")]
        let merged = GitHubRepoSuggestions.merged(
            ownRepos: own,
            searchResults: [repo("other", "intentd")],
            searchQuery: "",
            currentQuery: ""
        )
        #expect(merged == own)
    }

    @Test func trimsCurrentQueryWhenMatchingSearchQuery() {
        let own = [repo("intent-hq", "intentd")]
        let search = [repo("other", "intentd")]
        let merged = GitHubRepoSuggestions.merged(
            ownRepos: own,
            searchResults: search,
            searchQuery: "intentd",
            currentQuery: "  intentd  "
        )
        #expect(merged == [repo("intent-hq", "intentd"), repo("other", "intentd")])
    }
}
