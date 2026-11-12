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

    @Test func malformedJSONWithoutMessageKeepsLeadingText() {
        let summary = TurnFailureSummary(reason: #"internal error: agent crashed {"code": 7,"#)

        #expect(summary.category == .generic)
        #expect(summary.message == "agent crashed")
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
