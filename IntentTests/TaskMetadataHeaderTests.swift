import Foundation
import Testing
@testable import Intent

/// Tests for the task-note metadata header's pure helpers: reverse dependency
/// edge derivation, unmet-dependency highlight suppression, and assignee
/// dedup/ordering (fe `NoteMetadataBar.svelte` parity).
struct TaskMetadataHeaderTests {
    private func makeNote(
        id: String,
        taskStatus: String? = nil,
        isArchived: Bool = false,
        dependsOn: [String] = [],
        unmetDependsOn: [String] = []
    ) -> Note {
        Note(
            id: id, title: "Note \(id)", content: "", tags: [],
            isDefault: false, isArchived: isArchived, taskStatus: taskStatus,
            parentId: nil, createdAt: "", updatedAt: "",
            dependsOn: dependsOn, unmetDependsOn: unmetDependsOn
        )
    }

    // MARK: - dependedOnBy derivation

    @Test func dependedOnByFindsReverseEdges() {
        let notes = [
            makeNote(id: "target", taskStatus: "in_progress"),
            makeNote(id: "b", taskStatus: "not_started", dependsOn: ["target"]),
            makeNote(id: "a", taskStatus: "not_started", dependsOn: ["target", "other"]),
            makeNote(id: "c", taskStatus: "not_started", dependsOn: ["other"]),
            makeNote(id: "plain"),
        ]
        // Sorted by id for stable order, matching the fe derivation.
        #expect(TaskMetadataHeaderView.dependedOnBy(noteId: "target", in: notes) == ["a", "b"])
    }

    @Test func dependedOnByExcludesArchivedNotes() {
        let notes = [
            makeNote(id: "target", taskStatus: "in_progress"),
            makeNote(id: "live", taskStatus: "not_started", dependsOn: ["target"]),
            makeNote(
                id: "archived", taskStatus: "not_started", isArchived: true,
                dependsOn: ["target"]),
        ]
        #expect(TaskMetadataHeaderView.dependedOnBy(noteId: "target", in: notes) == ["live"])
    }

    @Test func dependedOnByExcludesSelfEdge() {
        let notes = [
            makeNote(id: "target", taskStatus: "in_progress", dependsOn: ["target"])
        ]
        #expect(TaskMetadataHeaderView.dependedOnBy(noteId: "target", in: notes) == [])
    }

    @Test func dependedOnByEmptyWhenNoEdges() {
        let notes = [
            makeNote(id: "target", taskStatus: "in_progress"),
            makeNote(id: "a", taskStatus: "not_started"),
        ]
        #expect(TaskMetadataHeaderView.dependedOnBy(noteId: "target", in: notes) == [])
    }

    // MARK: - Unmet-dependency highlight

    @Test func unmetHighlightShownForUnmetDep() {
        let note = makeNote(
            id: "t", taskStatus: "in_progress",
            dependsOn: ["a", "b"], unmetDependsOn: ["b"])
        #expect(TaskMetadataHeaderView.showsUnmetDependency("b", note: note) == true)
        #expect(TaskMetadataHeaderView.showsUnmetDependency("a", note: note) == false)
    }

    @Test func unmetHighlightSuppressedWhenComplete() {
        let note = makeNote(
            id: "t", taskStatus: "complete",
            dependsOn: ["a", "b"], unmetDependsOn: ["b"])
        #expect(TaskMetadataHeaderView.showsUnmetDependency("b", note: note) == false)
    }

    // MARK: - Assignee dedup and ordering

    @Test func sortedAssigneeIdsDedupsAndSortsByCreation() {
        let created: [String: Date] = [
            "newer": Date(timeIntervalSince1970: 200),
            "older": Date(timeIntervalSince1970: 100),
        ]
        let result = TaskMetadataHeaderView.sortedAssigneeIds(
            ["newer", "older", "newer"], createdAt: { created[$0] })
        #expect(result == ["older", "newer"])
    }

    @Test func sortedAssigneeIdsUnresolvedSortLastInWireOrder() {
        let created: [String: Date] = ["known": Date(timeIntervalSince1970: 100)]
        let result = TaskMetadataHeaderView.sortedAssigneeIds(
            ["mystery-b", "known", "mystery-a"], createdAt: { created[$0] })
        #expect(result == ["known", "mystery-b", "mystery-a"])
    }
}
