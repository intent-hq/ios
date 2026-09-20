import Foundation

extension DemoFixtures {
    /// Sentence that opens the first (user) message of
    /// `longConversationMessages`; stable anchor for UI tests.
    static let longConversationFirstSentence =
        "Start of the flake investigation: the payment integration suite failed 6 of the last 20 CI runs."

    /// Sentence that closes the last (assistant) message of
    /// `longConversationMessages`; stable anchor for UI tests.
    static let longConversationLastSentence =
        "End of the flake investigation: 50 consecutive green runs on the payment integration suite."

    /// Suggested prompts carried by the last (assistant) message of
    /// `longConversationMessages` as a trailing `<!-- suggested-prompts -->`
    /// block, so the transcript's prompt rows — and the scroll transition
    /// when one is tapped — can be exercised against `--demo-data`.
    static let longConversationSuggestedPrompts = [
        "Open a PR for the deflake changes",
        "Show me the final evidence table",
        "Schedule the worker scaling follow-up"
    ]

    /// A coordinator-shaped transcript many screens tall on an iPhone, so
    /// scroll-position UI (the "Go to End" button) and the LazyVStack
    /// cold-layout paths (intent-hq/ios#304, #305) can be exercised against
    /// `--demo-data`: 16 handwritten user/assistant exchanges with a
    /// generated delegation round between each pair — tool-call groups,
    /// agent-to-agent report rows (`metadata.type == "agent_message"`),
    /// multi-paragraph markdown, fenced code blocks, tables and thinking
    /// blocks — for `longConversationMessageCount` messages of widely varying
    /// heights. The first message begins with `longConversationFirstSentence`
    /// and the last one's rendered text ends with
    /// `longConversationLastSentence`, followed only by the stripped
    /// `longConversationSuggestedPrompts` block.
    private static var longConversationSuggestedPromptsBlock: String {
        (["<!-- suggested-prompts"] + longConversationSuggestedPrompts + ["-->"])
            .joined(separator: "\n")
    }

    private static let longConversationExchanges: [(user: String, assistant: String)] = [
            (
                """
                \(longConversationFirstSentence)

                Every failure is in `PaymentCaptureTests` or `RefundFlowTests`, and \
                re-running the job usually passes. Can you find out what is actually \
                racing before we start adding retries?
                """,
                """
                Pulling the last 20 CI logs now. Initial pattern:

                - 5 of the 6 failures are `capture_settles_after_authorization` timing out
                - the 6th is `refund_partial_amount` asserting on a stale ledger balance

                Both talk to the sandbox gateway through the shared `PaymentClient` \
                fixture, so I'll start there.
                """
            ),
            (
                """
                The shared fixture was added when we parallelised the suite. Does it \
                reuse a connection pool across test cases?
                """,
                """
                It does: `PaymentClient.shared` keeps one HTTP/2 connection pool per \
                process, and the parallel runner forks four workers that all inherit \
                the pre-warmed pool.

                After a fork the child sockets still point at the parent's stream ids, \
                so the first request on each worker races the gateway's stream reset. \
                That explains the 20–30s timeouts on the first capture in each worker.
                """
            ),
            (
                """
                Can we prove that before changing anything? I'd like a reproduction \
                that fails locally, not just a plausible story.
                """,
                """
                Reproduced locally with `--workers 4 --repeat 25`: 7 timeouts in 100 \
                runs, all on the first request of a worker.

                With `--workers 1` the same 100 runs are clean. I also added a debug \
                log of the stream id on each request; the failing ones reuse ids the \
                parent already consumed. Attaching the log to the task note.
                """
            ),
            (
                """
                Good. What's the smallest fix — recreate the pool after fork, or move \
                client creation into each test's setup?
                """,
                """
                Recreating the pool in an `after_fork` hook is smaller and keeps the \
                per-test setup untouched:

                ```python
                @runner.after_fork
                def _reset_payment_client():
                    PaymentClient.reset_shared()
                ```

                `reset_shared()` already exists for the CLI, so no new API surface. \
                Running the 100-run loop again with this in place.
                """
            ),
            (
                """
                While that runs: the refund balance assertion isn't a connection issue, \
                is it? A stale ledger read sounds like ordering.
                """,
                """
                Correct, that one is separate. `refund_partial_amount` reads the ledger \
                immediately after posting the refund, but the sandbox gateway applies \
                refunds through an async settlement queue.

                The test passes when the queue drains within the 200ms poll window and \
                fails when the gateway is under load from the other workers. It was \
                always order-dependent; parallel runs just made it visible.
                """
            ),
            (
                """
                So the refund test needs to wait on settlement instead of sleeping. Is \
                there a settlement event we can subscribe to in the sandbox?
                """,
                """
                Yes: the sandbox exposes `GET /v1/refunds/{id}` with a `status` field \
                that moves `pending → settled`, and the test helpers already have a \
                `wait_until(predicate, timeout=5s)` utility.

                I'll replace the fixed 200ms poll with `wait_until(lambda: refund.status == "settled")` \
                and assert on the balance after that. No production code changes.
                """
            ),
            (
                """
                Results from the 100-run loop with the after_fork reset?
                """,
                """
                Clean: 0 timeouts in 100 runs at 4 workers, and the median first-request \
                latency per worker dropped from 1.8s to 140ms because the workers no \
                longer wait out a stream reset.

                Total suite time went from 6m40s to 5m05s as a side effect. Pushing the \
                hook and the refund wait as two separate commits.
                """
            ),
            (
                """
                Two commits is right. Before you push, check whether any other test \
                relies on the pre-warmed pool for timing — I remember the webhook \
                tests being sensitive.
                """,
                """
                Checked `WebhookDeliveryTests`: they construct their own \
                `PaymentClient(base_url=...)` per test and never touch the shared one, \
                so the after-fork reset doesn't affect them.

                The only other consumer of `PaymentClient.shared` is the smoke test, \
                which runs single-worker. I added a comment on the hook explaining why \
                it exists so it isn't removed as dead code later.
                """
            ),
            (
                """
                CI is running on the branch now. While we wait, can you write down the \
                flake taxonomy so the next person doesn't have to rediscover it?
                """,
                """
                Added a "Known flake sources" section to the task note with three rows:

                1. Forked connection pools — fixed by the after-fork reset
                2. Async settlement reads — fixed by waiting on refund status
                3. Sandbox rate limiting at >6 workers — not fixed, documented as a limit

                Each row links to the commit or the sandbox docs.
                """
            ),
            (
                """
                What's the story on the rate limiting? We were planning to go to 8 \
                workers next quarter.
                """,
                """
                The sandbox gateway allows 60 requests per second per API key. At 6 \
                workers the capture tests peak at about 55 rps; at 8 they hit the limit \
                and get `429` responses, which the client retries with backoff and the \
                tests read as slow rather than failed.

                Going to 8 workers means either a second sandbox key per shard or \
                rate-aware test scheduling. I'd file that as a follow-up rather than \
                fold it into this fix.
                """
            ),
            (
                """
                Agreed, file the follow-up. Did CI finish?
                """,
                """
                CI is green on the first run. The payment integration job took 5m12s, \
                consistent with the local numbers.

                Filed the follow-up for worker scaling with the rps measurements \
                attached. I also enabled the job's flaky-test detector so any new \
                intermittent failure gets flagged on the PR instead of hiding behind \
                a retry.
                """
            ),
            (
                """
                One green run isn't proof for a flake fix. Can you run the job in a loop \
                on CI overnight and report the distribution?
                """,
                """
                Scheduled 50 runs of the payment integration job on the branch using \
                the matrix trigger, spaced 10 minutes apart so they overlap with the \
                normal nightly load.

                I'll collect the per-test durations and failure counts into a table \
                and post it here when the batch completes.
                """
            ),
            (
                """
                Overnight batch done?
                """,
                """
                All 50 runs passed. Duration distribution for the job:

                | Percentile | Duration |
                |------------|----------|
                | p50 | 5m04s |
                | p90 | 5m31s |
                | max | 6m02s |

                No test exceeded its per-test timeout, and the slowest individual test \
                was `capture_3ds_challenge` at 14s, which is expected for that flow.
                """
            ),
            (
                """
                That's convincing. Anything left before this is ready for review?
                """,
                """
                Two small items, both done now:

                - Removed the three `@retry(3)` decorators that were masking the original \
                failures, so a regression fails loudly
                - Bumped the refund settlement wait timeout from 5s to 10s with a comment, \
                since the sandbox p99 for settlement is 3.4s and 5s left little margin

                PR description lists the root causes, the reproduction commands, and the \
                overnight results.
                """
            ),
            (
                """
                Please also make sure the reproduction commands actually work from a \
                clean checkout; the README steps for the sandbox key are out of date.
                """,
                """
                Verified from a fresh clone: the README pointed at the old `SANDBOX_KEY` \
                variable while the client now reads `PAYMENT_SANDBOX_KEY`. Fixed the \
                README and the example `.env`, and the reproduction loop runs end to end \
                in about four minutes on a laptop.

                That change is in its own `docs:` commit so it can be cherry-picked \
                independently.
                """
            ),
            (
                """
                Great, request review from the payments team and mark the task ready. \
                Thanks for not just adding retries.
                """,
                """
                Review requested from the payments team and the task note is updated \
                with the final evidence table.

                Summary: two real races (forked connection pool, async refund \
                settlement) fixed without touching production code, retry decorators \
                removed, README corrected, and a follow-up filed for worker scaling. \
                \(longConversationLastSentence)

                \(longConversationSuggestedPromptsBlock)
                """
            )
    ]

    static var longConversationMessages: [[String: Any]] {
        longConversationMessages(slimToolRows: longConversationSlimToolRowLayout)
    }

    static func longConversationMessages(
        slimToolRows layout: LongConversationSlimToolRowLayout
    ) -> [[String: Any]] {
        var rows: [LongConversationRow] = []
        for (index, exchange) in longConversationExchanges.enumerated() {
            rows.append(LongConversationRow(role: "user", contentBlocks: [textBlock(exchange.user)]))
            let truncatedCallIndex = longConversationExchanges.count - 1 - index
            let truncatedBlocks = if truncatedCallIndex < longConversationTruncatedToolCalls.count {
                truncatedToolBlocks(longConversationTruncatedToolCalls[truncatedCallIndex])
            } else {
                [[String: Any]]()
            }
            switch layout {
            case .leading:
                rows.append(LongConversationRow(
                    role: "assistant",
                    contentBlocks: truncatedBlocks + [textBlock(exchange.assistant)]
                ))
            case .standalone:
                if !truncatedBlocks.isEmpty {
                    rows.append(LongConversationRow(role: "assistant", contentBlocks: truncatedBlocks))
                }
                rows.append(LongConversationRow(role: "assistant", contentBlocks: [textBlock(exchange.assistant)]))
            }
            if index < longConversationExchanges.count - 1 {
                rows += longConversationRound(index)
            }
        }

        let firstMinutesAgo = 240.0
        let lastMinutesAgo = 42.0
        let step = (firstMinutesAgo - lastMinutesAgo) / Double(rows.count - 1)
        return rows.enumerated().map { ordinal, row in
            var message: [String: Any] = [
                "id": "demo-long-msg-\(ordinal + 1)",
                "role": row.role,
                "timestamp": iso(minutesAgo: firstMinutesAgo - step * Double(ordinal)),
                "contentBlocks": row.contentBlocks
            ]
            if !row.metadata.isEmpty { message["metadata"] = row.metadata }
            return message
        }
    }
}
