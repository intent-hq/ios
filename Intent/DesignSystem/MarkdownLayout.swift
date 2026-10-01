import SwiftUI

extension Constants {
    enum Markdown {
        /// Default `.body` size used to convert the compact theme's em margins.
        static let baseFontSize: CGFloat = 17
        static let codeFontScale: CGFloat = 0.85
        static let lineSpacingScale: CGFloat = 0.15
        static let taskListTopSpacing: CGFloat = 2
        static let taskListBottomSpacing: CGFloat = 4
        static let thematicBreakMarginScale: CGFloat = 2
    }
}

extension Constants.Markdown {
    enum Heading {
        private static let scaleReferenceFontSize: CGFloat = 15
        private static let largestHeadingFontSize: CGFloat = 17
        private static let largeHeadingFontSize: CGFloat = 16
        private static let bodyHeadingFontScale: CGFloat = 1
        private static let largestHeadingFontScale = largestHeadingFontSize / scaleReferenceFontSize
        private static let largeHeadingFontScale = largeHeadingFontSize / scaleReferenceFontSize
        static let fontScales: [CGFloat] = [
            largestHeadingFontScale,
            largeHeadingFontScale,
            bodyHeadingFontScale,
            bodyHeadingFontScale,
            bodyHeadingFontScale,
            bodyHeadingFontScale
        ]
        static let weights: [Font.Weight] = [
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
        static let topMargins: [CGFloat] = [
            largeTopMargin, largeTopMargin,
            mediumTopMargin, mediumTopMargin,
            compactTopMargin, compactTopMargin
        ]
        static let bottomMargin: CGFloat = 4
    }

    enum BlockQuote {
        static let leadingPaddingScale: CGFloat = 2
        static let trailingPaddingScale: CGFloat = 1
    }

    enum CodeBlock {
        static let contentPadding: CGFloat = 12
        static let cornerRadius: CGFloat = 8
    }

    enum Table {
        static let bottomMargin: CGFloat = 16
    }

    enum TableCell {
        /// Bound descriptive text without squeezing columns to the viewport.
        static let maximumWidth: CGFloat = 240
        static let horizontalPaddingScale: CGFloat = 0.72
        static let verticalPaddingScale: CGFloat = 0.35
    }
}

extension Constants.Conversation.CodeBlock {
    static let copyLabelSpacing: CGFloat = 4
    static let horizontalPadding: CGFloat = 12
    static let headerVerticalPadding: CGFloat = 8
    static let codeBottomPadding: CGFloat = 12
    static let cornerRadius: CGFloat = 8
}
