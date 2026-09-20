@testable import Intent
import SwiftUI
import Testing

extension CreateWorkspaceParamsTests {
    // MARK: - preselectedBranch

    @Test func preselectedBranchKeepsStillValidSelection() {
        #expect(
            CreateWorkspaceView.preselectedBranch(
                current: "dev",
                branches: ["main", "dev"],
                defaultBranch: "main"
            ) == "dev"
        )
    }

    @Test func preselectedBranchPrefersDefaultWhenSelectionInvalid() {
        #expect(
            CreateWorkspaceView.preselectedBranch(
                current: nil,
                branches: ["dev", "main"],
                defaultBranch: "main"
            ) == "main"
        )
        // A stale selection from a previously picked repo is dropped
        #expect(
            CreateWorkspaceView.preselectedBranch(
                current: "feature/x",
                branches: ["dev", "main"],
                defaultBranch: "main"
            ) == "main"
        )
    }

    @Test func preselectedBranchFallsBackToFirstBranch() {
        #expect(
            CreateWorkspaceView.preselectedBranch(
                current: nil,
                branches: ["dev", "main"],
                defaultBranch: nil
            ) == "dev"
        )
        #expect(
            CreateWorkspaceView.preselectedBranch(
                current: nil,
                branches: [],
                defaultBranch: "main"
            ) == nil
        )
    }

    // MARK: - orderedBranches (default pinned first)

    @Test func orderedBranchesPinsDefaultFirstAndDedupes() {
        #expect(
            CreateWorkspaceView.orderedBranches(
                ["dev", "main", "feature/x"],
                defaultBranch: "main"
            ) == ["main", "dev", "feature/x"]
        )
    }

    @Test func orderedBranchesInsertsDefaultMissingFromPage() {
        // "main" can fall outside the fetched page (alphabetical 50-branch
        // cap); it is still pinned first so it stays visible and selectable.
        #expect(
            CreateWorkspaceView.orderedBranches(
                ["a", "b"],
                defaultBranch: "main"
            ) == ["main", "a", "b"]
        )
    }

    @Test func orderedBranchesLeavesEmptyListEmpty() {
        // An empty repo can still report a default_branch in metadata; no
        // nonexistent ref is fabricated for it.
        #expect(
            CreateWorkspaceView.orderedBranches(
                [],
                defaultBranch: "main"
            ).isEmpty
        )
    }

    @Test func orderedBranchesWithoutDefaultLeavesOrderUnchanged() {
        #expect(
            CreateWorkspaceView.orderedBranches(
                ["b", "a"],
                defaultBranch: nil
            ) == ["b", "a"]
        )
        #expect(
            CreateWorkspaceView.orderedBranches(
                ["b", "a"],
                defaultBranch: ""
            ) == ["b", "a"]
        )
    }

    // MARK: - displayedBranches

    @Test func displayedBranchesEmptyQueryShowsDefaultFirst() {
        #expect(
            CreateWorkspaceView.displayedBranches(
                loaded: ["dev", "main"],
                defaultBranch: "main",
                query: "  ",
                searchResults: ["ignored"],
                completedQuery: nil
            ) == ["main", "dev"]
        )
    }

    @Test func displayedBranchesUsesServerResultsWhenQueryAnswered() {
        #expect(
            CreateWorkspaceView.displayedBranches(
                loaded: ["main", "dev"],
                defaultBranch: "main",
                query: "feature/",
                searchResults: ["feature/x", "feature/y"],
                completedQuery: "feature/"
            ) == ["feature/x", "feature/y"]
        )
    }

    @Test func displayedBranchesFiltersLoadedPageWhileSearchInFlight() {
        // Stale results (answering an older query) are never shown; the
        // loaded page is locally prefix-filtered as an interim instead.
        #expect(
            CreateWorkspaceView.displayedBranches(
                loaded: ["main", "dev", "develop"],
                defaultBranch: "main",
                query: "dev",
                searchResults: ["feature/x"],
                completedQuery: "feature/"
            ) == ["dev", "develop"]
        )
    }

    @Test func displayedBranchesInterimIncludesOutOfPageDefault() {
        // The interim source is the pinned ordering, so a prefix of an
        // out-of-page default branch matches while the search is in flight
        // (and if the server search fails).
        #expect(
            CreateWorkspaceView.displayedBranches(
                loaded: ["a", "b"],
                defaultBranch: "main",
                query: "ma",
                searchResults: [],
                completedQuery: nil
            ) == ["main"]
        )
    }

    @Test func displayedBranchesLocallyFiltersServerResults() {
        // Graceful fallback: a daemon that ignores `prefix` returns the
        // unfiltered page, so the local prefix filter applies on top.
        #expect(
            CreateWorkspaceView.displayedBranches(
                loaded: [],
                defaultBranch: nil,
                query: "dev",
                searchResults: ["main", "dev"],
                completedQuery: "dev"
            ) == ["dev"]
        )
    }
}
