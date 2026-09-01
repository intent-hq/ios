import SwiftUI
import Textual

/// Textual port of the app's previous compact markdown theme: same font sizes,
/// weights, margins, and paddings, expressed as a `StructuredText.Style`.
struct CompactMarkdownStyle: StructuredText.Style {
    /// The body size the old theme was designed around; margins expressed in
    /// `em` in the old theme are computed against this size.
    static let baseFontSize: CGFloat = 15

    /// Inline-code colors from the old `.markdownTextStyle(\.code)` override.
    static let codeForeground = DynamicColor(
        light: Constants.Colors.Markdown.inlineCodeForeground(for: .light),
        dark: Constants.Colors.Markdown.inlineCodeForeground(for: .dark))
    static let codeBackground = DynamicColor(
        light: Constants.Colors.Markdown.inlineCodeBackground(for: .light),
        dark: Constants.Colors.Markdown.inlineCodeBackground(for: .dark))

    let inlineStyle = InlineStyle()
        .code(
            .monospaced, .fontScale(0.85),
            .foregroundColor(CompactMarkdownStyle.codeForeground),
            .backgroundColor(CompactMarkdownStyle.codeBackground))
        .link(.foregroundColor(.blue))
    let headingStyle = CompactHeadingStyle()
    let paragraphStyle = CompactParagraphStyle()
    let blockQuoteStyle = CompactBlockQuoteStyle()
    let codeBlockStyle = CompactCodeBlockStyle()
    let listItemStyle: StructuredText.DefaultListItemStyle = .default
    let unorderedListMarker: StructuredText.HierarchicalSymbolListMarker = .hierarchical(
        .disc, .circle, .square)
    let orderedListMarker: StructuredText.DecimalListMarker = .decimal
    let tableStyle: StructuredText.GitHubTableStyle = .gitHub
    let tableCellStyle = CompactTableCellStyle()
    let thematicBreakStyle = CompactThematicBreakStyle()
}

extension StructuredText.Style where Self == CompactMarkdownStyle {
    static var compact: Self { .init() }
}

/// h1 17pt/semibold, h2 16pt/semibold, h3 15pt/semibold, h4-h6 15pt/medium,
/// with the old 8/6/4pt top and 4pt bottom margins.
struct CompactHeadingStyle: StructuredText.HeadingStyle {
    private static let fontScales: [CGFloat] = [
        17 / CompactMarkdownStyle.baseFontSize, 16 / CompactMarkdownStyle.baseFontSize, 1, 1, 1, 1,
    ]
    private static let weights: [Font.Weight] = [
        .semibold, .semibold, .semibold, .medium, .medium, .medium,
    ]
    private static let topMargins: [CGFloat] = [8, 8, 6, 6, 4, 4]

    func makeBody(configuration: Configuration) -> some View {
        let level = min(configuration.headingLevel, 6)
        configuration.label
            .textual.fontScale(Self.fontScales[level - 1])
            .fontWeight(Self.weights[level - 1])
            .textual.blockSpacing(.init(top: Self.topMargins[level - 1], bottom: 4))
    }
}

struct CompactParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .textual.lineSpacing(.fontScaled(0.15))
            .textual.blockSpacing(.init(top: 0, bottom: CompactMarkdownStyle.baseFontSize))
    }
}

struct CompactBlockQuoteStyle: StructuredText.BlockQuoteStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .italic()
            .textual.padding(.leading, .fontScaled(2))
            .textual.padding(.trailing, .fontScaled(1))
    }
}

/// The old `.markdownBlockStyle(\.codeBlock)` override: 12pt padding, muted
/// rounded box, monospaced 0.85em, no horizontal scroller.
struct CompactCodeBlockStyle: StructuredText.CodeBlockStyle {
    private static let background = DynamicColor(
        light: Constants.Colors.Markdown.codeBlockBackground(for: .light),
        dark: Constants.Colors.Markdown.codeBlockBackground(for: .dark))

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(.fontScaled(0.15))
            .textual.fontScale(0.85)
            .fixedSize(horizontal: false, vertical: true)
            .monospaced()
            .padding(12)
            .background(Self.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .textual.blockSpacing(.init(top: 0, bottom: CompactMarkdownStyle.baseFontSize))
    }
}

/// 15pt cells, semibold header row, the old 0.72em/0.35em cell padding.
struct CompactTableCellStyle: StructuredText.TableCellStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(configuration.row == 0 ? .semibold : .regular)
            .fixedSize(horizontal: false, vertical: true)
            .textual.lineSpacing(.fontScaled(0.15))
            .textual.padding(.horizontal, .fontScaled(0.72))
            .textual.padding(.vertical, .fontScaled(0.35))
    }
}

struct CompactThematicBreakStyle: StructuredText.ThematicBreakStyle {
    func makeBody(configuration _: Configuration) -> some View {
        Divider()
            .textual.blockSpacing(
                .init(
                    top: 2 * CompactMarkdownStyle.baseFontSize,
                    bottom: 2 * CompactMarkdownStyle.baseFontSize))
    }
}
