import Foundation
import Testing
@testable import Intent

struct NoteContentSegmentsTests {
    // MARK: - segments(for:)

    @Test func plainMarkdownIsOneSegment() {
        let content = "# Title\n\nSome paragraph text."
        #expect(NoteContentSegmenter.segments(for: content) == [.markdown(content)])
    }

    @Test func splitsMarkdownAndTaskLines() {
        let content = "# Plan\n\n- [ ] First\n- [x] Second\n\nFooter text"
        let segments = NoteContentSegmenter.segments(for: content)
        #expect(segments.count == 4)
        #expect(segments[0] == .markdown("# Plan\n"))
        guard case .taskLine(let first) = segments[1], case .taskLine(let second) = segments[2] else {
            Issue.record("expected task-line segments"); return
        }
        #expect(first.lineNumber == 3)
        #expect(first.marker == " ")
        #expect(first.text == "First")
        #expect(second.lineNumber == 4)
        #expect(second.marker == "x")
        #expect(segments[3] == .markdown("\nFooter text"))
    }

    @Test func lineNumbersAreOneBasedContentPositions() {
        let content = "intro\n\n- [/] Working on it"
        let segments = NoteContentSegmenter.segments(for: content)
        guard case .taskLine(let line) = segments.last else {
            Issue.record("expected trailing task line"); return
        }
        #expect(line.lineNumber == 3)
        #expect(line.marker == "/")
    }

    @Test func whitespaceOnlyRunsBetweenTaskLinesAreDropped() {
        let content = "- [ ] A\n\n- [ ] B"
        let segments = NoteContentSegmenter.segments(for: content)
        #expect(segments.count == 2)
        guard case .taskLine(let b) = segments[1] else {
            Issue.record("expected task line"); return
        }
        #expect(b.lineNumber == 3)
    }

    @Test func nestedIndentedCheckboxes() {
        let content = "- [ ] Parent\n  - [x] Child\n\t- [/] Tab child"
        let segments = NoteContentSegmenter.segments(for: content)
        #expect(segments.count == 3)
        guard case .taskLine(let parent) = segments[0],
              case .taskLine(let child) = segments[1],
              case .taskLine(let tabChild) = segments[2] else {
            Issue.record("expected 3 task lines"); return
        }
        #expect(parent.indentColumns == 0)
        #expect(child.indentColumns == 2)
        #expect(child.marker == "x")
        #expect(tabChild.indentColumns == 1)
        #expect(tabChild.marker == "/")
    }

    @Test func starBulletsStayMarkdown() {
        // The daemon's task.update parser (parse_dash_checkbox) accepts only
        // `-` bullets, so a `* [ ]` line must not become an interactive row.
        let content = "* [ ] Star bullet\n* [x] Star done"
        #expect(NoteContentSegmenter.segments(for: content) == [.markdown(content)])
    }

    @Test func uppercaseMarkerNormalizes() {
        guard case .taskLine(let line)? = NoteContentSegmenter.segments(for: "- [X] Done").first else {
            Issue.record("expected task line"); return
        }
        #expect(line.marker == "x")
        #expect(line.markerStatus == .complete)
    }

    @Test func markerStatusFallbackMapping() {
        func status(_ content: String) -> TaskDisplayStatus? {
            guard case .taskLine(let line)? = NoteContentSegmenter.segments(for: content).first else { return nil }
            return line.markerStatus
        }
        #expect(status("- [ ] Todo") == .notStarted)
        #expect(status("- [/] Doing") == .inProgress)
        #expect(status("- [x] Done") == .complete)
    }

    @Test func linkedTaskLineCarriesRef() {
        let content = "- [ ] [My Task](intent://local/task/abc-123)"
        guard case .taskLine(let line)? = NoteContentSegmenter.segments(for: content).first else {
            Issue.record("expected task line"); return
        }
        #expect(line.linkedTask == LinkedTaskRef(title: "My Task", noteId: "abc-123"))
    }

    @Test func plainCheckboxHasNoLinkedTask() {
        guard case .taskLine(let line)? = NoteContentSegmenter.segments(for: "- [ ] Plain").first else {
            Issue.record("expected task line"); return
        }
        #expect(line.linkedTask == nil)
    }

    @Test func nonCheckboxBracketsStayMarkdown() {
        let content = "- [not a checkbox] item\n-[ ] missing space\ntext [x] inline"
        #expect(NoteContentSegmenter.segments(for: content) == [.markdown(content)])
    }

    @Test func crlfLineEndingsAreHandled() {
        let content = "intro\r\n- [x] Done\r\nafter"
        let segments = NoteContentSegmenter.segments(for: content)
        #expect(segments.count == 3)
        guard case .taskLine(let line) = segments[1] else {
            Issue.record("expected task line"); return
        }
        #expect(line.lineNumber == 2)
        #expect(line.text == "Done")
    }

    @Test func emptyCheckboxTextIsAllowed() {
        guard case .taskLine(let line)? = NoteContentSegmenter.segments(for: "- [ ] ").first else {
            Issue.record("expected task line"); return
        }
        #expect(line.text.isEmpty)
    }

    @Test func taskLineAcceptsTrailingCarriageReturn() {
        guard let line = NoteContentSegmenter.taskLine(from: "- [x] Done\r", lineNumber: 7) else {
            Issue.record("expected task line"); return
        }
        #expect(line.lineNumber == 7)
        #expect(line.marker == "x")
        #expect(line.text == "Done")
    }

    // MARK: - replacingCheckboxMarker

    @Test func rewritesMarkerForEachStatus() {
        let content = "intro\n- [ ] Task"
        #expect(NoteContentSegmenter.replacingCheckboxMarker(in: content, line: 2, status: "done") == "intro\n- [x] Task")
        #expect(NoteContentSegmenter.replacingCheckboxMarker(in: content, line: 2, status: "in-progress") == "intro\n- [/] Task")
        let done = "intro\n- [x] Task"
        #expect(NoteContentSegmenter.replacingCheckboxMarker(in: done, line: 2, status: "todo") == "intro\n- [ ] Task")
    }

    @Test func rewriteRejectsBadInput() {
        let content = "intro\n- [ ] Task"
        #expect(NoteContentSegmenter.replacingCheckboxMarker(in: content, line: 1, status: "done") == nil)
        #expect(NoteContentSegmenter.replacingCheckboxMarker(in: content, line: 5, status: "done") == nil)
        #expect(NoteContentSegmenter.replacingCheckboxMarker(in: content, line: 0, status: "done") == nil)
        #expect(NoteContentSegmenter.replacingCheckboxMarker(in: content, line: 2, status: "bogus") == nil)
    }

    @Test func rewritePreservesIndentAndText() {
        let content = "  - [ ] [T](intent://local/task/t1)"
        let rewritten = NoteContentSegmenter.replacingCheckboxMarker(in: content, line: 1, status: "done")
        #expect(rewritten == "  - [x] [T](intent://local/task/t1)")
    }
}
