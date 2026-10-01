import Foundation
import Testing

/// Enforces AGENTS.md's layout policy independently of suppressible lint rules.
/// Tokens in fixtures and patterns are split so this source passes its own scan.
struct LayoutPolicyTests {
    private static let reader = "Geometry" + "Reader"
    private static let suppression =
        #"\bswiftlint:"# + #"disable(?::(?:next|this|previous))?\b[^\r\n]*\bgeometry_reader_usage\b"#

    private func filesViolatingPolicy(under root: URL = TestSourceInputs.root) throws -> Set<String> {
        var violations: Set<String> = []
        let rootPrefix = root.standardizedFileURL.path + "/"
        for directory in ["Intent", "IntentTests", "IntentUITests"] {
            let sourceRoot = root.appendingPathComponent(directory)
            var isDirectory: ObjCBool = false
            try #require(
                FileManager.default.fileExists(atPath: sourceRoot.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue,
                "Missing source directory \(directory); check the Copy Test Source Inputs phase."
            )
            let enumerator = try #require(
                FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: [.isRegularFileKey]),
                "Failed to enumerate \(directory)."
            )
            var scannedFiles = 0
            for case let url as URL in enumerator {
                guard url.pathExtension == "swift" else { continue }
                let contents = try String(contentsOf: url, encoding: .utf8)
                scannedFiles += 1
                guard contents.contains(Self.reader)
                    || contents.range(of: Self.suppression, options: .regularExpression) != nil else { continue }
                let absolute = url.standardizedFileURL.path
                try #require(absolute.hasPrefix(rootPrefix), "Source file is outside the packaged tree: \(absolute)")
                violations.insert(String(absolute.dropFirst(rootPrefix.count)))
            }
            try #require(scannedFiles > 0, "No Swift sources found under \(directory); check the packaged inputs.")
        }
        return violations
    }

    @Test func sourcesRespectLayoutPolicy() throws {
        let violations = try filesViolatingPolicy()
        #expect(
            violations.isEmpty,
            """
            Layout policy violations: \(violations.sorted()).
            Remove \(Self.reader) and any disable comments for geometry_reader_usage.
            Use onGeometryChange, containerRelativeFrame, Shape.path(in:), or a custom Layout instead.
            """
        )
    }

    @Test func scanDetectsUsageAndSuppressionsAcrossAllSourceTrees() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayoutPolicyScan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let reader = Self.reader + " { _ in EmptyView() }"
        let disable = "// swiftlint:" + "disable"
        let rule = "geometry_reader_usage"
        let files = [
            "Intent/Nested/Reader.swift": reader,
            "Intent/Suppressed.swift": "\(disable):next \(rule)\n\(reader)",
            "IntentTests/Global.swift": "\(disable) \(rule)",
            "IntentTests/Next.swift": "\(disable):next \(rule)",
            "IntentTests/This.swift": "let value = 1 \(disable):this \(rule)",
            "IntentUITests/Previous.swift": "\(disable):previous \(rule)",
            "IntentUITests/Multiple.swift": "\(disable) identifier_name \(rule) line_length",
            "IntentUITests/Block.swift": "/* swiftlint:" + "disable \(rule) */",
            "Intent/Clean.swift": "Color.clear.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in }",
            "IntentTests/OtherRule.swift": "\(disable) identifier_name",
            "IntentUITests/Enabled.swift": "// swiftlint:enable \(rule)",
            "IntentUITests/NotSwift.txt": reader
        ]
        for (path, contents) in files {
            let url = fixture.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        #expect(try filesViolatingPolicy(under: fixture) == [
            "Intent/Nested/Reader.swift",
            "Intent/Suppressed.swift",
            "IntentTests/Global.swift",
            "IntentTests/Next.swift",
            "IntentTests/This.swift",
            "IntentUITests/Previous.swift",
            "IntentUITests/Multiple.swift",
            "IntentUITests/Block.swift"
        ])
    }
}
