import MarkdownUI
import SwiftUI

extension MarkdownUI.Theme {
    static let compact = MarkdownUI.Theme()
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.94))
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 8, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(17)
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 8, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(16)
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 6, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(15)
                }
        }
        .heading4 { configuration in
            configuration.label
                .markdownMargin(top: 6, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.medium)
                    FontSize(15)
                }
        }
        .heading5 { configuration in
            configuration.label
                .markdownMargin(top: 4, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.medium)
                    FontSize(15)
                }
        }
        .heading6 { configuration in
            configuration.label
                .markdownMargin(top: 4, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.medium)
                    FontSize(15)
                }
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.15))
                .markdownMargin(top: .zero, bottom: .em(1))
        }
        .blockquote { configuration in
            configuration.label
                .markdownTextStyle {
                    FontStyle(.italic)
                }
                .relativePadding(.leading, length: .em(2))
                .relativePadding(.trailing, length: .em(1))
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.15))
                    .relativePadding(.leading, length: .rem(1))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.94))
                    }
            }
            .markdownMargin(top: .zero, bottom: .em(1))
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: .zero, bottom: .em(1))
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(15)
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.15))
                .relativePadding(.horizontal, length: .em(0.72))
                .relativePadding(.vertical, length: .em(0.35))
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 2, bottom: 4)
        }
        .thematicBreak {
            Divider().markdownMargin(top: .em(2), bottom: .em(2))
        }
}

