import Foundation
import SwiftUI

nonisolated struct WorkspaceDiffPresentation: Sendable {
    let id = UUID()
    let hunks: [WorkspaceDiffHunk]
    var oldSource: String?
    var newSource: String?

    struct RowID: Hashable, Sendable {
        let hunk: Int
        let line: Int
    }

    struct Mapping: Sendable {
        let row: RowID
        let range: NSRange
    }

    struct Source: Sendable {
        let text: String
        let mappings: [Mapping]
    }

    static func displayedContent(_ line: WorkspaceDiffLine) -> String {
        line.content.hasSuffix("\n") ? String(line.content.dropLast()) : line.content
    }

    /// Commit diffs retain complete source. Working/staged diffs only expose hunks:
    /// lexer state starts fresh at each contiguous hunk side, never across omitted lines.
    func sources() -> [Source] {
        if let oldSource, let newSource {
            return [fullSource(oldSource, old: true), fullSource(newSource, old: false)]
        }
        return hunks.indices.flatMap { hunk in
            hunkSources(hunk, old: true) + hunkSources(hunk, old: false)
        }
    }

    private func fullSource(_ source: String, old: Bool) -> Source {
        let lines = source.components(separatedBy: "\n")
        var offset = 0
        let ranges = lines.map { line in
            defer { offset += line.utf16.count + 1 }
            return NSRange(location: offset, length: line.utf16.count)
        }
        var mappings: [Mapping] = []
        for (hunkIndex, hunk) in hunks.enumerated() {
            for (lineIndex, line) in hunk.lines.enumerated() {
                guard old ? line.type == .deletion : line.type != .deletion,
                      let number = old ? line.oldNumber : line.newNumber,
                      number > 0, number <= lines.count else { continue }
                let text = lines[number - 1]
                let displayed = Self.displayedContent(line)
                // The builder's no-newline annotation is display-only, never lexer input.
                guard displayed == text || displayed == text + "  ⟵ No newline at end of file" else { continue }
                mappings.append(Mapping(row: RowID(hunk: hunkIndex, line: lineIndex), range: ranges[number - 1]))
            }
        }
        return Source(text: source, mappings: mappings)
    }

    private func hunkSources(_ hunk: Int, old: Bool) -> [Source] {
        var result: [Source] = []
        var text = ""
        var mappings: [Mapping] = []
        var offset = 0
        var previousNumber: Int?
        for (index, line) in hunks[hunk].lines.enumerated() {
            guard old ? line.type != .addition : line.type != .deletion else { continue }
            let number = old ? line.oldNumber : line.newNumber
            if number == nil || previousNumber.map({ number != $0 + 1 }) == true {
                if !text.isEmpty { result.append(Source(text: text, mappings: mappings)) }
                text = ""
                mappings = []
                offset = 0
            }
            previousNumber = number
            guard let number, number > 0 else { continue }
            let content = Self.displayedContent(line)
            if !old || line.type == .deletion {
                mappings.append(Mapping(row: RowID(hunk: hunk, line: index), range: NSRange(location: offset, length: content.utf16.count)))
            }
            text += content + "\n"
            offset += content.utf16.count + 1
        }
        if !text.isEmpty { result.append(Source(text: text, mappings: mappings)) }
        return result
    }

    static func map(_ runs: [FileSyntaxRun], from source: Source) -> [RowID: [FileSyntaxRun]] {
        var result: [RowID: [FileSyntaxRun]] = [:]
        var firstRun = 0
        for mapping in source.mappings {
            while firstRun < runs.count, NSMaxRange(runs[firstRun].range) <= mapping.range.location {
                firstRun += 1
            }
            var index = firstRun
            while index < runs.count, runs[index].location < NSMaxRange(mapping.range) {
                let run = runs[index]
                let intersection = NSIntersectionRange(run.range, mapping.range)
                if intersection.length > 0 {
                    result[mapping.row, default: []].append(FileSyntaxRun(
                        location: intersection.location - mapping.range.location,
                        length: intersection.length,
                        color: run.color
                    ))
                }
                index += 1
            }
        }
        return result
    }
}

@MainActor
enum WorkspaceDiffSyntax {
    typealias Tokenizer = @MainActor (String, String, Bool) async -> [FileSyntaxRun]

    static func highlight(
        _ presentation: WorkspaceDiffPresentation,
        path: String,
        dark: Bool,
        tokenize: Tokenizer = { source, path, dark in
            await FileSyntaxHighlighter.shared.highlight(source: source, path: path, dark: dark)
        }
    ) async -> [WorkspaceDiffPresentation.RowID: [FileSyntaxRun]] {
        guard !Task.isCancelled else { return [:] }
        // Building sources and mapping runs to rows scale with the file; keep both off the main thread.
        let sources = await Task.detached(priority: .userInitiated) { presentation.sources() }.value
        guard sources.reduce(0, { $0 + $1.text.utf8.count }) <= FileSyntaxHighlighter.maxBytes else { return [:] }
        var result: [WorkspaceDiffPresentation.RowID: [FileSyntaxRun]] = [:]
        for source in sources where !source.mappings.isEmpty {
            guard !Task.isCancelled else { return [:] }
            let runs = await tokenize(source.text, path, dark)
            guard !Task.isCancelled else { return [:] }
            let mapped = await Task.detached(priority: .userInitiated) {
                WorkspaceDiffPresentation.map(runs, from: source)
            }.value
            result.merge(mapped) { _, new in new }
        }
        return result
    }

    static func text(_ line: WorkspaceDiffLine, runs: [FileSyntaxRun]) -> AttributedString {
        let content = WorkspaceDiffPresentation.displayedContent(line)
        var result = AttributedString(content)
        for run in runs {
            guard let range = Range(run.range, in: content),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[start..<end].foregroundColor = Color(uiColor: run.uiColor)
        }
        return result
    }
}
