import Foundation

struct TaskStats: Equatable {
    var total: Int
    var completed: Int
    var inProgress: Int
}

struct LinkedTaskLine: Equatable {
    let lineIndex: Int
    let lineRange: Range<String.Index>
    let title: String
    let noteId: String
    let checkboxMarker: Character?
}

enum TaskContentParser {
    private static let taskLinkRegex = #/\[([^\]\r\n]+)\]\(intent://local/task/([^)\r\n]+)\)/#

    private static let checkboxRegex = #/^\s*[-*]\s+\[([ xX/])\]/#

    static func parseTaskStats(content: String?, notes: [Note]) -> TaskStats {
        guard let content, !content.isEmpty else {
            return TaskStats(total: 0, completed: 0, inProgress: 0)
        }
        let noteById = Dictionary(notes.map { ($0.id, $0) }) { first, _ in first }

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

    static func firstTaskLink(in line: String) -> LinkedTaskRef? {
        guard let match = line.firstMatch(of: taskLinkRegex) else {
            return nil
        }
        return LinkedTaskRef(title: String(match.1), noteId: String(match.2))
    }

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
