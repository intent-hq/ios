import Foundation

/// Per-note linked-task aggregate parsed from markdown content.
/// Port of the fe's `parseTaskStats` (sidebar utils): a LOCAL count over
/// `[text](intent://local/task/{id})` links in one note — NOT the canonical
/// workspace-wide task-progress rollup, which the daemon owns (task.list).
struct TaskStats: Equatable {
    var total: Int
    var completed: Int
    var inProgress: Int
}

/// One `[title](intent://local/task/{id})` link found in note content,
/// with enough line info for a renderer to replace the line's checkbox.
struct LinkedTaskLine: Equatable {
    /// 0-based index of the line within the content.
    let lineIndex: Int
    /// Range of the full line (excluding the line terminator) in the content.
    let lineRange: Range<String.Index>
    /// Link text (the task title as written in the note).
    let title: String
    /// Task note ID from the link URL.
    let noteId: String
    /// Checkbox marker preceding the link (" ", "x", "/") when the line is a
    /// checkbox list item; nil when the line has no checkbox. An uppercase
    /// "X" in the source is normalized to "x".
    let checkboxMarker: Character?
}

/// Parsers for `[text](intent://local/task/{id})` links in note markdown.
/// Mirrors the fe's `TASK_LINK_REGEX_FLEXIBLE` / `parseTaskStats`.
enum TaskContentParser {
    /// Matches `[text](intent://local/task/{id})`; group 1 = text, group 2 = id.
    /// Line terminators are excluded from both classes so an unclosed link
    /// cannot consume a later line's `)` and match across lines.
    private static let taskLinkRegex = #/\[([^\]\r\n]+)\]\(intent://local/task/([^)\r\n]+)\)/#

    /// Matches a checkbox list-item prefix; group 1 = the marker character.
    private static let checkboxRegex = #/^\s*[-*]\s+\[([ xX/])\]/#

    /// Count linked-task progress in `content`, resolving each linked ID
    /// against `notes`. Classification (matching the fe):
    /// - cancelled tasks are excluded from the total entirely
    /// - complete counts as completed
    /// - in_progress and review_required count as inProgress
    /// - unresolved IDs and all other statuses count toward total only
    static func parseTaskStats(content: String?, notes: [Note]) -> TaskStats {
        guard let content, !content.isEmpty else {
            return TaskStats(total: 0, completed: 0, inProgress: 0)
        }
        let noteById = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var total = 0
        var completed = 0
        var inProgress = 0

        for match in content.matches(of: taskLinkRegex) {
            let noteId = String(match.2)
            let status = noteById[noteId]?.taskDisplayStatus

            if status == .cancelled { continue }
            total += 1
            switch status {
            case .complete: completed += 1
            case .inProgress, .reviewRequired: inProgress += 1
            default: break
            }
        }

        return TaskStats(total: total, completed: completed, inProgress: inProgress)
    }

    /// First `[title](intent://local/task/{id})` link in `line`, if any.
    static func firstTaskLink(in line: String) -> LinkedTaskRef? {
        guard let match = line.firstMatch(of: taskLinkRegex) else {
            return nil
        }
        return LinkedTaskRef(title: String(match.1), noteId: String(match.2))
    }

    /// Extract linked-task lines from `content`, in document order. Lines with
    /// several task links produce one entry per link. Plain checkboxes without
    /// a task link are not returned.
    static func linkedTaskLines(in content: String) -> [LinkedTaskLine] {
        var results: [LinkedTaskLine] = []
        var lineIndex = 0

        content.enumerateSubstrings(in: content.startIndex..<content.endIndex, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            defer { lineIndex += 1 }
            let line = String(content[lineRange])

            let checkboxMarker = line.firstMatch(of: checkboxRegex)
                .map { Character($0.1.lowercased()) }

            for match in line.matches(of: taskLinkRegex) {
                results.append(LinkedTaskLine(
                    lineIndex: lineIndex,
                    lineRange: lineRange,
                    title: String(match.1),
                    noteId: String(match.2),
                    checkboxMarker: checkboxMarker
                ))
            }
        }

        return results
    }
}
