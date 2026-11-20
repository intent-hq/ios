@testable import Intent
import SwiftUI
import Testing

extension CreateWorkspaceParamsTests {
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

    @Test func orderedBranchesPinsDefaultFirstAndDedupes() {
        #expect(
            CreateWorkspaceView.orderedBranches(
                ["dev", "main", "feature/x"],
                defaultBranch: "main"
            ) == ["main", "dev", "feature/x"]
        )
    }

    @Test func orderedBranchesInsertsDefaultMissingFromPage() {
        #expect(
            CreateWorkspaceView.orderedBranches(
                ["a", "b"],
                defaultBranch: "main"
            ) == ["main", "a", "b"]
        )
    }

    @Test func orderedBranchesLeavesEmptyListEmpty() {
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
