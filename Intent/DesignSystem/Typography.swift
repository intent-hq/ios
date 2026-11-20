import SwiftUI

extension Constants {
    nonisolated enum Typography {
        private static let heading1Size: CGFloat = 40
        private static let heading2Size: CGFloat = 28
        private static let bodyMSize: CGFloat = 18
        private static let bodySSize: CGFloat = 16
        private static let bodyXSSize: CGFloat = 14
        private static let smallLabelSize: CGFloat = 12

        static let heading1 = Style(face: .semibold, size: heading1Size, relativeTo: .largeTitle)

        static let heading2 = Style(face: .semibold, size: heading2Size, relativeTo: .title)

        static let bodyM = Style(face: .medium, size: bodyMSize, relativeTo: .headline)

        static let bodyS = Style(face: .regular, size: bodySSize, relativeTo: .body)

        static let bodySEmphasized = Style(face: .medium, size: bodySSize, relativeTo: .body)

        static let bodyXS = Style(face: .regular, size: bodyXSSize, relativeTo: .subheadline)

        static let bodyXSEmphasized = Style(face: .medium, size: bodyXSSize, relativeTo: .subheadline)

        static let subtextXXS = Style(face: .regular, size: smallLabelSize, relativeTo: .caption)

        static let eyebrow = Style(face: .regular, size: smallLabelSize, relativeTo: .caption)
    }
}

extension Constants.Typography {
    nonisolated enum Face: String {
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

    nonisolated struct Style {
        let face: Face
        let size: CGFloat
        let relativeTo: Font.TextStyle

        var font: Font {
            .custom(face.rawValue, size: size, relativeTo: relativeTo)
        }

        func font(legibilityWeight: LegibilityWeight?) -> Font {
            withFace(legibilityWeight == .bold ? face.legibleFace : face).font
        }

        func withFace(_ face: Face) -> Self {
            Self(face: face, size: size, relativeTo: relativeTo)
        }
    }
}
