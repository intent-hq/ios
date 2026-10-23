import CryptoKit
import Foundation
@testable import Intent
import Testing

/// `SuggestedPrompts` checked against the suggested-prompts block cases shared
/// with the desktop app and the daemon (monorepo
/// `docs/protocol/suggested-prompts.md`). The cases are an exact-byte copy
/// under `IntentTests/Fixtures/suggested-prompts/`; CI verifies the copy
/// against the monorepo commit named in `suggested-prompts.lock.json`, so an
/// expected value only changes by re-exporting it from the monorepo.
struct SuggestedPromptsContractTests {
    private static let consumer = "ios"
    private static let casesPath = "suggested-prompts/v1/cases.json"
    private static let lockPath = "suggested-prompts.lock.json"

    private struct Case {
        let id: String
        let input: String
        let prompts: [String]
        let cleaned: String
        let divergence: String?
    }

    private func fixture(_ path: String) throws -> Data {
        try Data(contentsOf: TestSourceInputs.url(for: "IntentTests/Fixtures").appendingPathComponent(path))
    }

    private func cases() throws -> [Case] {
        let doc = try #require(JSONSerialization.jsonObject(with: fixture(Self.casesPath)) as? [String: Any])
        #expect(doc["fixtureFormatVersion"] as? Int == 1)
        let rows = try #require(doc["cases"] as? [[String: Any]])
        return try rows.map { row in
            let expect = try #require(row["expect"] as? [String: Any])
            let divergences = row["divergences"] as? [String: String]
            return Case(
                id: try #require(row["id"] as? String),
                input: try #require(row["input"] as? String),
                prompts: try #require(expect["prompts"] as? [String]),
                cleaned: try #require(expect["cleaned"] as? String),
                divergence: divergences?[Self.consumer]
            )
        }
    }

    /// The contract's comparison form: CRLF as LF, trimmed, runs of 3+ line
    /// feeds collapsed to 2.
    static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var newlines = 0
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
        for scalar in unified.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            newlines = scalar == "\n" ? newlines + 1 : 0
            if newlines <= 2 { scalars.append(scalar) }
        }
        return String(scalars)
    }

    @Test func copyMatchesItsLock() throws {
        let lock = try #require(JSONSerialization.jsonObject(with: fixture(Self.lockPath)) as? [String: Any])
        #expect(lock["sourceRepository"] as? String == "intent-hq/intent")
        #expect(lock["sourcePath"] as? String == "docs/protocol/fixtures/suggested-prompts/v1")
        let digest = SHA256.hash(data: try fixture(Self.casesPath)).map { String(format: "%02x", $0) }.joined()
        #expect(lock["casesSha256"] as? String == digest, "cases.json was edited without re-exporting it from the monorepo")
    }

    @Test func normalizeMatchesTheContract() {
        #expect(Self.normalize("  a\n\n\n\nb\n") == "a\n\nb")
        #expect(Self.normalize("a\nb\n\nc") == "a\nb\n\nc")
        #expect(Self.normalize("a\r\n\r\n\r\nb\r\n") == "a\n\nb")
    }

    @Test func matchesEverySharedCase() throws {
        let cases = try cases()
        #expect(cases.count >= 40)
        for testCase in cases {
            let prompts = SuggestedPrompts.parse(testCase.input)
            let cleaned = Self.normalize(SuggestedPrompts.stripBlocks(from: testCase.input))
            let matches = prompts == testCase.prompts && cleaned == testCase.cleaned
            if let reason = testCase.divergence {
                #expect(!matches, "\(testCase.id): listed as an iOS divergence (\(reason)) but now matches; remove the entry")
            } else {
                #expect(prompts == testCase.prompts, "\(testCase.id): prompts")
                #expect(cleaned == testCase.cleaned, "\(testCase.id): cleaned text")
            }
        }
    }
}
