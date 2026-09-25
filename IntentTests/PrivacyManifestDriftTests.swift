import Foundation
import Testing

/// Keeps Intent/PrivacyInfo.xcprivacy in step with the required-reason APIs
/// the production sources actually call (ios#381). Reading the system boot
/// time — `ProcessInfo.systemUptime` or `mach_absolute_time()` — obliges the
/// manifest to declare `NSPrivacyAccessedAPICategorySystemBootTime` with an
/// approved reason; the transcript scroll timing measures elapsed time
/// between in-app events, which is reason `35F9.1`. A declaration with no
/// remaining caller is stale and fails too. The scan reads the copy of
/// Intent/ packaged into the test bundle (see TestSourceInputs), not the
/// checkout; IntentTests/ is not scanned because test code does not ship.
/// Comments and string literals are blanked before matching so a mention of
/// an API in prose cannot stand in for a call; a literal that interpolates an
/// expression is kept whole, because the expression is code.
struct PrivacyManifestDriftTests {
    private static let manifestPath = "Intent/PrivacyInfo.xcprivacy"
    private static let systemBootTimeCategory = "NSPrivacyAccessedAPICategorySystemBootTime"
    private static let elapsedTimeReasons = ["35F9.1"]
    private static let systemBootTimeAPI = #"\b(systemUptime|mach_absolute_time)\b"#
    /// Multi-line string literal, single-line string literal, block comment,
    /// line comment — leftmost match wins, so `//` inside a string stays a
    /// string and a quote inside a comment stays a comment.
    private static let commentOrStringLiteral = #""""[\s\S]*?"""|"(?:\\.|[^"\\\n])*"|/\*[\s\S]*?\*/|//[^\n]*"#
    /// `\(` in an ordinary literal, `\#(` / `\##(` … in a raw one.
    private static let interpolationStart = ##"\\#*\("##

    /// `source` with every comment and string literal replaced by a space,
    /// leaving only the tokens the compiler treats as code. A string literal
    /// containing an interpolation is retained unchanged so a call made
    /// inside it still counts.
    private func codeOnly(_ source: String) throws -> String {
        let regex = try NSRegularExpression(pattern: Self.commentOrStringLiteral)
        var code = ""
        var cursor = source.startIndex
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let range = try #require(Range(match.range, in: source), "lexeme range does not map into the source")
            code += source[cursor..<range.lowerBound]
            let lexeme = source[range]
            if lexeme.hasPrefix("\""),
               lexeme.range(of: Self.interpolationStart, options: .regularExpression) != nil {
                code += lexeme
            } else {
                code += " "
            }
            cursor = range.upperBound
        }
        code += source[cursor...]
        return code
    }

    /// `NSPrivacyAccessedAPIType` → `NSPrivacyAccessedAPITypeReasons` for
    /// every entry of the manifest's `NSPrivacyAccessedAPITypes` array.
    private func accessedAPIReasons(in manifestURL: URL) throws -> [String: [String]] {
        let data = try Data(contentsOf: manifestURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let root = try #require(plist as? [String: Any], "privacy manifest is not a dictionary plist")
        let entries = try #require(
            root["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
            "privacy manifest has no NSPrivacyAccessedAPITypes array"
        )
        var reasons: [String: [String]] = [:]
        for entry in entries {
            let type = try #require(
                entry["NSPrivacyAccessedAPIType"] as? String,
                "NSPrivacyAccessedAPITypes entry has no NSPrivacyAccessedAPIType string"
            )
            #expect(reasons[type] == nil, "privacy manifest declares \(type) more than once")
            reasons[type] = try #require(
                entry["NSPrivacyAccessedAPITypeReasons"] as? [String],
                "\(type) has no NSPrivacyAccessedAPITypeReasons string array"
            )
        }
        return reasons
    }

    /// Paths relative to `repoRoot` of .swift files under its Intent/ whose
    /// code (comments and string literals excluded) matches the regex `pattern`.
    private func productionFilesContaining(
        _ pattern: String, under repoRoot: URL = TestSourceInputs.root
    ) throws -> Set<String> {
        let root = repoRoot.appendingPathComponent("Intent")
        var isDirectory: ObjCBool = false
        try #require(
            FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            """
            scan root Intent/ is missing or not a directory at \(root.path); check the \
            IntentTests target's "Copy Test Source Inputs" phase in Intent.xcodeproj.
            """
        )
        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]),
            "failed to enumerate Intent/"
        )
        let rootPrefix = repoRoot.standardizedFileURL.path + "/"
        var matches: Set<String> = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            let code = try codeOnly(String(contentsOf: url, encoding: .utf8))
            guard code.range(of: pattern, options: .regularExpression) != nil else { continue }
            let absolute = url.standardizedFileURL.path
            try #require(absolute.hasPrefix(rootPrefix), "scanned file \(absolute) is not under \(rootPrefix)")
            matches.insert(String(absolute.dropFirst(rootPrefix.count)))
        }
        return matches
    }

    @Test func systemBootTimeCallersMatchTheManifestDeclaration() throws {
        let callers = try productionFilesContaining(Self.systemBootTimeAPI).sorted()
        let declared = try accessedAPIReasons(in: TestSourceInputs.url(for: Self.manifestPath))
        let reasons = declared[Self.systemBootTimeCategory]
        if callers.isEmpty {
            #expect(
                reasons == nil,
                """
                \(Self.manifestPath) declares \(Self.systemBootTimeCategory) but no production \
                source reads the system boot time any more; remove the stale entry.
                """
            )
        } else {
            #expect(
                reasons == Self.elapsedTimeReasons,
                """
                Production sources read the system boot time (\(callers)) but \
                \(Self.manifestPath) declares \(Self.systemBootTimeCategory) with reasons \
                \(reasons ?? []) instead of \(Self.elapsedTimeReasons). Declare the category \
                with the approved reason that describes the use, or update this test if a \
                different approved reason now applies.
                """
            )
        }
    }

    /// Negative case: the scan reports every production Swift caller of either
    /// system-boot-time API and nothing else (no test code, no non-Swift
    /// files, no other clocks, no mention in a comment or string literal), and
    /// the manifest reader returns each declared
    /// category's reasons — so a match above is evidence of the tree's
    /// contents rather than of an empty scan or an unread manifest.
    @Test func scanAndManifestReaderReportFixtureContents() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivacyManifestDrift-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        for (path, contents) in Self.fixtureFiles {
            let url = fixture.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        #expect(
            try productionFilesContaining(Self.systemBootTimeAPI, under: fixture)
                == [
                    "Intent/Nested/Uptime.swift", "Intent/Mach.swift", "Intent/StringThenCall.swift",
                    "Intent/Interpolation.swift", "Intent/RawInterpolation.swift"
                ]
        )
        #expect(
            try accessedAPIReasons(in: fixture.appendingPathComponent(Self.manifestPath)) == [
                "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
                Self.systemBootTimeCategory: ["35F9.1", "8FFB.1"]
            ]
        )
    }

    /// Path → contents of the fixture tree the negative case writes and scans.
    private static let fixtureFiles = [
        "Intent/Nested/Uptime.swift": "let now = ProcessInfo.processInfo.systemUptime\n",
        "Intent/Mach.swift": "let ticks = mach_absolute_time()\n",
        "Intent/Clean.swift": "let now = ContinuousClock.now\nlet media = CACurrentMediaTime()\n",
        "Intent/Prefix.swift": "let notTheAPI = systemUptimeSnapshot\n",
        "Intent/Prose.swift": """
        // systemUptime used to be read here (ios#381).
        /* mach_absolute_time() is
           the other boot-time API */
        let label = "systemUptime"
        let url = "https://example.com/systemUptime // not a comment"
        let doc = \"\"\"
            mach_absolute_time()
            \"\"\"
        let now = ContinuousClock.now

        """,
        "Intent/StringThenCall.swift": "let label = \"systemUptime\" // note\nlet now = ProcessInfo.processInfo.systemUptime\n",
        "Intent/Interpolation.swift": "let label = \"uptime: \\(ProcessInfo.processInfo.systemUptime)\"\n",
        "Intent/RawInterpolation.swift": """
        let raw = #"uptime: \\#(ProcessInfo.processInfo.systemUptime)"#
        let rawRaw = ##"uptime: \\##(ProcessInfo.processInfo.systemUptime)"##

        """,
        "Intent/Notes.txt": "systemUptime\n",
        "IntentTests/UptimeTests.swift": "let now = ProcessInfo.processInfo.systemUptime\n",
        manifestPath: """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>NSPrivacyAccessedAPITypes</key><array>
        <dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryUserDefaults</string>
        <key>NSPrivacyAccessedAPITypeReasons</key><array><string>CA92.1</string></array></dict>
        <dict><key>NSPrivacyAccessedAPIType</key><string>\(systemBootTimeCategory)</string>
        <key>NSPrivacyAccessedAPITypeReasons</key><array><string>35F9.1</string><string>8FFB.1</string></array></dict>
        </array></dict></plist>
        """
    ]
}
