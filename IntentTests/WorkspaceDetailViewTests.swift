import CoreGraphics
import Foundation
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

    @Test func overflowingCountsAreClampedToTotal() throws {
        let progress = try #require(WorkspaceTaskProgressLayout(
            total: 5,
            completed: 4,
            inProgress: 4
        ))

        #expect(progress.completed == 4)
        #expect(progress.inProgress == 1)
        #expect(progress.remaining == 0)
    }

    @Test func negativeCountsAreClampedToZero() throws {
        let progress = try #require(WorkspaceTaskProgressLayout(
            total: 5,
            completed: -2,
            inProgress: -3
        ))

        #expect(progress.completed == 0)
        #expect(progress.inProgress == 0)
        #expect(progress.remaining == 5)
    }

    @Test func nonpositiveTotalHasNoLayout() {
        #expect(WorkspaceTaskProgressLayout(total: 0, completed: 0, inProgress: 0) == nil)
        #expect(WorkspaceTaskProgressLayout(total: -1, completed: 0, inProgress: 0) == nil)
    }

    @Test func visibleSegmentCountIncludesOnlyPositiveSegments() throws {
        let threeSegments = try #require(WorkspaceTaskProgressLayout(
            total: 10, completed: 4, inProgress: 3))
        let twoSegments = try #require(WorkspaceTaskProgressLayout(
            total: 10, completed: 4, inProgress: 6))
        let oneSegment = try #require(WorkspaceTaskProgressLayout(
            total: 10, completed: 10, inProgress: 0))

        #expect(threeSegments.visibleSegmentCount == 3)
        #expect(twoSegments.visibleSegmentCount == 2)
        #expect(oneSegment.visibleSegmentCount == 1)
    }

    @Test func visibleSegmentsAndSpacingUseTheMeasuredWidth() throws {
        let measuredWidth: CGFloat = 320
        let spacing: CGFloat = 4
        let inputs = [
            (total: 10, completed: 4, inProgress: 3),
            (total: 10, completed: 4, inProgress: 6),
            (total: 10, completed: 0, inProgress: 3),
            (total: 10, completed: 10, inProgress: 0),
        ]

        for input in inputs {
            let progress = try #require(WorkspaceTaskProgressLayout(
                total: input.total,
                completed: input.completed,
                inProgress: input.inProgress
            ))
            let counts = [progress.completed, progress.inProgress, progress.remaining]
                .filter { $0 > 0 }
            let segmentsWidth = counts.reduce(CGFloat.zero) { width, count in
                width + progress.segmentWidth(
                    for: count,
                    in: measuredWidth,
                    spacing: spacing)
            }
            let totalSpacing = spacing * CGFloat(progress.visibleSegmentCount - 1)

            #expect(abs(segmentsWidth + totalSpacing - measuredWidth) < 0.001)
        }
    }

    @Test func segmentWidthsAreZeroWhenSpacingExceedsMeasuredWidth() throws {
        let progress = try #require(WorkspaceTaskProgressLayout(
            total: 10, completed: 4, inProgress: 3))

        for count in [progress.completed, progress.inProgress, progress.remaining] {
            #expect(progress.segmentWidth(for: count, in: 1, spacing: 4) == 0)
        }
    }

    // MARK: - Session store routing (multi-window state split)

    /// A pinned session composed over a fake backend connection; the
    /// coordinator factory is never invoked by these tests.
    @MainActor
    private func makePinnedSession(connection: FakeConnectionManager) -> BackendSession {
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        return BackendSession(
            kind: .pinned(BackendID(UUID())),
            connection: connection,
            workspaceStore: WorkspaceStore(forTesting: true),
            coordinatorFactory: { _ in fatalError("coordinator is not built in these tests") },
            prMonitorsStore: WorkspacePrMonitorsStore(connectionManager: connection),
            attachmentUploadService: AttachmentUploadService(connection: connection),
            workspaceFileImageLoader: fileLoader,
            attachmentImageLoader: AttachmentImageLoader(
                connection: connection, fileLoader: fileLoader),
            attentionCueCenter: WorkspaceAttentionCueCenter(playSound: {}))
    }

    /// A pinned window's workspace detail must fetch/observe agents and
    /// notes over its own session's backend, never the default one.
    @MainActor
    @Test func workspaceDetailStoresRouteOverTheSessionConnection() {
        let fake = FakeConnectionManager()
        let view = WorkspaceDetailView(
            workspaceId: "ws-1", session: makePinnedSession(connection: fake))

        #expect(view.agentStore.connectionManager === fake)
        #expect(view.noteStore.connectionManager === fake)
        #expect(view.agentStore.connectionManager !== ConnectionManager.shared)
        #expect(view.noteStore.connectionManager !== ConnectionManager.shared)
    }

    /// Same contract for the note detail: its note/agent stores are bound
    /// to the session that opened the note.
    @MainActor
    @Test func noteDetailStoresRouteOverTheSessionConnection() {
        let fake = FakeConnectionManager()
        let view = NoteDetailView(
            noteId: "n-1", workspaceId: "ws-1", noteTitle: "Note",
            session: makePinnedSession(connection: fake))

        #expect(view.noteStore.connectionManager === fake)
        #expect(view.agentStore.connectionManager === fake)
        #expect(view.noteStore.connectionManager !== ConnectionManager.shared)
        #expect(view.agentStore.connectionManager !== ConnectionManager.shared)
    }
}