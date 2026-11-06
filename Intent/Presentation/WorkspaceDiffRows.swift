import SwiftUI
import UIKit

nonisolated enum WorkspaceDiffRowID: Hashable, Sendable {
    case heading(Int)
    case line(WorkspaceDiffPresentation.RowID)
}

nonisolated enum WorkspaceDiffRow: Identifiable, Sendable {
    case heading(hunk: Int, text: String)
    case line(WorkspaceDiffPresentation.RowID, WorkspaceDiffLine)

    var id: WorkspaceDiffRowID {
        switch self {
        case let .heading(hunk, _): .heading(hunk)
        case let .line(row, _): .line(row)
        }
    }
}

/// Flattened diff rows with stable IDs, so a lazy stack only builds the lines on screen.
nonisolated struct WorkspaceDiffRows: Sendable {
    /// Embedded diffs sit inside the commit view's scroll view, so they cannot build rows lazily.
    static let embeddedLineLimit = 100
    private static let tabWidth = 4
    private static let wideColumns = 2
    /// Lines measured with the real font; column counts only shortlist them.
    private static let widthCandidates = 4

    let rows: [WorkspaceDiffRow]
    let lineCount: Int
    /// The hunk heading expected to render widest in a monospaced font.
    let widestHeading: String
    /// Displayed lines with the most columns, widest first.
    let widestLines: [String]

    init(hunks: [WorkspaceDiffHunk]) {
        var rows: [WorkspaceDiffRow] = []
        var lineCount = 0
        var widestHeading = (text: "", columns: 0)
        var widestLines: [(text: String, columns: Int)] = []
        for (hunkIndex, hunk) in hunks.enumerated() {
            let heading = hunk.heading
            rows.append(.heading(hunk: hunkIndex, text: heading))
            let headingColumns = Self.columns(heading)
            if headingColumns > widestHeading.columns { widestHeading = (heading, headingColumns) }
            for (lineIndex, line) in hunk.lines.enumerated() {
                rows.append(.line(.init(hunk: hunkIndex, line: lineIndex), line))
                let content = WorkspaceDiffPresentation.displayedContent(line)
                let columns = Self.columns(content)
                if widestLines.count < Self.widthCandidates || columns > widestLines[widestLines.count - 1].columns {
                    let index = widestLines.firstIndex { $0.columns < columns } ?? widestLines.endIndex
                    widestLines.insert((content, columns), at: index)
                    if widestLines.count > Self.widthCandidates { widestLines.removeLast() }
                }
            }
            lineCount += hunk.lines.count
        }
        self.rows = rows
        self.lineCount = lineCount
        self.widestHeading = widestHeading.text
        self.widestLines = widestLines.map(\.text)
    }

    /// Rows up to and including the `limit`th line; nil shows every row.
    func rows(limit: Int?) -> ArraySlice<WorkspaceDiffRow> {
        guard let limit, limit < lineCount else { return rows[...] }
        var seen = 0
        for (index, row) in rows.enumerated() {
            guard case .line = row else { continue }
            seen += 1
            if seen == limit { return rows[...index] }
        }
        return rows[...]
    }

    /// Approximate monospaced columns: tabs advance to the next 4-column stop and non-ASCII scalars,
    /// which include wide CJK and emoji, take two.
    static func columns(_ text: String) -> Int {
        var columns = 0
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .enclosingMark, .format:
                continue
            default:
                if scalar == "\t" {
                    columns += tabWidth - columns % tabWidth
                } else {
                    columns += scalar.isASCII ? 1 : wideColumns
                }
            }
        }
        return columns
    }
}

extension WorkspaceDiffRows {
    /// Horizontal padding on every diff row (SwiftUI's default `.padding(.horizontal)` on iOS).
    static let horizontalPadding: CGFloat = 16
    /// A line row is old number, new number, marker and content: three gaps.
    private static let lineRowGaps: CGFloat = 3

    /// The UIKit equivalent of `.system(.caption, design: .monospaced)` at `size`.
    @MainActor
    static func font(for size: DynamicTypeSize) -> UIFont {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        let pointSize = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits).pointSize
        return .monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }

    /// Width of the widest row, including line-number gutters, marker, spacing and padding.
    func contentWidth(font: UIFont) -> CGFloat {
        let padding = Self.horizontalPadding * 2
        let gutter = WorkspaceChangesLayout.lineNumberWidth * 2
            + Self.textWidth("+", font: font)
            + WorkspaceChangesLayout.sectionSpacing * Self.lineRowGaps
        return max(
            padding + Self.textWidth(widestHeading, font: font),
            padding + gutter + (widestLines.map { Self.textWidth($0, font: font) }.max() ?? 0)
        )
    }

    static func textWidth(_ text: String, font: UIFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width.rounded(.up)
    }
}
