import Testing
@testable import Intent

/// Tests for the task-note metadata header's pure helpers: reverse dependency
/// edge derivation and unmet-dependency highlight suppression (fe
/// `NoteMetadataBar.svelte` parity).
struct TaskMetadataHeaderTests {
    private func makeNote(
        id: String,
        taskStatus: String? = nil,
        dependsOn: [String] = [],
        unmetDependsOn: [String] = []
    ) -> Note {
        Note(
            id: id, title: "Note \(id)", content: "", tags: [],
            isDefault: false, isArchived: false, taskStatus: taskStatus,
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
}
