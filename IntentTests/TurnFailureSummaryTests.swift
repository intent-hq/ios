import Foundation
@testable import Intent
import Testing

struct TurnFailureSummaryTests {
    @Test func codexUsageLimitScreenshotReason() {
        // swiftlint:disable:next line_length
        let reason = #"internal error: session/prompt failed: JSON-RPC error -32603: Internal error: {"message":"You've hit your usage limit. Visit https://chatgpt.com/settings/usage to purchase more credits or try again at Nov 14th, 2026 8:07 AM.","codexErrorInfo":"usageLimitExceeded"}"#
        let summary = TurnFailureSummary(reason: reason)

        #expect(summary.category == .usageLimit)
        #expect(summary.title == "Usage limit reached")
        #expect(summary.message == "You've hit your usage limit. Visit https://chatgpt.com/settings/usage to purchase more credits or try again at Nov 14th, 2026 8:07 AM.")
        #expect(summary.retryHint == "try again at Nov 14th, 2026 8:07 AM")
        #expect(summary.linkURL == URL(string: "https://chatgpt.com/settings/usage"))
        #expect(summary.rawDetails == reason)
        let message = summary.message ?? ""
        #expect(!message.contains("{") && !message.contains("JSON-RPC") && !message.contains("-32603"))
    }

    @Test func claudeRateLimitErrorKind() {
        let reason = #"Internal error: {"errorKind":"rate_limit","message":"Claude usage limit reached for this period."}"#
        let summary = TurnFailureSummary(reason: reason)

        #expect(summary.category == .usageLimit)
        #expect(summary.message == "Claude usage limit reached for this period.")
        #expect(summary.retryHint == nil)
        #expect(summary.linkURL == nil)
    }

    @Test func dotResetsPhrasingKeepsProviderWording() {
        let summary = TurnFailureSummary(reason: "session/prompt failed: You've hit your limit · resets 3pm (America/New_York)")

        #expect(summary.category == .usageLimit)
        #expect(summary.message == "You've hit your limit · resets 3pm (America/New_York)")
        #expect(summary.retryHint == "resets 3pm (America/New_York)")
    }

    @Test func authenticationFailedErrorKind() {
        let reason = #"internal error: JSON-RPC error -32000: {"errorKind":"authentication_failed","message":"Invalid credentials. Run /login."}"#
        let summary = TurnFailureSummary(reason: reason)

        #expect(summary.category == .authentication)
        #expect(summary.title == "Sign-in required")
        #expect(summary.message == "Invalid credentials. Run /login.")
    }

    @Test func connectionResetIsNetwork() {
        let summary = TurnFailureSummary(reason: "internal error: read ECONNRESET")

        #expect(summary.category == .network)
        #expect(summary.title == "Connection lost")
        #expect(summary.message == "read ECONNRESET")
        #expect(summary.retryHint == nil)
    }

    @Test func malformedJSONStillYieldsMessageAndHints() {
        let reason = #"Internal error: {"message":"Rate limited, try again in 5 minutes.\nSorry","codexErrorInfo":"rateLimitExceeded""#
        let summary = TurnFailureSummary(reason: reason)

        #expect(summary.category == .usageLimit)
        #expect(summary.message == "Rate limited, try again in 5 minutes.\nSorry")
        #expect(summary.retryHint == "try again in 5 minutes")
        #expect(summary.rawDetails == reason)
    }

    @Test func malformedJSONWithoutMessageKeepsFullPeeledText() {
        let summary = TurnFailureSummary(reason: #"internal error: agent crashed {"code": 7,"#)

        #expect(summary.category == .generic)
        #expect(summary.message == #"agent crashed {"code": 7,"#)
    }

    @Test func proseBracesAreNotTreatedAsJSON() {
        let summary = TurnFailureSummary(reason: "Internal error: Invalid value {foo} for parameter bar")

        #expect(summary.category == .generic)
        #expect(summary.message == "Invalid value {foo} for parameter bar")
    }

    @Test func validJSONWithoutMessageFallsBackToStringFields() {
        let details = TurnFailureSummary(reason: #"Internal error: {"details":"Claude Code process exited with code 1"}"#)
        #expect(details.category == .generic)
        #expect(details.message == "Claude Code process exited with code 1")

        let errorType = TurnFailureSummary(reason: #"{"type":"error","error":{"type":"overloaded_error"}}"#)
        #expect(errorType.message == "overloaded_error")

        let nestedMessage = TurnFailureSummary(reason: #"{"error":{"type":"api_error","message":"Overloaded"}}"#)
        #expect(nestedMessage.message == "Overloaded")

        let stringError = TurnFailureSummary(reason: #"{"error":"bad gateway","code":502}"#)
        #expect(stringError.message == "bad gateway")
    }

    @Test func nonEmptyReasonNeverYieldsNilMessage() {
        let reasons = [
            #"{"code":7}"#, #"Internal error: {"code":7}"#, "{", "}", "{}", #"{"message":""}"#, "x {"
        ]
        for reason in reasons {
            #expect(TurnFailureSummary(reason: reason).message?.isEmpty == false, "reason: \(reason)")
        }
    }

    @Test func limitLikeTextOutsideIntentdPhrasingsIsNotUsageLimit() {
        let reasons = [
            "Disk quota exceeded (os error 122)",
            "Prompt is too long: context window limit reached",
            "Max turns limit reached",
            "rate limiting middleware misconfigured"
        ]
        for reason in reasons {
            #expect(TurnFailureSummary(reason: reason).category == .generic, "reason: \(reason)")
        }
    }

    @Test func intentdUsagePhrasingsAreUsageLimit() {
        let reasons = [
            "You've hit your session limit · resets 4am",
            "You've hit your weekly limit",
            "5-hour limit reached",
            "Weekly limit reached, upgrade for more",
            "Claude AI usage limit reached|1731600000"
        ]
        for reason in reasons {
            #expect(TurnFailureSummary(reason: reason).category == .usageLimit, "reason: \(reason)")
        }
    }

    @Test func nonConnectionTimeoutsAreNotNetwork() {
        #expect(TurnFailureSummary(reason: "Tool call timeout after 30s").category == .generic)
        #expect(TurnFailureSummary(reason: "Command timed out after 120s").category == .generic)
    }

    @Test func connectionLevelFailuresAreNetwork() {
        let reasons = ["connect ECONNREFUSED 127.0.0.1:443", "Connection timed out", "network timeout while streaming", "socket hang up"]
        for reason in reasons {
            #expect(TurnFailureSummary(reason: reason).category == .network, "reason: \(reason)")
        }
    }

    @Test func retryHintKeepsMeridiemAbbreviations() {
        #expect(TurnFailureSummary(reason: "Try again at 3 p.m. tomorrow").retryHint == "Try again at 3 p.m. tomorrow")
        #expect(TurnFailureSummary(reason: "Limit hit. Try again at 9 a.m. tomorrow. Thanks.").retryHint == "Try again at 9 a.m. tomorrow")
    }

    @Test func retryHintRequiresATimeOrDate() {
        #expect(TurnFailureSummary(reason: "Please try again in a moment.").retryHint == nil)
        #expect(TurnFailureSummary(reason: "Please try again later.").retryHint == nil)
        #expect(TurnFailureSummary(reason: "Please try again in a few seconds.").retryHint == "try again in a few seconds")
        #expect(TurnFailureSummary(reason: "Try again on Monday.").retryHint == "Try again on Monday")
    }

    @Test func plainTextIsGenericWithPeeledMessage() {
        let summary = TurnFailureSummary(reason: "session/prompt failed: The model returned an empty response.")

        #expect(summary.category == .generic)
        #expect(summary.title == "Turn failed")
        #expect(summary.message == "The model returned an empty response.")
        #expect(summary.retryHint == nil)
        #expect(summary.linkURL == nil)
    }

    @Test func emptyReasonHasTitleOnly() {
        for reason in ["", "  \n", "internal error:"] {
            let summary = TurnFailureSummary(reason: reason)
            #expect(summary.category == .generic)
            #expect(summary.title == "Turn failed")
            #expect(summary.message == nil)
            #expect(summary.rawDetails == reason)
        }
    }

    @Test func structuredHintWithoutMessageUsesCategorySentence() {
        let summary = TurnFailureSummary(reason: #"{"codexErrorInfo":"usageLimitExceeded"}"#)

        #expect(summary.category == .usageLimit)
        #expect(summary.message == "The provider's usage limit was reached.")
    }

    @Test func connectionResetIsNotARetryHint() {
        #expect(TurnFailureSummary(reason: "connection reset by peer").retryHint == nil)
    }

    @Test func noticeExposesSummaryOnlyForTurnFailures() {
        #expect(AttentionNotice(kind: .turnFailure, reason: "boom").turnFailureSummary?.message == "boom")
        #expect(AttentionNotice(kind: .blockerReport, reason: "boom").turnFailureSummary == nil)
        #expect(AttentionNotice(kind: .discussionRequest, reason: "boom").turnFailureSummary == nil)
    }
}
