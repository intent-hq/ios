import Foundation
import Testing
import UIKit

struct InterFontTests {
    nonisolated private static let postScriptNames = [
        "Inter-Thin", "Inter-ThinItalic",
        "Inter-ExtraLight", "Inter-ExtraLightItalic",
        "Inter-Light", "Inter-LightItalic",
        "Inter-Regular", "Inter-Italic",
        "Inter-Medium", "Inter-MediumItalic",
        "Inter-SemiBold", "Inter-SemiBoldItalic",
        "Inter-Bold", "Inter-BoldItalic",
        "Inter-ExtraBold", "Inter-ExtraBoldItalic",
        "Inter-Black", "Inter-BlackItalic"
    ]

    @Test func appDeclaresEveryStaticFace() throws {
        let declaredFonts = try #require(Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String])
        let expectedFiles = Self.postScriptNames.map { "\($0).ttf" }
        #expect(declaredFonts.sorted() == expectedFiles.sorted())
    }

    @Test(arguments: postScriptNames)
    func fontLoadsByPostScriptNameWithoutFallback(_ postScriptName: String) throws {
        let font = try #require(UIFont(name: postScriptName, size: 17), "\(postScriptName) is not registered")
        #expect(font.fontName == postScriptName)

        let url = Bundle.main.bundleURL.appending(path: "\(postScriptName).ttf")
        let provider = try #require(CGDataProvider(url: url as CFURL), "Missing font resource: \(url.lastPathComponent)")
        let bundledFont = try #require(CGFont(provider))
        #expect(bundledFont.postScriptName as String? == postScriptName)
    }

    @Test func appIncludesInterLicense() throws {
        let url = try #require(Bundle.main.url(forResource: "Inter-LICENSE", withExtension: "txt"))
        let license = try String(contentsOf: url, encoding: .utf8)
        #expect(license.contains("Copyright (c) 2016 The Inter Project Authors"))
        #expect(license.contains("SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007"))
    }
}
