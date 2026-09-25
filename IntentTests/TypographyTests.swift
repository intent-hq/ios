@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
struct TypographyTests {
    private struct Fixture {
        let style: Constants.Typography.Style
        let fontName: String
        let size: CGFloat
        let role: Font.TextStyle
    }

    private static let fixtures: [Fixture] = [
        Fixture(style: Constants.Typography.heading1, fontName: "Inter-SemiBold", size: 40, role: .largeTitle),
        Fixture(style: Constants.Typography.heading2, fontName: "Inter-SemiBold", size: 28, role: .title),
        Fixture(style: Constants.Typography.bodyM, fontName: "Inter-Medium", size: 18, role: .headline),
        Fixture(style: Constants.Typography.bodyS, fontName: "Inter-Regular", size: 16, role: .body),
        Fixture(style: Constants.Typography.bodySEmphasized, fontName: "Inter-Medium", size: 16, role: .body),
        Fixture(style: Constants.Typography.bodyXS, fontName: "Inter-Regular", size: 14, role: .subheadline),
        Fixture(style: Constants.Typography.bodyXSEmphasized, fontName: "Inter-Medium", size: 14, role: .subheadline),
        Fixture(style: Constants.Typography.subtextXXS, fontName: "Inter-Regular", size: 12, role: .caption),
        Fixture(style: Constants.Typography.eyebrow, fontName: "Inter-Regular", size: 12, role: .caption)
    ]

    @Test func tokensUseApprovedFacesSizesAndSemanticRoles() throws {
        for fixture in Self.fixtures {
            #expect(fixture.style.face.rawValue == fixture.fontName)
            #expect(fixture.style.size == fixture.size)
            #expect(fixture.style.relativeTo == fixture.role)
            #expect(fixture.style.font == .custom(fixture.fontName, size: fixture.size, relativeTo: fixture.role))

            // Exercise launch-time registration, not a test-only font registration path.
            let loadedFont = try #require(UIFont(name: fixture.style.face.rawValue, size: fixture.style.size))
            #expect(loadedFont.fontName == fixture.fontName)
            #expect(loadedFont.pointSize == fixture.size)
        }
    }

    @Test func largeCategoryRendersAtTheDesignSize() throws {
        for fixture in Self.fixtures {
            let actual = try renderedSize(font: fixture.style.font, category: .large)
            // The fixed font is only a measurement reference, never the production API.
            let reference = try renderedSize(
                font: .custom(fixture.fontName, fixedSize: fixture.size), category: .large
            )
            #expect(actual == reference)
        }
    }

    @Test func everyTokenActuallyScalesThroughAccessibilitySizes() throws {
        let categories: [DynamicTypeSize] = [.xSmall, .large, .xxxLarge, .accessibility1, .accessibility5]
        for fixture in Self.fixtures {
            var previous = CGSize.zero
            for category in categories {
                let actual = try renderedSize(font: fixture.style.font, category: category)
                #expect(actual.width > previous.width, "\(fixture.fontName) \(fixture.size) at \(category)")
                #expect(actual.height > previous.height, "\(fixture.fontName) \(fixture.size) at \(category)")
                previous = actual
            }
        }
    }

    @Test func textModifierHonorsBoldTextWithoutChangingTheScalingRole() throws {
        for fixture in Self.fixtures {
            let text = Text(verbatim: "Inter Typography Ag09")
            let regular = try renderedImage(text.interFont(fixture.style).environment(\.legibilityWeight, .regular))
            let bold = try renderedImage(text.interFont(fixture.style).environment(\.legibilityWeight, .bold))
            #expect(regular != bold, "Bold Text must visibly change \(fixture.fontName)")
            let reference = try renderedImage(text.font(.custom(fixture.fontName, size: fixture.size, relativeTo: fixture.role)))
            #expect(regular == reference)
            let accessible = try renderedSize(font: fixture.style.font(legibilityWeight: .bold), category: .accessibility5)
            let standard = try renderedSize(font: fixture.style.font(legibilityWeight: .bold), category: .large)
            #expect(accessible.width > standard.width)
            #expect(accessible.height > standard.height)
        }
    }

    @Test func inlineEmphasisUsesRealInterFaces() throws {
        let style = Constants.Typography.bodyS
        let text = Text(verbatim: "Inter Typography Ag09")
        let cases: [(Text, String)] = [
            (text.bold(), "Inter-Bold"),
            (text.italic(), "Inter-Italic"),
            (text.bold().italic(), "Inter-BoldItalic")
        ]
        for (emphasized, name) in cases {
            let actual = try renderedImage(emphasized.interFont(style))
            let reference = try renderedImage(text.font(.custom(name, size: 16, relativeTo: .body)))
            #expect(actual == reference, "Inline emphasis must render the bundled \(name) face")
        }
        let markdown = Text(try AttributedString(markdown: "Plain **bold** *italic*"))
        let explicit = Text("Plain \(Text("bold").bold()) \(Text("italic").italic())")
        #expect(try renderedImage(markdown.interFont(style)) == renderedImage(explicit.interFont(style)))
    }

    @Test func uiKitFontsKeepTheirFaceAndScaleWithCurrentTraits() {
        let normal = UITraitCollection(preferredContentSizeCategory: .large)
        let accessible = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        for fixture in Self.fixtures {
            let base = fixture.style.uiFont(compatibleWith: normal)
            let scaled = fixture.style.uiFont(compatibleWith: accessible)
            #expect(base.fontName == fixture.fontName)
            #expect(base.pointSize == fixture.size)
            #expect(scaled.fontName == fixture.fontName)
            #expect(scaled.pointSize > base.pointSize)
        }
        let traits = UITraitCollection(traitsFrom: [accessible, UITraitCollection(legibilityWeight: .bold)])
        let italic = Constants.Typography.bodyS.withFace(.italic).uiFont(compatibleWith: traits)
        #expect(italic.fontName == "Inter-SemiBoldItalic")
        #expect(italic.fontDescriptor.symbolicTraits.contains(.traitItalic))
        #expect(italic.pointSize > 16)
        let custom = Constants.Typography.Style(face: .boldItalic, size: 19, relativeTo: .title3)
        #expect(custom.uiFont(compatibleWith: normal).pointSize == 19)
        #expect(custom.uiFont(compatibleWith: normal).fontName == "Inter-BoldItalic")
    }

    private func renderedImage(_ view: some View) throws -> Data {
        let renderer = ImageRenderer(content: view.fixedSize().environment(\.dynamicTypeSize, .large))
        renderer.scale = 1
        return try #require(renderer.uiImage?.pngData())
    }

    private func renderedSize(font: Font, category: DynamicTypeSize) throws -> CGSize {
        // Measure the exact SwiftUI Font used by callers, not a parallel UIFontMetrics implementation.
        // Unconstrained, single-line text avoids wrapping/truncation masking changes in glyph size.
        let renderer = ImageRenderer(
            content: Text(verbatim: "Inter Typography Ag09")
                .font(font)
                .fixedSize()
                .environment(\.dynamicTypeSize, category)
        )
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return CGSize(width: image.width, height: image.height)
    }
}
