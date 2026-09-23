import SwiftUI
import Textual

/// Textual port of the app's previous compact markdown theme: same relative font
/// scales, weights, margins, and paddings, expressed as a `StructuredText.Style`.
struct CompactMarkdownStyle: StructuredText.Style {
    /// Inline-code colors from the old `.markdownTextStyle(\.code)` override.
    static let codeForeground = DynamicColor(
        light: Constants.Colors.Markdown.inlineCodeForeground(for: .light),
        dark: Constants.Colors.Markdown.inlineCodeForeground(for: .dark)
    )
    static let codeBackground = DynamicColor(
        light: Constants.Colors.Markdown.inlineCodeBackground(for: .light),
        dark: Constants.Colors.Markdown.inlineCodeBackground(for: .dark)
    )

    let inlineStyle = InlineStyle()
        .code(
            .monospaced,
            .fontScale(Constants.Markdown.codeFontScale),
            .foregroundColor(Self.codeForeground),
            .backgroundColor(Self.codeBackground)
        )
        .link(.foregroundColor(.blue))
    let headingStyle = CompactHeadingStyle()
    let paragraphStyle = CompactParagraphStyle()
    let blockQuoteStyle = CompactBlockQuoteStyle()
    let codeBlockStyle = CompactCodeBlockStyle()
    let listItemStyle: StructuredText.DefaultListItemStyle = .default
    let unorderedListMarker: StructuredText.HierarchicalSymbolListMarker = .hierarchical(
        .disc,
        .circle,
        .square
    )
    let orderedListMarker: StructuredText.DecimalListMarker = .decimal
    let tableStyle: StructuredText.GitHubTableStyle = .gitHub
    let tableCellStyle = CompactTableCellStyle()
    let thematicBreakStyle = CompactThematicBreakStyle()
}

extension StructuredText.Style where Self == CompactMarkdownStyle {
    static var compact: Self { .init() }
}

/// At the default `.body` size: h1 19.27pt/semibold, h2 18.13pt/semibold,
/// h3 17pt/semibold, h4-h6 17pt/medium, with 8/6/4pt top and 4pt bottom margins.
struct CompactHeadingStyle: StructuredText.HeadingStyle {
    private static let maximumHeadingLevel = 6
    private static let arrayIndexOffset = 1

    func makeBody(configuration: Configuration) -> some View {
        let level = min(configuration.headingLevel, Self.maximumHeadingLevel)
        configuration.label
            .textual.fontScale(Constants.Markdown.Heading.fontScales[level - Self.arrayIndexOffset])
            .fontWeight(Constants.Markdown.Heading.weights[level - Self.arrayIndexOffset])
            .textual.blockSpacing(.init(
                top: Constants.Markdown.Heading.topMargins[level - Self.arrayIndexOffset],
                bottom: Constants.Markdown.Heading.bottomMargin
            ))
    }
}

struct CompactParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .textual.lineSpacing(.fontScaled(Constants.Markdown.lineSpacingScale))
            .textual.blockSpacing(.init(top: 0, bottom: Constants.Markdown.baseFontSize))
    }
}

struct CompactBlockQuoteStyle: StructuredText.BlockQuoteStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .italic()
            .textual.padding(.leading, .fontScaled(Constants.Markdown.BlockQuote.leadingPaddingScale))
            .textual.padding(.trailing, .fontScaled(Constants.Markdown.BlockQuote.trailingPaddingScale))
    }
}

/// The old `.markdownBlockStyle(\.codeBlock)` override: 12pt padding, muted
/// rounded box, monospaced 0.85em, no horizontal scroller.
struct CompactCodeBlockStyle: StructuredText.CodeBlockStyle {
    private static let background = DynamicColor(
        light: Constants.Colors.Markdown.codeBlockBackground(for: .light),
        dark: Constants.Colors.Markdown.codeBlockBackground(for: .dark)
    )

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(.fontScaled(Constants.Markdown.lineSpacingScale))
            .textual.fontScale(Constants.Markdown.codeFontScale)
            .fixedSize(horizontal: false, vertical: true)
            .monospaced()
            .padding(Constants.Markdown.CodeBlock.contentPadding)
            .background(Self.background)
            .clipShape(RoundedRectangle(cornerRadius: Constants.Markdown.CodeBlock.cornerRadius))
            .textual.blockSpacing(.init(top: 0, bottom: Constants.Markdown.baseFontSize))
    }
}

/// 17pt cells at the default `.body` size, semibold header row, and the old
/// 0.72em/0.35em cell padding.
struct CompactTableCellStyle: StructuredText.TableCellStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(configuration.row == 0 ? .semibold : .regular)
            .fixedSize(horizontal: false, vertical: true)
            .textual.lineSpacing(.fontScaled(Constants.Markdown.lineSpacingScale))
            .textual.padding(.horizontal, .fontScaled(Constants.Markdown.TableCell.horizontalPaddingScale))
            .textual.padding(.vertical, .fontScaled(Constants.Markdown.TableCell.verticalPaddingScale))
    }
}

struct CompactThematicBreakStyle: StructuredText.ThematicBreakStyle {
    func makeBody(configuration _: Configuration) -> some View {
        Divider()
            .textual.blockSpacing(
                .init(
                    top: Constants.Markdown.thematicBreakMarginScale * Constants.Markdown.baseFontSize,
                    bottom: Constants.Markdown.thematicBreakMarginScale * Constants.Markdown.baseFontSize
                )
            )
    }
}
