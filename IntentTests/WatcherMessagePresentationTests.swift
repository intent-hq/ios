import Foundation
@testable import Intent
import Testing

struct WatcherMessagePresentationTests {
    @Test func summarizesJobsWithoutTreatingAnUnfinishedRunAsPassed() throws {
        let text = #"iOS Mermaid validation: {"conclusion":"","jobs":["#
            + #"{"name":"Build","conclusion":"","status":"in_progress"},"#
            + #"{"name":"SwiftLint","conclusion":"failure","status":"completed","steps":[{"name":"Lint","conclusion":"failure"}]},"#
            + #"{"name":"Tests","conclusion":"success","status":"completed"}]}"#
        let result = WatcherMessagePresentation(text: text)
        #expect(result.summary == "iOS Mermaid validation:")
        #expect(result.checks == [
            .init(name: "SwiftLint", status: "failure"),
            .init(name: "Build", status: "in_progress"),
            .init(name: "Tests", status: "success")
        ])
        #expect(result.checks.first?.needsAttention == true)
        let details = try #require(result.details)
        let decoded = try JSONSerialization.jsonObject(with: Data(details.utf8)) as? [String: Any]
        let jobs = try #require(decoded?["jobs"] as? [[String: Any]])
        #expect((jobs[1]["steps"] as? [[String: String]])?.first?["name"] == "Lint")
        #expect(details.contains("\n"))
    }

    @Test(arguments: ["```json", "```"])
    func recognizesFencedData(fence: String) throws {
        let result = WatcherMessagePresentation(text: "Build report\n\(fence)\n{\"value\": [1, true, null]}\n```")
        #expect(result.summary == "Build report")
        #expect(result.isJSON)
        let details = try #require(result.details)
        let decoded = try JSONSerialization.jsonObject(with: Data(details.utf8)) as? [String: Any]
        #expect((decoded?["value"] as? [Any])?.count == 3)
    }

    @Test func preservesUnknownObjectsArraysAndEscapedStrings() throws {
        let text = #"[CI] Result: {"message":"Quoted \"value\" and braces {[]}","url":"https://example.com/run","unknown":[{"code":42}]}"#
        let result = WatcherMessagePresentation(text: text)
        #expect(result.summary == "[CI] Result:")
        #expect(result.checks.isEmpty)
        let details = try #require(result.details)
        #expect(details.contains("https://example.com/run"))
        let decoded = try JSONSerialization.jsonObject(with: Data(details.utf8)) as? [String: Any]
        #expect(decoded?["message"] as? String == "Quoted \"value\" and braces {[]}")
        #expect(WatcherMessagePresentation(text: "[1, 2]").summary == "Watcher update")
        #expect(WatcherMessagePresentation(text: "{}").isJSON)
    }

    @Test func preservesShortProseAndMalformedData() {
        for text in ["Checks passed.", "Build report: {\"jobs\":", "[CI] finished", "", "123", "null"] {
            let result = WatcherMessagePresentation(text: text)
            #expect(result.summary == text)
            #expect(result.details == nil)
            #expect(!result.isJSON)
        }
    }

    @Test func keepsLongAndMultilineFallbacksAvailableInFull() {
        for text in [String(repeating: "A long report. ", count: 100), "One\nTwo\nThree\nFour\nFive"] {
            let result = WatcherMessagePresentation(text: text)
            #expect(result.summary.count < text.count)
            #expect(result.summary.hasSuffix("…"))
            #expect(result.details == text)
            #expect(!result.isJSON)
        }
    }

    @Test func boundsParsingOfLargePayloads() {
        let text = "{\"log\":\"" + String(repeating: "x", count: 300_000) + "\"}"
        let result = WatcherMessagePresentation(text: text)
        #expect(!result.isJSON)
        #expect(result.details == text)
    }

    @Test func missingAndUnknownJobStatusesStayNeutral() {
        let text = #"{"jobs":[{"name":"Unknown"},{"name":"Future","status":"some_new_state"},"#
            + #"{"name":"Done","status":"completed","conclusion":null},{"name":"  "},{"status":"success"}]}"#
        let result = WatcherMessagePresentation(text: text)
        #expect(result.checks.map(\.label) == ["Status unknown", "Some New State", "Completed"])
        #expect(result.checks.allSatisfy { !$0.needsAttention })
    }

    @Test func attentionStatusesOverrideCompletedStatus() {
        for status in ["failure", "timed_out", "action_required", "startup_failure"] {
            let result = WatcherMessagePresentation(text: "{\"jobs\":[{\"name\":\"Check\",\"status\":\"completed\",\"conclusion\":\"\(status)\"}]}")
            #expect(result.checks.first?.needsAttention == true)
            #expect(result.checks.first?.status == status)
        }
    }

    @Test func copyStillIncludesOriginalWatcherPayload() throws {
        let attribution = try #require(HookWakeAttribution.from([
            "type": AnyCodable("hook_wake"), "hookName": AnyCodable("CI")
        ]))
        let payload = #"Build: {"jobs":[{"name":"Lint","conclusion":"failure"}]}"#
        let text = "[Background hook \"CI\"] \(payload)\n\n[This hook has retired.]"
        let blocks = [ContentBlock(type: .text, text: text)]
        #expect(MessageBlockPartitioning.userCopyText(from: blocks, hookWake: attribution) == payload)
        #expect(WatcherMessagePresentation(text: HookWakeAttribution.displayText(text, attribution: attribution)).isJSON)
    }
}
