import Foundation
@testable import Intent
import Testing

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
        guard case .taskLine(let secondTask) = segments[1] else {
            Issue.record("expected task line"); return
        }
        #expect(secondTask.lineNumber == 3)
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

extension NoteContentSegmentsTests {
    @Test(arguments: ["```", "~~~"])
    func closedMermaidFencesKeepSurroundingMarkdownTogether(marker: String) {
        let source = "flowchart TD\n  A --> B"
        let content = "# Plan\n\n\(marker)mermaid\n\(source)\n\(marker)\n\nAfter"
        #expect(NoteContentSegmenter.segments(for: content) == [.markdown(content)])
    }

    @Test func adjacentDiagramsPreserveFollowingTaskLineNumber() throws {
        let content = "```mermaid\nflowchart TD\n```\n~~~mermaid\nsequenceDiagram\n~~~\n- [ ] Review"
        let segments = NoteContentSegmenter.segments(for: content)
        try #require(segments.count == 2)
        #expect(segments[0] == .markdown("```mermaid\nflowchart TD\n```\n~~~mermaid\nsequenceDiagram\n~~~"))
        guard case .taskLine(let task) = segments[1] else {
            Issue.record("expected task after both diagrams"); return
        }
        #expect(task.lineNumber == 7)
        #expect(task.text == "Review")
    }

    @Test(arguments: ["```", "```swift", "~~~", "~~~swift", "```mermaid", "~~~mermaid", "```MERMAID", "~~~Mermaid", "```mermaid extra"])
    func fencesKeepCheckboxesAsSource(opening: String) throws {
        let closing = String(opening.prefix(3))
        let code = "\(opening)\n- [ ] [Example](intent://local/task/example)\n\(closing)"
        let segments = NoteContentSegmenter.segments(for: code + "\n- [x] Real task")
        try #require(segments.count == 2)
        #expect(segments[0] == .markdown(code))
        guard case .taskLine(let task) = segments[1] else {
            Issue.record("expected task after ordinary code"); return
        }
        #expect(task.lineNumber == 4)
        #expect(task.marker == "x")
    }

    @Test func nestedMermaidFenceInsideLongerCodeFenceStaysSource() {
        let content = "````markdown\n```mermaid\nflowchart TD\n```\n- [ ] Example\n````"
        #expect(NoteContentSegmenter.segments(for: content) == [.markdown(content)])
    }

    @Test(arguments: ["```mermaid", "~~~mermaid", "```swift", "~~~"])
    func unclosedFencesStaySourceAndProtectCheckboxes(opening: String) {
        let content = "Intro\n\(opening)\nflowchart TD\n- [ ] Still code\n"
        #expect(NoteContentSegmenter.segments(for: content) == [.markdown(content)])
    }

    @Test(arguments: ["```", "~~~~", "```` trailing", "````mermaid", "    ````", "\t````"])
    func invalidClosersStayInsideMermaidSource(candidate: String) {
        let source = "flowchart TD\n\(candidate)\n- [ ] Still code"
        let content = "````mermaid\n\(source)\n````"
        #expect(NoteContentSegmenter.segments(for: content) == [.markdown(content)])
    }

    @Test func longerClosersAndWhitespaceAreAccepted() {
        let content = "````mermaid\nflowchart TD\n   ````` \t\n~~~mermaid\nsequenceDiagram\n ~~~~~\t"
        #expect(NoteContentSegmenter.segments(for: content) == [.markdown(content)])
        #expect(MermaidMarkdownContent(content).sources.count == 2)
    }

    @Test(arguments: ["    ```mermaid", "\t```mermaid", "```mer`maid", "``mermaid"])
    func invalidOpenersRemainMarkdown(opening: String) {
        let content = "\(opening)\nflowchart TD\n```"
        #expect(NoteContentSegmenter.segments(for: content) == [.markdown(content)])
    }

    @Test func backticksInInfoDoNotOpenFence() throws {
        let segments = NoteContentSegmenter.segments(for: "```mer`maid\n- [ ] Real task")
        try #require(segments.count == 2)
        #expect(segments[0] == .markdown("```mer`maid"))
        guard case .taskLine(let task) = segments[1] else {
            Issue.record("expected task after invalid opener"); return
        }
        #expect(task.lineNumber == 2)
    }

    @Test func tildeInfoCanContainBackticks() {
        let content = "~~~a`b\n- [ ] Example\n~~~"
        #expect(NoteContentSegmenter.segments(for: content) == [.markdown(content)])
    }

    @Test func openingIndentIsPreservedForMarkdownRenderer() {
        let content = "   ``` mermaid \t\n   flowchart TD\n     A --> B\n B --> C\n   ```"
        #expect(NoteContentSegmenter.segments(for: content) == [.markdown(content)])
        #expect(Array(MermaidMarkdownContent(content).sources.values) == ["flowchart TD\n  A --> B\nB --> C"])
        let ordinaryCode = "   ```swift\n   - [ ] Example\n   ```"
        #expect(NoteContentSegmenter.segments(for: ordinaryCode) == [.markdown(ordinaryCode)])
    }

    @Test func crlfDiagramsPreserveTaskPositionsAndRewriteLineEndings() throws {
        let content = "Intro\r\n```mermaid\r\nflowchart TD\r\n\r\n```\r\n- [ ] Review\r\n"
        let segments = NoteContentSegmenter.segments(for: content)
        try #require(segments.count == 2)
        #expect(segments[0] == .markdown("Intro\n```mermaid\nflowchart TD\n\n```"))
        guard case .taskLine(let task) = segments[1] else {
            Issue.record("expected task after CRLF diagram"); return
        }
        #expect(task.lineNumber == 6)
        let updated = NoteContentSegmenter.replacingCheckboxMarker(in: content, line: task.lineNumber, status: "done")
        #expect(updated == content.replacingOccurrences(of: "- [ ] Review", with: "- [x] Review"))
    }

    @Test func emptyClosedMermaidFenceReachesDiagramRenderer() {
        let content = "```mermaid\n```"
        #expect(NoteContentSegmenter.segments(for: content) == [.markdown(content)])
        #expect(Array(MermaidMarkdownContent(content).sources.values) == [""])
    }
}
