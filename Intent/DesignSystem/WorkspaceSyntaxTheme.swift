import UIKit

/// Shared, opaque foreground colors for file text and lightly tinted diff rows.
enum WorkspaceSyntaxTheme {
    /// Dotted scopes inherit the closest known parent; unstyled scopes use label.
    static func color(for scope: String) -> UIColor {
        var candidate = scope
        while !candidate.isEmpty {
            if let color = colors[candidate] { return color }
            guard let separator = candidate.lastIndex(of: ".") else { break }
            candidate = String(candidate[..<separator])
        }
        return .label
    }

    // Named sRGB pairs keep at least 4.5:1 contrast on the file canvas and the
    // existing 12% red/green diff overlays in both appearances.
    // swiftlint:disable no_magic_numbers
    private static let keyword = adaptive(light: 0x6F2C91, dark: 0xDFB4FF)
    private static let string = adaptive(light: 0x215E35, dark: 0xA4D6A0)
    private static let comment = adaptive(light: 0x515960, dark: 0xACB6BF)
    private static let number = adaptive(light: 0x854112, dark: 0xF3C18B)
    private static let title = adaptive(light: 0x1B4F91, dark: 0xA9CFFF)
    private static let type = adaptive(light: 0x13656B, dark: 0x92D4D9)
    // swiftlint:enable no_magic_numbers

    private static let colors: [String: UIColor] = [
        "keyword": keyword, "meta": keyword, "doctag": keyword,
        "string": string, "regexp": string, "addition": string,
        "comment": comment, "quote": comment,
        "number": number, "literal": number, "symbol": number, "bullet": number, "deletion": number,
        "title": title, "name": title, "tag": title, "section": title, "link": title,
        "type": type, "built_in": type, "attr": type, "attribute": type, "variable": type,
        "selector-tag": title, "selector-id": title, "selector-class": title,
        "selector-pseudo": keyword, "selector-attr": type
    ]

    private static func adaptive(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            // Extract literal 8-bit sRGB channels; keep the result fully opaque.
            // swiftlint:disable no_magic_numbers
            return UIColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
            // swiftlint:enable no_magic_numbers
        }
    }
}
