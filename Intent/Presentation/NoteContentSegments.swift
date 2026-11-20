import Foundation

struct NoteTaskLine: Equatable {
    let lineNumber: Int
    let marker: Character
    let text: String
    let indentColumns: Int
    let linkedTask: LinkedTaskRef?

    var markerStatus: TaskDisplayStatus {
        switch marker {
        case "x": return .complete
        case "/": return .inProgress
        default: return .notStarted
        }
    }
}

struct LinkedTaskRef: Equatable {
    let title: String
    let noteId: String
}

enum NoteContentSegment: Equatable {
    case markdown(String)
    case taskLine(NoteTaskLine)
}

enum NoteContentSegmenter {
    private static let checkboxLineRegex = #/^([ \t]*)-\s+\[([ xX/])\]\s?(.*)$/#

    static func segments(for content: String) -> [NoteContentSegment] {
        var segments: [NoteContentSegment] = []
        var markdownBuffer: [String] = []

        func flushMarkdown() {
            guard !markdownBuffer.isEmpty else { return }
            let text = markdownBuffer.joined(separator: "\n")
            markdownBuffer = []
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            segments.append(.markdown(text))
        }

        let lines = content.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let fence = MarkdownCodeFence(opening: line) {
                var end = index + 1
                while end < lines.count, !fence.closes(with: lines[end]) { end += 1 }
                markdownBuffer.append(contentsOf: lines[index..<min(end + 1, lines.count)])
                index = min(end + 1, lines.count)
                continue
            }
            if let taskLine = taskLine(from: line, lineNumber: index + 1) {
                flushMarkdown()
                segments.append(.taskLine(taskLine))
            } else {
                markdownBuffer.append(line)
            }
            index += 1
        }
        flushMarkdown()

        return segments
    }

    static func taskLine(from line: String, lineNumber: Int) -> NoteTaskLine? {
        let matchTarget = line.hasSuffix("\r") ? line.dropLast() : line[...]
        guard let match = matchTarget.wholeMatch(of: checkboxLineRegex) else {
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
