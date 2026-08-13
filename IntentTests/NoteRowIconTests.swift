import Foundation
import Testing
@testable import Intent

struct NoteRowIconTests {
    private func makeNote(
        id: String,
        taskStatus: String? = nil,
        isDefault: Bool = false,
        content: String = ""
    ) -> Note {
        Note(
            id: id, title: "Note \(id)", content: content, tags: [],
            isDefault: isDefault, isArchived: false, taskStatus: taskStatus,
            parentId: nil, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"
        )
    }

    private func link(_ id: String) -> String {
        "- [ ] [Task \(id)](intent://local/task/\(id))"
    }

    // MARK: - Branch selection

    @Test func taskNoteGetsItsMetadataStatusIcon() {
        let note = makeNote(id: "t1", taskStatus: "in_progress")
        #expect(NoteRowIcon.kind(for: note, notes: []) == .taskStatus(.inProgress))
    }

    @Test func taskStatusWinsOverLinkedTasksInContent() {
        let linked = makeNote(id: "a", taskStatus: "complete")
        let note = makeNote(id: "t1", taskStatus: "blocked", content: link("a"))
        #expect(NoteRowIcon.kind(for: note, notes: [linked]) == .taskStatus(.blocked))
    }

    @Test func specWithoutLinkedTasksKeepsStarOnly() {
        let note = makeNote(id: "spec", isDefault: true, content: "# Plan\nNo tasks yet.")
        #expect(NoteRowIcon.kind(for: note, notes: []) == .star)
    }

    @Test func specWithLinkedTasksGetsStarWithRing() {
        let notes = [
            makeNote(id: "a", taskStatus: "complete"),
            makeNote(id: "b", taskStatus: "in_progress"),
            makeNote(id: "c", taskStatus: "not_started"),
        ]
        let spec = makeNote(id: "spec", isDefault: true, content: [link("a"), link("b"), link("c")].joined(separator: "\n"))
        let expected = TaskStats(total: 3, completed: 1, inProgress: 1)
        #expect(NoteRowIcon.kind(for: spec, notes: notes) == .starWithProgressRing(expected))
    }

    @Test func plainNoteWithLinkedTasksGetsProgressRing() {
        let notes = [
            makeNote(id: "a", taskStatus: "complete"),
            makeNote(id: "b", taskStatus: "review_required"),
        ]
        let note = makeNote(id: "n1", content: link("a") + "\n" + link("b"))
        let expected = TaskStats(total: 2, completed: 1, inProgress: 1)
        #expect(NoteRowIcon.kind(for: note, notes: notes) == .progressRing(expected))
    }

    @Test func plainNoteWithoutLinkedTasksGetsDocumentIcon() {
        let note = makeNote(id: "n1", content: "Some prose\n- [ ] plain checkbox, no task link")
        #expect(NoteRowIcon.kind(for: note, notes: []) == .document)
    }

    @Test func allCancelledLinksFallBackToDocumentIcon() {
        // Cancelled tasks are excluded from the total, so the ring has no
        // denominator and the note falls back to the doc icon.
        let notes = [makeNote(id: "a", taskStatus: "cancelled")]
        let note = makeNote(id: "n1", content: link("a"))
        #expect(NoteRowIcon.kind(for: note, notes: notes) == .document)
    }

    @Test func statsRecomputeAgainstUpdatedNoteList() {
        let note = makeNote(id: "n1", content: link("a"))
        let before = NoteRowIcon.kind(for: note, notes: [makeNote(id: "a", taskStatus: "not_started")])
        let after = NoteRowIcon.kind(for: note, notes: [makeNote(id: "a", taskStatus: "complete")])
        #expect(before == .progressRing(TaskStats(total: 1, completed: 0, inProgress: 0)))
        #expect(after == .progressRing(TaskStats(total: 1, completed: 1, inProgress: 0)))
    }
}
