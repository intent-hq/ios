@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
struct WorkspaceSyntaxThemeTests {
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func dottedScopesInheritAndUnknownScopesUseLabel(style: UIUserInterfaceStyle) {
        let traits = UITraitCollection(userInterfaceStyle: style)
        for (scope, parent) in [("title.function", "title"), ("title.class.inherited", "title"), ("variable.language", "variable")] {
            #expect(WorkspaceSyntaxTheme.color(for: scope).resolvedColor(with: traits)
                == WorkspaceSyntaxTheme.color(for: parent).resolvedColor(with: traits))
        }
        for scope in ["", "unknown", "unknown.child", "subst"] {
            #expect(WorkspaceSyntaxTheme.color(for: scope).resolvedColor(with: traits) == UIColor.label.resolvedColor(with: traits))
        }
    }

    @Test func paletteAdaptsWithoutRecreatingTheColors() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let scopes = ["keyword", "string", "comment", "number", "title", "type"]
        let colors = scopes.map { WorkspaceSyntaxTheme.color(for: $0) }
        for color in colors {
            #expect(color.resolvedColor(with: light) != color.resolvedColor(with: dark))
        }
        for traits in [light, dark] {
            let resolved = colors.map { $0.resolvedColor(with: traits) }
            #expect(Set(resolved).count == scopes.count)
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func syntaxStaysReadableOnFileAndDiffBackgrounds(scheme: ColorScheme) throws {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let canvas = try components(UIColor(WorkspaceDetailStyle.background(for: scheme)), traits: traits)
        let backgrounds = try [Color.clear, .green, .red].map { tint in
            let overlay = try components(UIColor(tint.opacity(WorkspaceChangesLayout.diffTintOpacity)), traits: traits)
            return zip(overlay.rgb, canvas.rgb).map { $0 * overlay.alpha + $1 * (1 - overlay.alpha) }
        }
        for scope in ["keyword", "string", "comment", "number", "title", "type", "unknown"] {
            let foreground = try components(WorkspaceSyntaxTheme.color(for: scope), traits: traits)
            #expect(foreground.alpha == 1)
            for background in backgrounds {
                let values = [luminance(foreground.rgb), luminance(background)].sorted()
                #expect((values[1] + 0.05) / (values[0] + 0.05) >= 4.5)
            }
        }
    }

    private func components(_ color: UIColor, traits: UITraitCollection) throws -> (rgb: [CGFloat], alpha: CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        try #require(color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return ([red, green, blue], alpha)
    }

    private func luminance(_ rgb: [CGFloat]) -> CGFloat {
        let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return zip(linear, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
