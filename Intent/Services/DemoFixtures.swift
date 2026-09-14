import Foundation

/// Launch-argument-driven demo mode for screenshot UI tests: with
/// `--demo-data` the app skips pairing, serves fixture data from
/// `DemoFixtures` instead of a live daemon connection, and runs
/// `PersistenceManager.shared` over an ephemeral store (see
/// `PersistenceManager.ephemeral()`). Zero-impact when the arguments are
/// absent.
enum DemoMode {
    /// True when fixture data should be served (`--demo-data`).
    static let isEnabled = demoDataRequested(by: ProcessInfo.processInfo.arguments)

    /// True when the pairing flow should be skipped (`--pretend-paired`,
    /// implied by `--demo-data`).
    static let pretendPaired = pretendPairedRequested(by: ProcessInfo.processInfo.arguments)

    static func demoDataRequested(by arguments: [String]) -> Bool {
        arguments.contains("--demo-data")
    }

    static func pretendPairedRequested(by arguments: [String]) -> Bool {
        arguments.contains("--pretend-paired") || demoDataRequested(by: arguments)
    }
}

/// Static fixture responses for demo mode. Shapes mirror the daemon's
/// JSON-RPC results exactly as the stores parse them (`workspace.list` →
/// `WorkspaceStore.parseWorkspaces`, `note.list` → `Note.parseNote`,
/// `agent.list` → `AgentSession.parseAgent`, ...).
///
/// Subscribe methods intentionally fall through to the empty-dictionary
/// default: a response without a `subscriptionId` makes every store fall
/// back to its legacy fetch path, which is exactly right for static data.
enum DemoFixtures {

    /// Workspace whose `agent.list` returns `longConversationAgents` instead
    /// of the default `agents` (the "Deflake payment integration tests"
    /// workspace, not part of App Store screenshots 02–04).
    static let longConversationWorkspaceId = "demo-ws-flaky-tests"

    /// Agent whose `agent.getConversation` returns `longConversationMessages`
    /// ("Test Stabilizer", idle). Every other agent keeps the 4-message
    /// `conversationMessages` used by App Store screenshot 03.
    static let longConversationAgentId = "demo-agent-deflake"

    /// Name of the single scheduled hook `hook.list` serves for
    /// `longConversationAgentId`. Rendered as a chip in the hooks row above
    /// the composer; the row's own label is "Running hooks".
    static let longConversationHookName = "Wait for CI on flake fix"

    /// `hook.list` for `longConversationWorkspaceId` answers only after this
    /// delay, so the hooks row appears under an already-settled transcript —
    /// the container-resize path of #272 under `--demo-data`
    /// (`ConversationTranscriptScrollUITests`). Every other fixture answers
    /// immediately.
    static let longConversationHookListDelay: Duration = .seconds(4)

    /// Delay to apply before serving `response(for:params:)`, or nil for an
    /// immediate answer.
    static func responseDelay(for method: String, params: [String: Any]) -> Duration? {
        guard method == "hook.list",
              params["workspaceId"] as? String == longConversationWorkspaceId else { return nil }
        return longConversationHookListDelay
    }

    /// Fixture response for a JSON-RPC method. Unknown methods return an
    /// empty dictionary, which every call site parses as "no data" safely.
    static func response(for method: String, params: [String: Any]) -> Any {
        switch method {
        case "workspace.list":
            return ["workspaces": workspaces]
        case "note.list":
            return ["notes": notes]
        case "note.get":
            let noteId = params["noteId"] as? String
            let note = notes.first { ($0["id"] as? String) == noteId } ?? notes[0]
            return ["note": note]
        case "agent.list":
            let workspaceId = params["workspaceId"] as? String
            return ["agents": workspaceId == longConversationWorkspaceId ? longConversationAgents : agents]
        case "agent.get":
            let agentId = params["agentId"] as? String
            let agent = (agents + longConversationAgents).first { ($0["id"] as? String) == agentId } ?? agents[0]
            return ["agent": agent]
        case "agent.getConversation":
            let agentId = params["agentId"] as? String
            let messages = agentId == longConversationAgentId ? longConversationMessages : conversationMessages
            return [
                "messages": messages,
                "truncated": false,
                "totalMessages": messages.count,
            ] as [String: Any]
        case "agent.getQueue":
            return ["queue": [[String: Any]]()]
        case "hook.list":
            let workspaceId = params["workspaceId"] as? String
            return ["hooks": workspaceId == longConversationWorkspaceId ? longConversationHooks : []]
        case "task.list":
            return ["tasks": tasks]
        case "specialist.list":
            return ["specialists": specialists]
        default:
            return [String: Any]()
        }
    }

    /// ISO 8601 timestamp relative to now, so relative-time labels
    /// ("12m ago") always look fresh in screenshots.
    private static func iso(minutesAgo: Double) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -minutesAgo * 60))
    }

    // MARK: - Workspaces

    static var workspaces: [[String: Any]] {
        [
            [
                "id": "demo-ws-dashboard",
                "title": "Add usage analytics dashboard",
                "branch": "feat/usage-dashboard",
                "baseRef": "main",
                "status": "active",
                "activity": "idle",
                "displayStatus": "pr_open",
                "attention": "none",
                "lastActivity": iso(minutesAgo: 12),
                "updatedAt": iso(minutesAgo: 12),
                "repositoryOwner": "nova-labs",
                "repositoryName": "console",
                "prStatus": "Open",
                "prNumber": 482,
                "diffSummary": ["totalFiles": 14],
                "taskStats": ["total": 5, "completed": 3, "inProgress": 1],
                "agentSummary": [
                    "count": 2,
                    "agents": [
                        [
                            "id": "demo-agent-implementor",
                            "name": "Dashboard Implementor",
                            "status": "idle",
                            "specialist": "implementor",
                            "lastActivity": iso(minutesAgo: 12),
                        ],
                        [
                            "id": "demo-agent-reviewer",
                            "name": "PR Reviewer",
                            "status": "running",
                            "specialist": "verifier",
                            "isResponding": true,
                            "lastActivity": iso(minutesAgo: 2),
                        ],
                    ] as [[String: Any]],
                ] as [String: Any],
                "activePullRequest": [
                    "number": 482,
                    "status": "Open",
                    "title": "feat: usage analytics dashboard with CSV export",
                    "updatedAt": iso(minutesAgo: 25),
                ] as [String: Any],
            ],
            [
                "id": "demo-ws-reconnect",
                "title": "Fix websocket reconnect storm",
                "branch": "fix/ws-reconnect-backoff",
                "baseRef": "main",
                "status": "active",
                "activity": "agent_running",
                "displayStatus": "in_progress",
                "attention": "none",
                "lastActivity": iso(minutesAgo: 1),
                "updatedAt": iso(minutesAgo: 1),
                "repositoryOwner": "nova-labs",
                "repositoryName": "gateway",
                "diffSummary": ["totalFiles": 3],
                "taskStats": ["total": 3, "completed": 1, "inProgress": 1],
                "agentSummary": [
                    "count": 1,
                    "agents": [
                        [
                            "id": "demo-agent-backoff",
                            "name": "Reconnect Fixer",
                            "status": "running",
                            "specialist": "implementor",
                            "isStreaming": true,
                            "lastActivity": iso(minutesAgo: 1),
                        ],
                    ] as [[String: Any]],
                ] as [String: Any],
            ],
            [
                "id": "demo-ws-dark-mode",
                "title": "Dark mode for settings screens",
                "branch": "feat/settings-dark-mode",
                "baseRef": "main",
                "status": "active",
                "activity": "idle",
                "displayStatus": "complete",
                "attention": "none",
                "lastActivity": iso(minutesAgo: 95),
                "updatedAt": iso(minutesAgo: 95),
                "repositoryOwner": "nova-labs",
                "repositoryName": "mobile",
                "prStatus": "Merged",
                "prNumber": 471,
                "diffSummary": ["totalFiles": 9],
                "taskStats": ["total": 4, "completed": 4, "inProgress": 0],
                "agentSummary": ["count": 0, "agents": [[String: Any]]()] as [String: Any],
            ],
            [
                "id": "demo-ws-flaky-tests",
                "title": "Deflake payment integration tests",
                "branch": "chore/deflake-payment-tests",
                "baseRef": "main",
                "status": "active",
                "activity": "idle",
                "displayStatus": "needs_attention",
                "attention": "unread",
                "lastActivity": iso(minutesAgo: 42),
                "updatedAt": iso(minutesAgo: 42),
                "repositoryOwner": "nova-labs",
                "repositoryName": "billing",
                "diffSummary": ["totalFiles": 2],
                "taskStats": ["total": 2, "completed": 0, "inProgress": 1],
                "agentSummary": [
                    "count": 1,
                    "agents": [
                        [
                            "id": "demo-agent-deflake",
                            "name": "Test Stabilizer",
                            "status": "idle",
                            "specialist": "implementor",
                            "lastActivity": iso(minutesAgo: 42),
                        ],
                    ] as [[String: Any]],
                ] as [String: Any],
            ],
        ]
    }

    // MARK: - Notes

    static var notes: [[String: Any]] {
        [
            [
                "id": "demo-note-spec",
                "title": "Spec",
                "isDefault": true,
                "createdAt": iso(minutesAgo: 320),
                "updatedAt": iso(minutesAgo: 18),
                "content": """
                # Usage analytics dashboard

                Add a usage analytics dashboard to the console so admins can see \
                seat activity, API call volume, and export the data for finance.

                ## Goals

                - Per-team daily/weekly active seat counts
                - API request volume chart with 30-day history
                - CSV export matching the finance team's import format

                ## Plan

                - [x] Add `/api/usage/summary` endpoint with date-range params
                - [x] Chart component with daily/weekly toggle
                - [x] Wire dashboard route + navigation entry
                - [/] CSV export with streamed download
                - [ ] Feature flag rollout to beta orgs

                ## Decisions

                - Reuse the existing `MetricsRollupJob` output table instead of \
                querying raw events — keeps the dashboard queries under 50ms.
                - Export is capped at 90 days per request; longer ranges get a \
                background job + email link in a follow-up.
                """,
            ],
            [
                "id": "demo-note-csv-task",
                "title": "CSV export with streamed download",
                "createdAt": iso(minutesAgo: 240),
                "updatedAt": iso(minutesAgo: 20),
                "metadata": [
                    "task": [
                        "status": "in_progress",
                        "assignedAgentIds": ["demo-agent-implementor"],
                    ] as [String: Any],
                ] as [String: Any],
                "content": """
                # CSV export with streamed download

                Stream the usage rows as CSV instead of buffering the whole \
                range in memory — the 90-day export for large orgs is ~40MB.

                - [x] Chunked encoder over the rollup cursor
                - [x] Content-Disposition + progress header plumbing
                - [ ] Integration test for the 90-day cap error
                """,
            ],
            [
                "id": "demo-note-research",
                "title": "Chart library evaluation",
                "createdAt": iso(minutesAgo: 300),
                "updatedAt": iso(minutesAgo: 150),
                "content": """
                # Chart library evaluation

                Compared three options for the volume chart. Recharts wins on \
                bundle size and theming; we already ship it in the admin panel, \
                so no new dependency.

                | Library | Size (gz) | Theming | Verdict |
                |---------|-----------|---------|---------|
                | Recharts | 45 KB | CSS vars | ✅ picked |
                | Chart.js | 68 KB | JS config | runner-up |
                | ECharts | 320 KB | JS config | too heavy |
                """,
            ],
        ]
    }

    // MARK: - Agents

    static var agents: [[String: Any]] {
        [
            [
                "id": "demo-agent-implementor",
                "name": "Dashboard Implementor",
                "status": "idle",
                "createdAt": iso(minutesAgo: 260),
                "updatedAt": iso(minutesAgo: 12),
                "lastActivity": iso(minutesAgo: 12),
                "lastMessageRole": "assistant",
                "digest": "CSV export endpoint is streaming; adding the 90-day cap test next.",
                "metadata": ["specialist": "implementor"],
            ],
            [
                "id": "demo-agent-reviewer",
                "name": "PR Reviewer",
                "status": "running",
                "isResponding": true,
                "createdAt": iso(minutesAgo: 40),
                "updatedAt": iso(minutesAgo: 2),
                "lastActivity": iso(minutesAgo: 2),
                "lastMessageRole": "assistant",
                "digest": "Reviewing PR #482 — checking the pagination math on the rollup query.",
                "metadata": ["specialist": "verifier"],
            ],
        ]
    }

    /// Agents of `longConversationWorkspaceId`: the single idle agent whose
    /// transcript is `longConversationMessages`.
    static var longConversationAgents: [[String: Any]] {
        [
            [
                "id": longConversationAgentId,
                "name": "Test Stabilizer",
                "status": "idle",
                "createdAt": iso(minutesAgo: 250),
                "updatedAt": iso(minutesAgo: 42),
                "lastActivity": iso(minutesAgo: 42),
                "lastMessageRole": "assistant",
                "digest": "Payment integration suite is green across 50 consecutive runs.",
                "metadata": ["specialist": "implementor"],
            ],
        ]
    }

    /// Background hooks of `longConversationWorkspaceId` (PROTOCOL §5.40):
    /// one scheduled hook owned by `longConversationAgentId`, mid-TTL.
    static var longConversationHooks: [[String: Any]] {
        [
            [
                "hookId": "demo-hook-deflake-ci",
                "workspaceId": longConversationWorkspaceId,
                "agentId": longConversationAgentId,
                "name": longConversationHookName,
                "delayMs": 600_000,
                "state": "scheduled",
                "createdAt": iso(minutesAgo: 42),
                "expiresAt": iso(minutesAgo: -318),
                "lastRunAt": iso(minutesAgo: 2),
                "nextRunAt": iso(minutesAgo: -8),
                "runCount": 4,
                "perpetual": false,
            ],
        ]
    }

    // MARK: - Conversation

    static var conversationMessages: [[String: Any]] {
        [
            [
                "id": "demo-msg-1",
                "role": "user",
                "timestamp": iso(minutesAgo: 65),
                "contentBlocks": [
                    [
                        "type": "text",
                        "text": "Add the CSV export for the usage dashboard. Finance wants the same column layout as the old billing export.",
                    ],
                ],
            ],
            [
                "id": "demo-msg-2",
                "role": "assistant",
                "timestamp": iso(minutesAgo: 62),
                "contentBlocks": [
                    [
                        "type": "text",
                        "text": """
                        I'll match the billing export layout. Plan:

                        1. Add `GET /api/usage/export` with `from`/`to` params
                        2. Stream rows straight from the rollup cursor (large orgs \
                        hit ~40MB for 90 days, so no in-memory buffering)
                        3. Reuse `BillingCsvSchema` for the column order

                        Starting with the streaming encoder.
                        """,
                    ],
                ],
            ],
            [
                "id": "demo-msg-3",
                "role": "user",
                "timestamp": iso(minutesAgo: 30),
                "contentBlocks": [
                    [
                        "type": "text",
                        "text": "What happens if someone requests more than 90 days?",
                    ],
                ],
            ],
            [
                "id": "demo-msg-4",
                "role": "assistant",
                "timestamp": iso(minutesAgo: 12),
                "contentBlocks": [
                    [
                        "type": "text",
                        "text": """
                        The endpoint returns `422 range_too_large` with the max range \
                        in the body, and the dashboard shows an inline hint instead of \
                        a failed download:

                        ```json
                        { "error": "range_too_large", "maxDays": 90 }
                        ```

                        Longer ranges will get a background job + email link in the \
                        follow-up task. The streaming encoder and cap are in — running \
                        the integration tests now.
                        """,
                    ],
                ],
            ],
        ]
    }

    /// Sentence that opens the first (user) message of
    /// `longConversationMessages`; stable anchor for UI tests.
    static let longConversationFirstSentence =
        "Start of the flake investigation: the payment integration suite failed 6 of the last 20 CI runs."

    /// Sentence that closes the last (assistant) message of
    /// `longConversationMessages`; stable anchor for UI tests.
    static let longConversationLastSentence =
        "End of the flake investigation: 50 consecutive green runs on the payment integration suite."

    /// A transcript several screens tall on an iPhone: 32 alternating
    /// user/assistant messages, each a few lines long, so scroll-position UI
    /// (the "Go to End" button) can be exercised against `--demo-data`.
    /// The first message begins with `longConversationFirstSentence` and the
    /// last one ends with `longConversationLastSentence`.
    static var longConversationMessages: [[String: Any]] {
        let exchanges: [(user: String, assistant: String)] = [
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
                """
            ),
        ]

        var messages: [[String: Any]] = []
        let firstMinutesAgo = 240.0
        let lastMinutesAgo = 42.0
        let step = (firstMinutesAgo - lastMinutesAgo) / Double(exchanges.count * 2 - 1)
        for (index, exchange) in exchanges.enumerated() {
            let userOrdinal = index * 2
            let assistantOrdinal = userOrdinal + 1
            messages.append([
                "id": "demo-long-msg-\(userOrdinal + 1)",
                "role": "user",
                "timestamp": iso(minutesAgo: firstMinutesAgo - step * Double(userOrdinal)),
                "contentBlocks": [["type": "text", "text": exchange.user]],
            ])
            messages.append([
                "id": "demo-long-msg-\(assistantOrdinal + 1)",
                "role": "assistant",
                "timestamp": iso(minutesAgo: firstMinutesAgo - step * Double(assistantOrdinal)),
                "contentBlocks": [["type": "text", "text": exchange.assistant]],
            ])
        }
        return messages
    }

    // MARK: - Tasks

    static var tasks: [[String: Any]] {
        [
            [
                "id": "demo-note-csv-task",
                "title": "CSV export with streamed download",
                "status": "in_progress",
                "updatedAt": iso(minutesAgo: 20),
            ],
            [
                "id": "demo-task-flag",
                "title": "Feature flag rollout to beta orgs",
                "status": "not_started",
                "updatedAt": iso(minutesAgo: 240),
            ],
        ]
    }

    // MARK: - Specialists

    static var specialists: [[String: Any]] {
        [
            [
                "id": "implementor",
                "name": "Implementor",
                "description": "Implements a scoped task end to end.",
            ],
            [
                "id": "verifier",
                "name": "Verifier",
                "description": "Reviews and verifies completed work.",
            ],
        ]
    }
}
