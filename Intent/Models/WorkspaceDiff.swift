import Foundation

nonisolated struct WorkspaceDiffLine: Decodable, Identifiable, Equatable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case addition = "Addition"
        case deletion = "Deletion"
        case context = "Context"

        var marker: String {
            switch self {
            case .addition: "+"
            case .deletion: "−"
            case .context: " "
            }
        }
    }

    let type: Kind
    let content: String
    let oldNumber: Int?
    let newNumber: Int?

    var id: String { "\(type.rawValue):\(oldNumber ?? 0):\(newNumber ?? 0)" }
}

nonisolated struct WorkspaceDiffHunk: Decodable, Sendable {
    let oldStart: Int
    let oldLines: Int
    let newStart: Int
    let newLines: Int
    let lines: [WorkspaceDiffLine]

    var heading: String { "@@ −\(oldStart),\(oldLines) +\(newStart),\(newLines) @@" }
}

nonisolated struct WorkspaceFileDiff: Decodable, Sendable {
    let path: String
    let hunks: [WorkspaceDiffHunk]
}

nonisolated struct WorkspaceCommitFile: Decodable, Identifiable, Hashable, Sendable {
    let path: String
    let additions: Int
    let deletions: Int

    var id: String { path }
}

nonisolated enum WorkspaceDiffBuilder {
    private static let maximumBytes = 524_288
    private static let maximumLines = 10_000
    private static let maximumComparisonSize = 4_000_000
    private static let contextLines = 3

    enum Unavailable: LocalizedError {
        case binary
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .binary: "Binary file. A text diff is not available."
            case .tooLarge: "This diff is too large to display on this device. Open it in the desktop app."
            }
        }
    }

    static func hunks(old: String, new: String) throws -> [WorkspaceDiffHunk] {
        guard !old.contains("\0"), !new.contains("\0") else { throw Unavailable.binary }
        guard old.utf8.count + new.utf8.count <= maximumBytes else { throw Unavailable.tooLarge }
        let oldLines = lines(in: old)
        let newLines = lines(in: new)
        guard oldLines.count + newLines.count <= maximumLines,
              oldLines.count * newLines.count <= maximumComparisonSize else { throw Unavailable.tooLarge }
        let difference = newLines.difference(from: oldLines)
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var result: [WorkspaceDiffLine] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if removed.contains(oldIndex) {
                result.append(WorkspaceDiffLine(type: .deletion, content: oldLines[oldIndex], oldNumber: oldIndex + 1, newNumber: nil))
                oldIndex += 1
            } else if inserted.contains(newIndex) {
                result.append(WorkspaceDiffLine(type: .addition, content: newLines[newIndex], oldNumber: nil, newNumber: newIndex + 1))
                newIndex += 1
            } else {
                result.append(WorkspaceDiffLine(type: .context, content: oldLines[oldIndex], oldNumber: oldIndex + 1, newNumber: newIndex + 1))
                oldIndex += 1
                newIndex += 1
            }
        }
        return groupedHunks(result)
    }

    private static func lines(in content: String) -> [String] {
        guard !content.isEmpty else { return [] }
        var result = content.components(separatedBy: "\n")
        if content.utf8.last == UInt8(ascii: "\n") {
            result.removeLast()
        } else {
            result[result.count - 1] += "  ⟵ No newline at end of file"
        }
        return result
    }

    private static func groupedHunks(_ lines: [WorkspaceDiffLine]) -> [WorkspaceDiffHunk] {
        var ranges: [Range<Int>] = []
        for index in lines.indices where lines[index].type != .context {
            let range = max(0, index - contextLines)..<min(lines.count, index + contextLines + 1)
            if let last = ranges.last, last.upperBound >= range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
        }
        return ranges.map { range in
            let selected = Array(lines[range])
            let oldNumbers = selected.compactMap(\.oldNumber)
            let newNumbers = selected.compactMap(\.newNumber)
            return WorkspaceDiffHunk(
                oldStart: oldNumbers.first ?? max(0, (lines[..<range.lowerBound].compactMap(\.oldNumber).last ?? 0)),
                oldLines: oldNumbers.count,
                newStart: newNumbers.first ?? max(0, (lines[..<range.lowerBound].compactMap(\.newNumber).last ?? 0)),
                newLines: newNumbers.count,
                lines: selected
            )
        }
    }
}
