import Foundation

/// One checkbox line extracted from note content.
struct NoteTaskLine: Equatable {
    /// 1-based line number in the note content (the daemon `task.update`
    /// method's `line` param, PROTOCOL §5.4).
    let lineNumber: Int
    /// Normalized checkbox marker: " ", "x", or "/" (uppercase "X" → "x").
    let marker: Character
    /// Inline text after the checkbox marker.
    let text: String
    /// Number of leading whitespace characters (nesting indent).
    let indentColumns: Int
    /// First `[title](intent://local/task/{id})` link on the line, if any.
    let linkedTask: LinkedTaskRef?

    /// Display status implied by the checkbox marker. Used directly for plain
    /// checkbox rows, and as the fallback for linked-task lines whose note is
    /// not resolved in the workspace note list yet.
    var markerStatus: TaskDisplayStatus {
        switch marker {
        case "x": return .complete
        case "/": return .inProgress
        default: return .notStarted
        }
    }
}

/// A task-note link target on a checkbox line.
struct LinkedTaskRef: Equatable {
    /// Link text (the task title as written in the note).
    let title: String
    /// Task note ID from the link URL.
    let noteId: String
}

/// A run of note content: either ordinary markdown or a single checkbox line.
enum NoteContentSegment: Equatable {
    case markdown(String)
    case taskLine(NoteTaskLine)
}

/// Splits note markdown into markdown segments and task-line segments so the
/// note detail view can render checkbox lines as native rows (replacing the
/// old emoji marker substitution). Checkbox syntax: `- [ ]` / `- [x]` / `- [/]`
/// at any indent. Only `-` bullets — the daemon's `task.update` line parser
/// (note_ops.rs `parse_dash_checkbox`) rejects `*` bullets, so a `* [ ]` line
/// must stay ordinary markdown rather than become a row whose status write
/// would fail.
enum NoteContentSegmenter {
    /// Groups: 1 = leading indent, 2 = marker, 3 = text after the checkbox.
    private static let checkboxLineRegex = #/^([ \t]*)-\s+\[([ xX/])\]\s?(.*)$/#

    static func segments(for content: String) -> [NoteContentSegment] {
        var segments: [NoteContentSegment] = []
        var markdownBuffer: [String] = []

        func flushMarkdown() {
            guard !markdownBuffer.isEmpty else { return }
            let text = markdownBuffer.joined(separator: "\n")
            markdownBuffer = []
            // Drop whitespace-only runs (e.g. blank lines between task lines).
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            segments.append(.markdown(text))
        }

        for (index, rawLine) in content.components(separatedBy: "\n").enumerated() {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if let taskLine = taskLine(from: line, lineNumber: index + 1) {
                flushMarkdown()
                segments.append(.taskLine(taskLine))
            } else {
                markdownBuffer.append(line)
            }
        }
        flushMarkdown()

        return segments
    }

    /// Parse a single content line as a checkbox line; nil when it is not one.
    /// `lineNumber` is the 1-based position of the line within the content.
    static func taskLine(from line: String, lineNumber: Int) -> NoteTaskLine? {
        guard let match = line.wholeMatch(of: checkboxLineRegex) else {
            return nil
        }
        let text = String(match.3)
        return NoteTaskLine(
            lineNumber: lineNumber,
            marker: Character(match.2.lowercased()),
            text: text,
            indentColumns: match.1.count,
            linkedTask: TaskContentParser.firstTaskLink(in: text)
        )
    }

    /// Rewrite the checkbox marker on `line` (1-based) of `content` for a
    /// checkbox status word ("todo" | "in-progress" | "done"). Returns nil when
    /// the status is unknown or the addressed line is not a checkbox line.
    static func replacingCheckboxMarker(in content: String, line: Int, status: String) -> String? {
        let marker: String
        switch status {
        case "todo": marker = " "
        case "in-progress": marker = "/"
        case "done": marker = "x"
        default: return nil
        }

        var lines = content.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return nil }
        let target = lines[line - 1]
        let matchTarget = target.hasSuffix("\r") ? target.dropLast() : target[...]
        guard let match = matchTarget.wholeMatch(of: checkboxLineRegex) else {
            return nil
        }
        let markerRange = match.2.startIndex..<match.2.endIndex
        lines[line - 1] = target.replacingCharacters(in: markerRange, with: marker)
        return lines.joined(separator: "\n")
    }
}
