import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceTitleShimmerTests {
    private let createdAt = "1970-01-01T00:00:00Z"
    private let creation = Date(timeIntervalSince1970: 0)

    @Test(arguments: [(59.5, 0.5), (60.0, 0.0), (120.0, 0.0)])
    func expiresAtSixtySeconds(elapsed: TimeInterval, expected: TimeInterval) {
        let lifetime = WorkspaceTitleShimmerLifetime(createdAt: createdAt, firstShownAt: creation)

        #expect(lifetime.remaining(at: creation.addingTimeInterval(elapsed)) == expected)
    }

    @Test func openingAnotherScreenDoesNotRestartTheTimeout() {
        let later = creation.addingTimeInterval(45)
        let list = WorkspaceTitleShimmerLifetime(createdAt: createdAt, firstShownAt: creation)
        let heading = WorkspaceTitleShimmerLifetime(createdAt: createdAt, firstShownAt: later)

        #expect(list.deadline == heading.deadline)
        #expect(heading.remaining(at: later) == 15)
        #expect(heading.remaining(at: creation.addingTimeInterval(90)) == 0)
    }

    @Test func oldUnnamedWorkspaceIsAlreadyExpiredWhenOpened() {
        let later = creation.addingTimeInterval(300)
        let lifetime = WorkspaceTitleShimmerLifetime(createdAt: createdAt, firstShownAt: later)

        #expect(lifetime.remaining(at: later) == 0)
    }

    @Test(arguments: [nil, "", "invalid"])
    func missingOrInvalidCreationTimeUsesFirstAppearance(createdAt: String?) {
        let firstShown = creation.addingTimeInterval(120)
        let lifetime = WorkspaceTitleShimmerLifetime(createdAt: createdAt, firstShownAt: firstShown)

        #expect(lifetime.remaining(at: firstShown) == 60)
        #expect(lifetime.remaining(at: firstShown.addingTimeInterval(60)) == 0)
    }

    @Test func futureServerTimestampCannotExtendTheTimeout() {
        let lifetime = WorkspaceTitleShimmerLifetime(
            createdAt: "1970-01-02T00:00:00Z",
            firstShownAt: creation
        )

        #expect(lifetime.remaining(at: creation) == 60)
        #expect(lifetime.remaining(at: creation.addingTimeInterval(60)) == 0)
    }

    @Test func fractionalCreationTimestampKeepsItsPrecision() {
        let lifetime = WorkspaceTitleShimmerLifetime(
            createdAt: "1970-01-01T00:00:00.500Z",
            firstShownAt: creation.addingTimeInterval(10)
        )

        #expect(lifetime.remaining(at: creation.addingTimeInterval(60)) == 0.5)
    }
}
