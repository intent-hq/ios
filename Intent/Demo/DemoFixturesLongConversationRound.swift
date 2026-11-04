import Foundation

extension DemoFixtures {
    private static let reportCycleCount = 3
    private static let tableCycleCount = 4
    private static let oddRoundEndToEndBaseMinutes = 9

    /// One `longConversationMessages` row before its id and timestamp are
    /// assigned.
    struct LongConversationRow {
        var role: String
        var contentBlocks: [[String: Any]]
        var metadata: [String: Any] = [:]
    }

    static func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    static func toolUseBlock(id: String, name: String, input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "toolCallId": id, "name": name, "input": input]
    }

    static func toolResultBlock(toolUseId: String, output: String) -> [String: Any] {
        ["type": "tool_result", "id": "\(toolUseId)-result", "toolUseId": toolUseId, "output": output]
    }

    /// A user-role row sent by delegate `index` (PROTOCOL §5.5 agent-to-agent
    /// attribution on the row metadata and the text block's `messageMetadata`).
    static func delegateRow(_ index: Int, text: String) -> LongConversationRow {
        let attribution: [String: Any] = [
            "type": "agent_message",
            "fromAgentId": longConversationDelegateIds[index],
            "fromAgentName": longConversationDelegateNames[index]
        ]
        var block = textBlock(text)
        block["messageMetadata"] = attribution
        return LongConversationRow(role: "user", contentBlocks: [block], metadata: attribution)
    }

    private struct LongConversationTopic {
        let subject: String
        let file: String
        let symbol: String
        let command: String
        let metric: String
    }

    /// Per-round subject matter for longConversationRound; one entry
    /// per gap between handwritten exchanges.
    private static let longConversationRoundTopics: [LongConversationTopic] = [
        LongConversationTopic(
            subject: "stream id reuse after fork",
            file: "tests/payments/conftest.py",
            symbol: "PaymentClient.shared",
            command: "pytest tests/payments -n 4 --count 25",
            metric: "7 timeouts in 100 runs"
        ),
        LongConversationTopic(
            subject: "the pre-warmed pool inheritance",
            file: "payments/client/pool.py",
            symbol: "Http2Pool.warm",
            command: "pytest tests/payments/test_capture.py -n 4",
            metric: "20–30s first-request stalls"
        ),
        LongConversationTopic(
            subject: "the local reproduction loop",
            file: "scripts/repro_flake.sh",
            symbol: "run_loop",
            command: "scripts/repro_flake.sh --workers 4 --repeat 25",
            metric: "7/100 failing, 0/100 single-worker"
        ),
        LongConversationTopic(
            subject: "the after_fork reset hook",
            file: "tests/payments/hooks.py",
            symbol: "_reset_payment_client",
            command: "pytest tests/payments -n 4 --count 25 -p hooks",
            metric: "0 timeouts in 100 runs"
        ),
        LongConversationTopic(
            subject: "the stale ledger read",
            file: "tests/payments/test_refund.py",
            symbol: "test_refund_partial_amount",
            command: "pytest tests/payments/test_refund.py -n 4 --count 50",
            metric: "3 stale reads in 50 runs"
        ),
        LongConversationTopic(
            subject: "the settlement status poll",
            file: "tests/payments/helpers/wait.py",
            symbol: "wait_until",
            command: "pytest tests/payments/test_refund.py --count 50",
            metric: "settled p99 3.4s"
        ),
        LongConversationTopic(
            subject: "first-request latency per worker",
            file: "payments/client/metrics.py",
            symbol: "record_first_request",
            command: "scripts/repro_flake.sh --workers 4 --repeat 25 --metrics",
            metric: "median 140ms, was 1.8s"
        ),
        LongConversationTopic(
            subject: "webhook test isolation",
            file: "tests/webhooks/test_delivery.py",
            symbol: "WebhookDeliveryTests",
            command: "pytest tests/webhooks -n 4",
            metric: "48 passed, 0 shared-client uses"
        ),
        LongConversationTopic(
            subject: "the known-flake taxonomy",
            file: "docs/testing/flakes.md",
            symbol: "Known flake sources",
            command: "make docs-check",
            metric: "3 rows, 3 links"
        ),
        LongConversationTopic(
            subject: "sandbox rate limiting",
            file: "payments/client/backoff.py",
            symbol: "RetryPolicy.for_429",
            command: "scripts/repro_flake.sh --workers 8 --repeat 10",
            metric: "55 rps at 6 workers, 429s at 8"
        ),
        LongConversationTopic(
            subject: "the CI branch run",
            file: ".github/workflows/payments.yml",
            symbol: "payments-integration",
            command: "gh run watch 88123",
            metric: "green in 5m12s"
        ),
        LongConversationTopic(
            subject: "the overnight matrix",
            file: ".github/workflows/payments-matrix.yml",
            symbol: "matrix.repeat",
            command: "gh workflow run payments-matrix.yml -f repeat=50",
            metric: "50 scheduled, 10 min apart"
        ),
        LongConversationTopic(
            subject: "the duration distribution",
            file: "scripts/collect_durations.py",
            symbol: "percentiles",
            command: "scripts/collect_durations.py --runs 50",
            metric: "p50 5m04s, p90 5m31s, max 6m02s"
        ),
        LongConversationTopic(
            subject: "the retry decorators",
            file: "tests/payments/test_capture.py",
            symbol: "@retry(3)",
            command: "rg -n 'retry\\(3\\)' tests/payments",
            metric: "3 decorators removed"
        ),
        LongConversationTopic(
            subject: "the README sandbox key steps",
            file: "README.md",
            symbol: "PAYMENT_SANDBOX_KEY",
            command: "git clone … && make repro",
            metric: "end to end in ~4 min"
        )
    ]

    /// The delegation round inserted after handwritten exchange `round`:
    /// nine rows of deliberately uneven height — a tool-call group, three
    /// agent-to-agent reports, a delegation tool call, markdown replies with
    /// code fences / tables / a thinking block, and one human follow-up.
    static func longConversationRound(_ round: Int) -> [LongConversationRow] {
        longConversationFirstRows(round) + longConversationLastRows(round)
    }

    private static func longConversationFirstRows(_ round: Int) -> [LongConversationRow] {
        [longConversationInvestigationRow(round)]
            + longConversationReportRows(round)
            + longConversationDelegationRows(round)
    }

    private static func longConversationInvestigationRow(_ round: Int) -> LongConversationRow {
        let topic = longConversationRoundTopics[round]
        let ordinal = round + 1
        let toolPrefix = "demo-long-tool-\(ordinal)"
        let repeatedParagraph = "Nothing in the production path changes for this step; the only writes " +
            "are under `tests/` and the scripts folder, so review scope stays narrow."
        let fillerCount = round.quotientAndRemainder(dividingBy: reportCycleCount).remainder + 1
        let filler = Array(repeating: repeatedParagraph, count: fillerCount).joined(separator: "\n\n")
        return LongConversationRow(role: "assistant", contentBlocks: [
            textBlock("""
            <group:Investigating \(topic.subject)>
            Reading `\(topic.file)` around `\(topic.symbol)` and re-running the narrow command before delegating.
            """),
            toolUseBlock(id: "\(toolPrefix)-view", name: "view", input: [
                "path": topic.file,
                "search_query_regex": topic.symbol
            ]),
            toolResultBlock(toolUseId: "\(toolPrefix)-view", output: """
            \(topic.file)
            41 |     # \(topic.symbol)
            42 |     client = PaymentClient.shared()
            43 |     return client.capture(intent_id, amount=amount)
            """),
            toolUseBlock(id: "\(toolPrefix)-run", name: "launch-process", input: [
                "command": topic.command,
                "cwd": "services/billing",
                "wait": true
            ]),
            toolResultBlock(toolUseId: "\(toolPrefix)-run", output: """
            $ \(topic.command)
            collected 96 items across 4 workers
            ........F.....F.........................F.......
            \(topic.metric)
            """),
            textBlock("""
            The narrow run reproduces it: \(topic.metric).
            </group>

            Round \(ordinal) of the investigation covers **\(topic.subject)**. The signal is \
            consistent with the fork story, so I am splitting the work across the delegates \
            instead of serialising it here.

            \(filler)
            """)
        ])
    }

    private static func longConversationReportRows(_ round: Int) -> [LongConversationRow] {
        let topic = longConversationRoundTopics[round]
        let ordinal = round + 1
        let reporter = round.quotientAndRemainder(dividingBy: reportCycleCount).remainder
        let firstReportStatus = round.isMultiple(of: 2)
            ? "Patch is ready; running the loop once more before I report it done"
            : "Still bisecting the second failure mode; will report within the hour"
        let firstReportCode = round.isMultiple(of: 2) ? """
        ```python
        # \(topic.file)
        def reset_for_round_\(ordinal)():
            client = PaymentClient.reset_shared()
            return client
        ```
        """ : "No code to show yet — the evidence is in the attached log."
        let firstReport = delegateRow(reporter, text: """
        Progress on \(topic.subject):

        - Reproduced with `\(topic.command)` → \(topic.metric)
        - Isolated the path to `\(topic.symbol)` in `\(topic.file)`
        - \(firstReportStatus)

        \(firstReportCode)
        """)

        return [firstReport, longConversationReplyRow(round)]
    }

    private static func longConversationReplyRow(_ round: Int) -> LongConversationRow {
        let topic = longConversationRoundTopics[round]
        let ordinal = round + 1
        let repeatedParagraph = "Nothing in the production path changes for this step; the only writes " +
            "are under `tests/` and the scripts folder, so review scope stays narrow."
        let fillerCount = round.quotientAndRemainder(dividingBy: reportCycleCount).remainder + 1
        let filler = Array(repeating: repeatedParagraph, count: fillerCount).joined(separator: "\n\n")
        let table = round.isMultiple(of: reportCycleCount) ? """

        | Run | Workers | Result |
        |-----|---------|--------|
        | 1 | 4 | \(topic.metric) |
        | 2 | 4 | \(topic.metric) |
        | 3 | 1 | clean |
        """ : ""
        return LongConversationRow(
            role: "assistant",
            contentBlocks: [
                textBlock("""
        ### Next step for \(topic.subject)

        1. Keep the change confined to `\(topic.file)`
        2. Re-run `\(topic.command)` until the loop is clean twice in a row
        3. Attach the per-worker log to the task note
        \(table)
        ```bash
        cd services/billing
        \(topic.command) 2>&1 | tee /tmp/round-\(ordinal).log
        ```

        \(filler)
        """)
            ]
        )
    }

    private static func longConversationDelegationRows(_ round: Int) -> [LongConversationRow] {
        let topic = longConversationRoundTopics[round]
        let ordinal = round + 1
        let toolPrefix = "demo-long-tool-\(ordinal)"
        let secondReporter = (round + 1).quotientAndRemainder(dividingBy: reportCycleCount).remainder
        let thirdReporter = (round + 2).quotientAndRemainder(dividingBy: reportCycleCount).remainder
        let delegation = LongConversationRow(role: "assistant", contentBlocks: [
            textBlock("Delegating the verification of \(topic.subject) so it runs in parallel with the fix."),
            toolUseBlock(id: "\(toolPrefix)-delegate", name: "workspace_api", input: [
                "code": "return await ws.agent.delegate({ taskNoteId: \"demo-task-round-\(ordinal)\", specialist: \"verifier\", waitMode: \"after_all\" })",
                "summary": "Delegate verification of \(topic.subject)"
            ]),
            toolResultBlock(toolUseId: "\(toolPrefix)-delegate", output: """
            {"ok":true,"agentId":"\(longConversationDelegateIds[thirdReporter])","waitMode":"after_all","summary":{"started":1,"held":0,"skipped":0}}
            """),
            textBlock("Delegated; I will pick the evidence up when the group settles.")
        ])

        let secondReport = delegateRow(secondReporter, text: """
        Verification of \(topic.subject) is under way. First pass: `\(topic.command)` → \(topic.metric). \
        I am repeating it with `--count 50` to get a distribution rather than a single sample.
        """)

        return [delegation, secondReport]
    }

    private static func longConversationLastRows(_ round: Int) -> [LongConversationRow] {
        longConversationSummaryRows(round) + longConversationAnswerRows(round)
    }

    private static func longConversationSummaryRows(_ round: Int) -> [LongConversationRow] {
        let topic = longConversationRoundTopics[round]
        let ordinal = round + 1
        let repeatedParagraph = "Nothing in the production path changes for this step; the only writes " +
            "are under `tests/` and the scripts folder, so review scope stays narrow."
        let fillerCount = round.quotientAndRemainder(dividingBy: reportCycleCount).remainder + 1
        let filler = Array(repeating: repeatedParagraph, count: fillerCount).joined(separator: "\n\n")
        let bulletCount = round.quotientAndRemainder(dividingBy: tableCycleCount).remainder + 2
        var summaryBlocks: [[String: Any]] = []
        if !round.isMultiple(of: 2) {
            summaryBlocks.append(
                [
                    "type": "thinking",
                    "text": "Both delegates agree on \(topic.metric). The remaining risk is ordering, not connectivity; " +
                        "check the settlement path before closing round \(ordinal)."
                ]
            )
        }
        let bullets = (0..<bulletCount)
            .map { bullet in "- Sample \(bullet + 1): `\(topic.command)` → \(topic.metric)" }
            .joined(separator: "\n")
        summaryBlocks.append(textBlock("""
        Round \(ordinal) summary for \(topic.subject):

        \(bullets)

        The fix stays inside `\(topic.file)`. \(filler)
        """))
        let summary = LongConversationRow(role: "assistant", contentBlocks: summaryBlocks)

        let followUpText = round.isMultiple(of: 2)
            ? "Does round \(ordinal) change anything for the webhook tests?"
            : "How long did round \(ordinal) take end to end?"
        let followUp = LongConversationRow(role: "user", contentBlocks: [textBlock(followUpText)])

        return [summary, followUp]
    }

    private static func longConversationAnswerRows(_ round: Int) -> [LongConversationRow] {
        let topic = longConversationRoundTopics[round]
        let ordinal = round + 1
        let thirdReporter = (round + 2).quotientAndRemainder(dividingBy: reportCycleCount).remainder
        let bigTable = round.isMultiple(of: tableCycleCount) ? """

        | Test | Before | After |
        |------|--------|-------|
        | capture_settles_after_authorization | 20–30s timeout | 140ms |
        | refund_partial_amount | stale balance | settled |
        | capture_3ds_challenge | 14s | 14s |
        | webhook_delivery_retry | 2.1s | 2.1s |
        | capture_idempotent_replay | 380ms | 120ms |
        | refund_full_amount | 900ms | 410ms |
        """ : ""
        let answerLead = round.isMultiple(of: 2)
            ? "No: the webhook tests build their own `PaymentClient(base_url=...)` per test and never touch " +
                "the shared pool, so round \(ordinal) leaves them untouched."
            : "About \(oddRoundEndToEndBaseMinutes + round) minutes end to end, " +
                "most of it the `--count 50` loop; the patch itself was a few lines."
        let answer = LongConversationRow(
            role: "assistant",
            contentBlocks: [
                textBlock("""
        \(answerLead)
        \(bigTable)
        ```diff
        --- a/\(topic.file)
        +++ b/\(topic.file)
        @@ -40,3 +40,4 @@
        -    client = PaymentClient.shared()
        +    client = PaymentClient.reset_shared()
        +    # \(topic.subject): see round \(ordinal)
        ```
        """)
            ]
        )

        let thirdReport = delegateRow(thirdReporter, text: """
        Evidence for \(topic.subject), 50 runs:

        | Metric | Value |
        |--------|-------|
        | Failures | 0 |
        | Median | 5m04s |
        | Max | 6m02s |

        Attached the per-run log to the task note and marked the verification complete.
        """)

        return [answer, thirdReport]
    }
}
