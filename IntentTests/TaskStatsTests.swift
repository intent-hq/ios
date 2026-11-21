import Foundation
@testable import Intent
import Testing

struct TaskStatsTests {
    private func makeNote(id: String, taskStatus: String?) -> Note {
        Note(
            id: id,
            title: "Task \(id)",
            content: "",
            tags: [],
            isDefault: false,
            isArchived: false,
            taskStatus: taskStatus,
            parentId: "spec",
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z"
        )
    }

    private func link(_ title: String, _ id: String) -> String {
        "- [ ] [\(title)](intent://local/task/\(id))"
    }

    // MARK: - parseTaskStats

    @Test func emptyAndNilContentReturnZeros() {
        #expect(TaskContentParser.parseTaskStats(content: nil, notes: []) == TaskStats(total: 0, completed: 0, inProgress: 0))
        #expect(TaskContentParser.parseTaskStats(content: "", notes: []) == TaskStats(total: 0, completed: 0, inProgress: 0))
    }

    @Test func classifiesEachStatusClass() {
        let notes = [
            makeNote(id: "a", taskStatus: "complete"),
            makeNote(id: "b", taskStatus: "in_progress"),
            makeNote(id: "c", taskStatus: "review_required"),
            makeNote(id: "d", taskStatus: "not_started"),
            makeNote(id: "e", taskStatus: "waiting"),
            makeNote(id: "f", taskStatus: "discussion_needed"),
            makeNote(id: "g", taskStatus: "blocked")
        ]
        let content = ["a", "b", "c", "d", "e", "f", "g"].map { link("Task", $0) }.joined(separator: "\n")
        let stats = TaskContentParser.parseTaskStats(content: content, notes: notes)
        #expect(stats == TaskStats(total: 7, completed: 1, inProgress: 2))
    }

    @Test func cancelledTasksAreExcludedFromTotal() {
        let notes = [
            makeNote(id: "a", taskStatus: "cancelled"),
            makeNote(id: "b", taskStatus: "complete")
        ]
        let content = link("Cancelled", "a") + "\n" + link("Done", "b")
        let stats = TaskContentParser.parseTaskStats(content: content, notes: notes)
        #expect(stats == TaskStats(total: 1, completed: 1, inProgress: 0))
    }

    @Test func unresolvedIdsCountTowardTotalOnly() {
        let content = link("Ghost", "does-not-exist")
        let stats = TaskContentParser.parseTaskStats(content: content, notes: [])
        #expect(stats == TaskStats(total: 1, completed: 0, inProgress: 0))
    }

    @Test func linkedNoteWithoutTaskStatusCountsTowardTotalOnly() {
        let notes = [makeNote(id: "a", taskStatus: nil)]
        let stats = TaskContentParser.parseTaskStats(content: link("Plain note", "a"), notes: notes)
        #expect(stats == TaskStats(total: 1, completed: 0, inProgress: 0))
    }

    @Test func malformedLinksAreIgnored() {
        let content = """
        [no url]
        [unclosed](intent://local/task/abc
        (intent://local/task/abc)
        [wrong kind](intent://local/note/abc)
        intent://local/task/abc
        """
        let stats = TaskContentParser.parseTaskStats(content: content, notes: [makeNote(id: "abc", taskStatus: "complete")])
        #expect(stats == TaskStats(total: 0, completed: 0, inProgress: 0))
    }

    @Test func plainCheckboxesAreIgnored() {
        let content = "- [ ] just a checkbox\n- [x] done checkbox\n- [/] in progress checkbox"
        let stats = TaskContentParser.parseTaskStats(content: content, notes: [])
        #expect(stats == TaskStats(total: 0, completed: 0, inProgress: 0))
    }

    @Test func duplicateLinksCountPerOccurrence() {
        let notes = [makeNote(id: "a", taskStatus: "complete")]
        let content = link("Once", "a") + "\n" + link("Twice", "a")
        let stats = TaskContentParser.parseTaskStats(content: content, notes: notes)
        #expect(stats == TaskStats(total: 2, completed: 2, inProgress: 0))
    }

    // MARK: - linkedTaskLines

    @Test func returnsLinkedTaskLinesInOrderWithMarkers() {
        let content = """
        # Spec

        - [ ] [First task](intent://local/task/id-1)
        - [x] [Second task](intent://local/task/id-2)
        - [/] [Third task](intent://local/task/id-3)
        See also [inline link](intent://local/task/id-4) in prose.
        - [ ] plain checkbox without link
        """
        let lines = TaskContentParser.linkedTaskLines(in: content)
        #expect(lines.count == 4)
        #expect(lines.map(\.noteId) == ["id-1", "id-2", "id-3", "id-4"])
        #expect(lines.map(\.title) == ["First task", "Second task", "Third task", "inline link"])
        #expect(lines.map(\.checkboxMarker) == [" ", "x", "/", nil])
        #expect(lines.map(\.lineIndex) == [2, 3, 4, 5])
    }

    @Test func lineRangeCoversTheFullLine() {
        let content = "intro\n- [ ] [Task](intent://local/task/id-9)\noutro"
        let lines = TaskContentParser.linkedTaskLines(in: content)
        #expect(lines.count == 1)
        #expect(String(content[lines[0].lineRange]) == "- [ ] [Task](intent://local/task/id-9)")
    }

    @Test func multipleLinksOnOneLineProduceOneEntryPerLink() {
        let content = "- [ ] [A](intent://local/task/id-a) and [B](intent://local/task/id-b)"
        let lines = TaskContentParser.linkedTaskLines(in: content)
        #expect(lines.count == 2)
        #expect(lines.map(\.noteId) == ["id-a", "id-b"])
        #expect(lines.allSatisfy { $0.lineIndex == 0 })
        #expect(lines.allSatisfy { $0.checkboxMarker == " " })
    }

    @Test func indentedAndStarBulletCheckboxesAreRecognized() {
        let content = "  - [x] [Nested](intent://local/task/id-1)\n* [ ] [Star](intent://local/task/id-2)\n- [X] [Upper](intent://local/task/id-3)"
        let lines = TaskContentParser.linkedTaskLines(in: content)
        #expect(lines.map(\.checkboxMarker) == ["x", " ", "x"])
    }

    @Test func emptyContentReturnsNoLines() {
        #expect(TaskContentParser.linkedTaskLines(in: "").isEmpty)
    }
}
