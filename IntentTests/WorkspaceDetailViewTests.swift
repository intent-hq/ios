import Testing
@testable import Intent

struct WorkspaceDetailViewTests {
    @Test func progressCountsPreserveAllThreeProportions() throws {
        let progress = try #require(WorkspaceTaskProgressLayout(
            total: 10,
            completed: 4,
            inProgress: 3
        ))

        #expect(progress.completed == 4)
        #expect(progress.inProgress == 3)
        #expect(progress.remaining == 3)
    }

    @Test func invalidCountsCannotOverflowTotal() throws {
        let progress = try #require(WorkspaceTaskProgressLayout(
            total: 5,
            completed: 4,
            inProgress: 4
        ))

        #expect(progress.completed == 4)
        #expect(progress.inProgress == 1)
        #expect(progress.remaining == 0)
        #expect(progress.completed + progress.inProgress + progress.remaining == progress.total)
    }

    @Test func nonpositiveTotalHasNoLayout() {
        #expect(WorkspaceTaskProgressLayout(total: 0, completed: 0, inProgress: 0) == nil)
    }
}