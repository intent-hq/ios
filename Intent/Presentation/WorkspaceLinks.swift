import Foundation

enum WorkspaceLinks {
    enum Segment: Equatable {
        case markdown(String)
        case workspaces([String])
    }

    private static let minimumFenceLength = 3
    private static let codeIndent = 4
    private static let linkPrefix = "intent://local/workspace/"

    static func parse(_ text: String) -> [Segment] {
        let lines = text.components(separatedBy: "\n")
        var result: [Segment] = []
        var start = 0
        var index = 0
        var fence: String?
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if let marker = fence {
                if closesFence(line, marker: marker) { fence = nil }
            } else if !lines[index].hasPrefix(String(repeating: " ", count: codeIndent)),
                      !lines[index].hasPrefix("\t") {
                let marker = fenceMarker(line)
                let isWorkspaceFence = marker?.first == "`" && line == (marker ?? "") + "workspace"
                if line == "@@@workspace" || isWorkspaceFence,
                   let end = closingLine(in: lines, after: index, marker: isWorkspaceFence ? marker : nil),
                   let ids = workspaceIDs(lines[(index + 1)..<end]) {
                    if start < index { result.append(.markdown(lines[start..<index].joined(separator: "\n") + "\n")) }
                    result.append(.workspaces(ids))
                    index = end
                    start = end + 1
                } else {
                    fence = marker
                }
            }
            index += 1
        }
        if start < lines.count { result.append(.markdown(lines[start...].joined(separator: "\n"))) }
        return result
    }

    static func coalescingTextBlocks(_ blocks: [ContentBlock]) -> [ContentBlock] {
        var result: [ContentBlock] = []
        var pending: [ContentBlock] = []
        func flush() {
            let text = pending.compactMap(\.resolvedText).joined()
            if var first = pending.first, text.contains("@@@workspace") || text.contains("```workspace") {
                first.text = text
                result.append(first)
            } else {
                result.append(contentsOf: pending)
            }
            pending = []
        }
        for block in blocks {
            if block.type == .text {
                pending.append(block)
            } else {
                flush()
                result.append(block)
            }
        }
        flush()
        return result
    }

    private static func workspaceIDs(_ lines: ArraySlice<String>) -> [String]? {
        var ids: [String] = []
        for line in lines {
            var id = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty { continue }
            if id.hasPrefix("- ") || id.hasPrefix("* ") { id = String(id.dropFirst(2)) }
            id = id.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            if id.hasPrefix(linkPrefix) { id = String(id.dropFirst(linkPrefix.count)) }
            guard id.wholeMatch(of: /[A-Za-z0-9_-]+/) != nil else { return nil }
            if !ids.contains(id) { ids.append(id) }
        }
        return ids.isEmpty ? nil : ids
    }

    private static func fenceMarker(_ line: String) -> String? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let marker = String(line.prefix(while: { $0 == first }))
        return marker.count >= minimumFenceLength ? marker : nil
    }

    private static func closesFence(_ line: String, marker: String) -> Bool {
        line.count >= marker.count && line.allSatisfy { $0 == marker.first }
    }

    private static func closingLine(in lines: [String], after start: Int, marker: String?) -> Int? {
        ((start + 1)..<lines.count).first { index in
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return marker.map { closesFence(line, marker: $0) } ?? (line == "@@@")
        }
    }
}
