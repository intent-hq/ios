import Foundation
import Testing

/// The Intent target builds with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
/// The SDK imports the block parameters of the APIs below as plain
/// non-Sendable function types, so a closure literal passed to them is
/// silently inferred MainActor-isolated (SE-0434 permits this — no compiler
/// setting diagnoses it) and the process aborts with
/// `_dispatch_assert_queue_fail` when the framework invokes the closure off
/// the main thread. The crash is device-only; the simulator never reproduces
/// it. Fixed instance: 09c22b6 (SpeechDictationController). This test is the
/// registry of known thread-hopping callback APIs and the guard that keeps
/// their closures explicitly `@Sendable`.
struct ObjCCallbackIsolationTests {
    /// Known thread-hopping ObjC callback APIs. A call site passes only if
    /// its closure literal opens with `{ @Sendable` or the call is `await`-ed
    /// (async overloads hop isolation correctly). The AVCapture* delegate
    /// setters take delegate objects, not closures, so any use fails here by
    /// design: audit the delegate's isolation, then teach this test the
    /// audited pattern. Extend this table when adopting another ObjC API
    /// whose callback runs off the main thread.
    private static let threadHoppingCallbackAPIs = [
        "installTap(",                              // AVAudioNode — realtime audio thread
        "recognitionTask(with",                     // SFSpeechRecognizer — Speech-owned queue
        "SFSpeechRecognizer.requestAuthorization",  // arbitrary queue
        "AVAudioApplication.requestRecordPermission",  // arbitrary queue
        ".setSampleBufferDelegate(",                // AVCaptureVideoDataOutput
        ".setMetadataObjectsDelegate(",             // AVCaptureMetadataOutput
        ".addObserver(forName",                    // NotificationCenter — posting thread
        ".pathUpdateHandler =",                    // Network — connection/monitor queue
        ".viabilityUpdateHandler ="                // NWConnection — connection queue
    ]

    /// How many lines below a match to search for the opening `{` of a
    /// call whose closure starts on a later line.
    private static let closureLookaheadLines = 5

    @Test func threadHoppingCallbackClosuresAreExplicitlySendable() throws {
        var violations: [String] = []
        let inputs = try TestBundleInputs.current()
        let files = try inputs.swiftFiles(under: "Intent")
        try #require(!files.isEmpty, "Intent/ contains no bundled Swift inputs")
        for file in files {
            let lines = try String(contentsOf: file.url, encoding: .utf8)
                .components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                for api in Self.threadHoppingCallbackAPIs {
                    guard let matchRange = line.range(of: api) else { continue }
                    guard !Self.callSiteIsSafe(lines: lines, lineIndex: index, matchRange: matchRange)
                    else { continue }
                    violations.append(
                        "\(file.path):\(index + 1): closure passed to `\(api)` must open "
                            + "with `{ @Sendable` (or the call must be awaited) — it is "
                            + "otherwise inferred MainActor-isolated and crashes on device "
                            + "when invoked off-main; see 09c22b6."
                    )
                }
            }
        }
        #expect(
            violations.isEmpty,
            "Thread-hopping ObjC callback call sites missing explicit @Sendable (see 09c22b6):\n\(violations.joined(separator: "\n"))"
        )
    }

    /// A match is safe when the call is `await`-ed, or the first closure
    /// literal opening after the matched API name begins with `@Sendable`.
    /// The `await` exemption only considers the matched call's own statement:
    /// text after the last `;` before the match, so an earlier semicolon-
    /// separated statement's `await` cannot mark the callback safe.
    private static func callSiteIsSafe(
        lines: [String],
        lineIndex: Int,
        matchRange: Range<String.Index>
    ) -> Bool {
        let line = lines[lineIndex]
        let assignment = line[matchRange.lowerBound...]
        if assignment.hasPrefix(".pathUpdateHandler =") || assignment.hasPrefix(".viabilityUpdateHandler =") {
            if assignment.split(separator: "=", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) == "nil" {
                return true
            }
        }
        let ownStatementPrefix = line[..<matchRange.lowerBound]
            .split(separator: ";", omittingEmptySubsequences: false).last ?? ""
        if ownStatementPrefix.contains("await ") { return true }

        var remainder = String(line[matchRange.lowerBound...])
        for offset in 0...closureLookaheadLines {
            if let braceIndex = remainder.firstIndex(of: "{") {
                let afterBrace = remainder[remainder.index(after: braceIndex)...]
                    .drop(while: \.isWhitespace)
                return afterBrace.hasPrefix("@Sendable")
            }
            let nextLine = lineIndex + offset + 1
            guard nextLine < lines.count else { break }
            remainder = lines[nextLine]
        }
        return false
    }
}
