import SwiftUI
import Textual

/// Textual port of the app's previous compact markdown theme: same relative font
/// scales, weights, margins, and paddings, expressed as a `StructuredText.Style`.
struct CompactMarkdownStyle: StructuredText.Style {
    /// The default point size of the `.body` base font; margins expressed in
    /// `em` in the old theme are computed against this size.
    static let baseFontSize: CGFloat = 17
    static let codeFontScale: CGFloat = 0.85
    static let lineSpacingScale: CGFloat = 0.15

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
            .fontScale(Self.codeFontScale),
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
    private static let scaleReferenceFontSize: CGFloat = 15
    private static let largestHeadingFontSize: CGFloat = 17
    private static let largeHeadingFontSize: CGFloat = 16
    private static let bodyHeadingFontScale: CGFloat = 1
    private static let largestHeadingFontScale = largestHeadingFontSize / scaleReferenceFontSize
    private static let largeHeadingFontScale = largeHeadingFontSize / scaleReferenceFontSize
    private static let fontScales: [CGFloat] = [
        largestHeadingFontScale,
        largeHeadingFontScale,
        bodyHeadingFontScale,
        bodyHeadingFontScale,
        bodyHeadingFontScale,
        bodyHeadingFontScale
    ]
    private static let weights: [Font.Weight] = [
        .semibold,
        .semibold,
        .semibold,
        .medium,
        .medium,
        .medium
    ]
    private static let largeTopMargin: CGFloat = 8
    private static let mediumTopMargin: CGFloat = 6
    private static let compactTopMargin: CGFloat = 4
    private static let topMargins: [CGFloat] = [
        largeTopMargin, largeTopMargin,
        mediumTopMargin, mediumTopMargin,
        compactTopMargin, compactTopMargin
    ]
    private static let maximumHeadingLevel = 6
    private static let arrayIndexOffset = 1
    private static let bottomMargin: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        let level = min(configuration.headingLevel, Self.maximumHeadingLevel)
        configuration.label
            .textual.fontScale(Self.fontScales[level - Self.arrayIndexOffset])
            .fontWeight(Self.weights[level - Self.arrayIndexOffset])
            .textual.blockSpacing(.init(
                top: Self.topMargins[level - Self.arrayIndexOffset],
                bottom: Self.bottomMargin
            ))
    }
}

struct CompactParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .textual.lineSpacing(.fontScaled(CompactMarkdownStyle.lineSpacingScale))
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
    private static let contentPadding: CGFloat = 12
    private static let cornerRadius: CGFloat = 8
    private static let background = DynamicColor(
        light: Constants.Colors.Markdown.codeBlockBackground(for: .light),
        dark: Constants.Colors.Markdown.codeBlockBackground(for: .dark)
    )

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(.fontScaled(CompactMarkdownStyle.lineSpacingScale))
            .textual.fontScale(CompactMarkdownStyle.codeFontScale)
            .fixedSize(horizontal: false, vertical: true)
            .monospaced()
            .padding(Self.contentPadding)
            .background(Self.background)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            .textual.blockSpacing(.init(top: 0, bottom: CompactMarkdownStyle.baseFontSize))
    }
}

/// 17pt cells at the default `.body` size, semibold header row, and the old
/// 0.72em/0.35em cell padding.
struct CompactTableCellStyle: StructuredText.TableCellStyle {
    private static let horizontalPaddingScale: CGFloat = 0.72
    private static let verticalPaddingScale: CGFloat = 0.35

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(configuration.row == 0 ? .semibold : .regular)
            .fixedSize(horizontal: false, vertical: true)
            .textual.lineSpacing(.fontScaled(CompactMarkdownStyle.lineSpacingScale))
            .textual.padding(.horizontal, .fontScaled(Self.horizontalPaddingScale))
            .textual.padding(.vertical, .fontScaled(Self.verticalPaddingScale))
    }
}

struct CompactThematicBreakStyle: StructuredText.ThematicBreakStyle {
    func makeBody(configuration _: Configuration) -> some View {
        Divider()
            .textual.blockSpacing(
                .init(
                    top: 2 * CompactMarkdownStyle.baseFontSize,
                    bottom: 2 * CompactMarkdownStyle.baseFontSize
                )
            )
    }
}
