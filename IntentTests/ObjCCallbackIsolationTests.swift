import Foundation
import Testing

struct ObjCCallbackIsolationTests {
    private static let threadHoppingCallbackAPIs = [
        "installTap(",
        "recognitionTask(with",
        "SFSpeechRecognizer.requestAuthorization",
        "AVAudioApplication.requestRecordPermission",
        ".setSampleBufferDelegate(",
        ".setMetadataObjectsDelegate(",
        ".addObserver(forName",
        ".pathUpdateHandler =",
        ".viabilityUpdateHandler =",
        ".stateUpdateHandler =",
        "sec_protocol_options_set_verify_block(",
        ".completionWithItemsHandler ="
    ]

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
                            + "with `{ @Sendable`, even in a nonisolated helper (or the call must be awaited) — "
                            + "otherwise moving it into a MainActor context can cause a crash "
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

    private static func callSiteIsSafe(
        lines: [String],
        lineIndex: Int,
        matchRange: Range<String.Index>
    ) -> Bool {
        let line = lines[lineIndex]
        let assignment = line[matchRange.lowerBound...]
        if assignment.hasPrefix(".pathUpdateHandler =")
            || assignment.hasPrefix(".viabilityUpdateHandler =")
            || assignment.hasPrefix(".stateUpdateHandler =") {
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
