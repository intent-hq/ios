import SwiftUI

extension Constants {
    /// Inter styles from the IOS Working Figma page. Sizes are the `.large` Dynamic Type baseline.
    /// Static Regular 400 and Medium 500 intentionally approximate Figma's 450 and 550;
    /// SemiBold 600 matches directly. Figma's “Bold” body styles use Medium, not Bold.
    /// Tracking units remain unverified, and Figma line-height ratios are not imposed on text layout.
    /// Apply to text only; preserve native control, SF Symbol, and monospaced fonts.
    /// Use `interFont` on SwiftUI text for Bold Text support. Unsupported scripts and emoji
    /// use the platform's glyph fallback; Inter does not cover every Unicode character.
    enum Typography {
        private static let heading1Size: CGFloat = 40
        private static let heading2Size: CGFloat = 28
        private static let bodyMSize: CGFloat = 18
        private static let bodySSize: CGFloat = 16
        private static let bodyXSSize: CGFloat = 14
        private static let smallLabelSize: CGFloat = 12

        /// IOS/IOS H1 — 40/600. Large-title scaling for prominent custom page headings.
        static let heading1 = Style(face: .semibold, size: heading1Size, relativeTo: .largeTitle)

        /// IOS/IOS H2 — 28/600. Title scaling for custom screen and section headings.
        static let heading2 = Style(face: .semibold, size: heading2Size, relativeTo: .title)

        /// IOS/IOS Body M — 18/550. Headline scaling for primary row titles.
        static let bodyM = Style(face: .medium, size: bodyMSize, relativeTo: .headline)

        /// IOS/IOS Body S — 16/450. Body scaling for prose and action descriptions.
        static let bodyS = Style(face: .regular, size: bodySSize, relativeTo: .body)

        /// IOS/IOS Body S Bold — 16/550. Emphasis changes the face, not the body scaling role.
        static let bodySEmphasized = Style(face: .medium, size: bodySSize, relativeTo: .body)

        /// IOS/IOS Body XS — 14/450. Subheadline scaling for secondary supporting text.
        static let bodyXS = Style(face: .regular, size: bodyXSSize, relativeTo: .subheadline)

        /// IOS/IOS Body XS Bold — 14/550. Shares the secondary-text scaling role.
        static let bodyXSEmphasized = Style(face: .medium, size: bodyXSSize, relativeTo: .subheadline)

        /// IOS/IOS Subtext XXS — 12/450. Caption scaling for timestamps and compact metadata.
        static let subtextXXS = Style(face: .regular, size: smallLabelSize, relativeTo: .caption)

        /// IOS/IOS Eyebrow — 12/450. Caption scaling for small group labels; no forced uppercase.
        static let eyebrow = Style(face: .regular, size: smallLabelSize, relativeTo: .caption)
    }
}

extension Constants.Typography {
    enum Face: String {
        case regular = "Inter-Regular"
        case medium = "Inter-Medium"
        case semibold = "Inter-SemiBold"
        case bold = "Inter-Bold"
        case extraBold = "Inter-ExtraBold"
        case italic = "Inter-Italic"
        case mediumItalic = "Inter-MediumItalic"
        case semiboldItalic = "Inter-SemiBoldItalic"
        case boldItalic = "Inter-BoldItalic"
        case extraBoldItalic = "Inter-ExtraBoldItalic"

        /// Accessibility emphasis is separate from the documented Figma “Bold” tokens.
        var legibleFace: Self {
            switch self {
            case .regular: .semibold
            case .medium, .semibold: .bold
            case .bold, .extraBold: .extraBold
            case .italic: .semiboldItalic
            case .mediumItalic, .semiboldItalic: .boldItalic
            case .boldItalic, .extraBoldItalic: .extraBoldItalic
            }
        }
    }

    struct Style {
        let face: Face
        let size: CGFloat
        let relativeTo: Font.TextStyle

        /// SwiftUI resolves scaling from the current environment; no fixed size or category cap.
        var font: Font {
            .custom(face.rawValue, size: size, relativeTo: relativeTo)
        }

        func font(legibilityWeight: LegibilityWeight?) -> Font {
            withFace(legibilityWeight == .bold ? face.legibleFace : face).font
        }

        /// Preserve the size and scaling role when genuine bold/italic is required.
        func withFace(_ face: Face) -> Self {
            Self(face: face, size: size, relativeTo: relativeTo)
        }
    }
}
