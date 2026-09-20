@testable import Intent
import SwiftUI
import Testing

@MainActor
struct WorkspaceRowLayoutPolicyTests {
    @Test func metadataReflowsOnlyAtAccessibilitySizes() {
        #expect(!WorkspaceRowView.usesExpandedMetadataLayout(for: .xxxLarge))
        #expect(WorkspaceRowView.usesExpandedMetadataLayout(for: .accessibility1))
        #expect(WorkspaceRowView.usesExpandedMetadataLayout(for: .accessibility5))
    }

    @Test func accessibilitySizesDoNotLimitLongTitles() {
        #expect(WorkspaceRowView.titleLineLimit(for: .xxxLarge) == 2)
        #expect(WorkspaceRowView.titleLineLimit(for: .accessibility1) == nil)
        #expect(WorkspaceRowView.titleLineLimit(for: .accessibility5) == nil)
    }

    @Test func additionalPullRequestCountHasReadableAccessibilityLabel() {
        #expect(WorkspaceRowView.additionalPullRequestsAccessibilityLabel(1)
            == "1 additional pull request")
        #expect(WorkspaceRowView.additionalPullRequestsAccessibilityLabel(3)
            == "3 additional pull requests")
        #expect(WorkspaceRowView.additionalPullRequestsAccessibilityLabel(100)
            == "100 additional pull requests")
    }
}
