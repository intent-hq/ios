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

    /// Sub-agents delegated by `longConversationAgentId`, in the order they
    /// appear in the transcript's agent-to-agent rows. `agent.getSubscriptions`
    /// for the coordinator reports one delegation group over all three with
    /// the first already complete, so the conversation opens with the
    /// "Waiting for all (1/3)" footer already under the transcript.
    static let longConversationDelegateIds = [
        "demo-agent-deflake-capture",
        "demo-agent-deflake-refund",
        "demo-agent-deflake-webhooks",
    ]

    static let longConversationDelegateNames = [
        "Capture Race Fixer",
        "Refund Settlement Fixer",
        "Webhook Regression Check",
    ]

    /// Name of the single scheduled hook `hook.list` serves for
    /// `longConversationAgentId`. Rendered as a chip in the hooks row above
    /// the composer; the row's own label is "Running hooks".
    static let longConversationHookName = "Wait for CI on flake fix"

    /// What `hook.list` for `longConversationWorkspaceId` waits on before
    /// answering, so the hooks row appears under an already-settled
    /// transcript — the container-resize path of #272 under `--demo-data`
    /// (`ConversationTranscriptScrollUITests`). Every other fixture answers
    /// immediately. The default delay suits the screenshot flows; a UI test
    /// that must observe the transcript before the row lands passes
    /// `--demo-hook-list-trigger-file=<path>` and creates that file when it
    /// is ready — a clock cannot be made robust against the render time of a
    /// loaded CI simulator.
    static let longConversationHookListGate = hookListGate(from: ProcessInfo.processInfo.arguments)

    static let defaultHookListDelay: Duration = .seconds(4)

    static let hookListDelayArgumentPrefix = "--demo-hook-list-delay-ms="

    static let hookListTriggerFileArgumentPrefix = "--demo-hook-list-trigger-file="

    /// What `agent.getMessageBlock` for `longConversationAgentId` waits on
    /// before answering: the slow-network hydration of the slim-truncated
    /// tool rows near the end of the long transcript
    /// (`longConversationTruncatedToolCalls`), so a row re-measures seconds
    /// after the entry follow has landed (intent-hq/ios#338). Same shape as
    /// the hooks-row gate: a delay by default, or
    /// `--demo-block-hydration-trigger-file=<path>` for a UI test that
    /// releases the hydration itself.
    static let longConversationBlockHydrationGate = blockHydrationGate(from: ProcessInfo.processInfo.arguments)

    static let defaultBlockHydrationDelay: Duration = .seconds(4)

    static let blockHydrationDelayArgumentPrefix = "--demo-block-hydration-delay-ms="

    static let blockHydrationTriggerFileArgumentPrefix = "--demo-block-hydration-trigger-file="

    /// Polling cadence for `ResponseGate.triggerFile`.
    static let triggerFilePollInterval: Duration = .milliseconds(100)

    /// Condition a fixture response waits on before it is served.
    enum ResponseGate: Equatable {
        case delay(Duration)
        /// Served once the file exists; waits indefinitely otherwise.
        case triggerFile(URL)
    }

    /// `.triggerFile` when the arguments carry a non-empty
    /// `--demo-hook-list-trigger-file=<path>` (the last one wins);
    /// otherwise `.delay` of `hookListDelay(from:)`.
    static func hookListGate(from arguments: [String]) -> ResponseGate {
        gate(from: arguments,
             triggerFilePrefix: hookListTriggerFileArgumentPrefix,
             delayPrefix: hookListDelayArgumentPrefix,
             defaultDelay: defaultHookListDelay)
    }

    /// `defaultHookListDelay` unless the arguments carry a well-formed
    /// `--demo-hook-list-delay-ms=<milliseconds>`; the last one wins.
    static func hookListDelay(from arguments: [String]) -> Duration {
        delay(from: arguments, prefix: hookListDelayArgumentPrefix, defaultDelay: defaultHookListDelay)
    }

    /// `.triggerFile` when the arguments carry a non-empty
    /// `--demo-block-hydration-trigger-file=<path>` (the last one wins);
    /// otherwise `.delay` of `blockHydrationDelay(from:)`.
    static func blockHydrationGate(from arguments: [String]) -> ResponseGate {
        gate(from: arguments,
             triggerFilePrefix: blockHydrationTriggerFileArgumentPrefix,
             delayPrefix: blockHydrationDelayArgumentPrefix,
             defaultDelay: defaultBlockHydrationDelay)
    }

    /// `defaultBlockHydrationDelay` unless the arguments carry a well-formed
    /// `--demo-block-hydration-delay-ms=<milliseconds>`; the last one wins.
    static func blockHydrationDelay(from arguments: [String]) -> Duration {
        delay(from: arguments, prefix: blockHydrationDelayArgumentPrefix, defaultDelay: defaultBlockHydrationDelay)
    }

    private static func gate(
        from arguments: [String], triggerFilePrefix: String, delayPrefix: String, defaultDelay: Duration
    ) -> ResponseGate {
        let path = arguments
            .filter { $0.hasPrefix(triggerFilePrefix) }
            .map { String($0.dropFirst(triggerFilePrefix.count)) }
            .last { !$0.isEmpty }
        if let path { return .triggerFile(URL(fileURLWithPath: path)) }
        return .delay(delay(from: arguments, prefix: delayPrefix, defaultDelay: defaultDelay))
    }

    private static func delay(from arguments: [String], prefix: String, defaultDelay: Duration) -> Duration {
        let milliseconds = arguments
            .filter { $0.hasPrefix(prefix) }
            .compactMap { Int($0.dropFirst(prefix.count)) }
            .last { $0 >= 0 }
        guard let milliseconds else { return defaultDelay }
        return .milliseconds(milliseconds)
    }

    /// Gate to wait on before serving `response(for:params:)`, or nil for an
    /// immediate answer.
    static func responseGate(for method: String, params: [String: Any]) -> ResponseGate? {
        switch method {
        case "hook.list" where params["workspaceId"] as? String == longConversationWorkspaceId:
            return longConversationHookListGate
        case "agent.getMessageBlock" where params["agentId"] as? String == longConversationAgentId:
            return longConversationBlockHydrationGate
        default:
            return nil
        }
    }

    /// Suspends until `gate` opens; cancellation propagates from `Task.sleep`.
    static func wait(for gate: ResponseGate) async throws {
        switch gate {
        case .delay(let duration):
            try await Task.sleep(for: duration)
        case .triggerFile(let url):
            while !FileManager.default.fileExists(atPath: url.path) {
                try await Task.sleep(for: triggerFilePollInterval)
            }
        }
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
        case "agent.getMessageBlock":
            let blockId = params["blockId"] as? String
            guard let block = longConversationFullBlock(id: blockId) else { return [String: Any]() }
            return ["block": block]
        case "agent.getQueue":
            return ["queue": [[String: Any]]()]
        case "agent.getSubscriptions":
            let agentId = params["agentId"] as? String
            return agentId == longConversationAgentId ? longConversationSubscriptions : [String: Any]()
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

    /// Agents of `longConversationWorkspaceId`: the single top-level agent
    /// whose transcript is `longConversationMessages` (still the only
    /// foreground agent, so the workspace row auto-opens into it), plus its
    /// three delegated sub-agents (`createdByAgentId`, background) that the
    /// coordinator waits on — the rows of the "Waiting for all" footer.
    static var longConversationAgents: [[String: Any]] {
        let delegateDigests = [
            "Done: after_fork reset landed, 100-run loop clean at 4 workers.",
            "Replacing the fixed 200ms poll with wait_until on refund status.",
            "Running WebhookDeliveryTests against the after_fork branch.",
        ]
        let delegateStatuses = ["idle", "active", "streaming"]
        let delegates: [[String: Any]] = longConversationDelegateIds.indices.map { index in
            [
                "id": longConversationDelegateIds[index],
                "name": longConversationDelegateNames[index],
                "status": delegateStatuses[index],
                "isStreaming": index == 2,
                "createdAt": iso(minutesAgo: 200 - Double(index) * 30),
                "updatedAt": iso(minutesAgo: 50 - Double(index) * 3),
                "lastActivity": iso(minutesAgo: 50 - Double(index) * 3),
                "lastMessageRole": "assistant",
                "digest": delegateDigests[index],
                "metadata": [
                    "specialist": index == 2 ? "verifier" : "implementor",
                    "createdByAgentId": longConversationAgentId,
                    "isBackground": true,
                ] as [String: Any],
            ]
        }
        return [
            [
                "id": longConversationAgentId,
                "name": "Test Stabilizer",
                "status": "idle",
                "isWaitingForOtherAgents": true,
                "waitingForAgentIds": Array(longConversationDelegateIds.dropFirst()),
                "createdAt": iso(minutesAgo: 250),
                "updatedAt": iso(minutesAgo: 42),
                "lastActivity": iso(minutesAgo: 42),
                "lastMessageRole": "assistant",
                "digest": "Payment integration suite is green across 50 consecutive runs.",
                "metadata": ["specialist": "implementor"],
            ],
        ] + delegates
    }

    /// `agent.getSubscriptions` for `longConversationAgentId` (PROTOCOL
    /// §5.5): one `after_all` delegation group over
    /// `longConversationDelegateIds` with the first delegate complete, so the
    /// conversation enters with the "Waiting for all (1/3)" footer.
    static var longConversationSubscriptions: [String: Any] {
        [
            "subscriptions": [
                [
                    "subscriptionId": "demo-sub-deflake-group",
                    "eventTypes": ["agent:completed", "agent:error"],
                    "actorIds": longConversationDelegateIds,
                ] as [String: Any],
            ],
            "delegationGroups": [
                [
                    "groupId": "demo-group-deflake",
                    "waitMode": "after_all",
                    "expectedAgentIds": longConversationDelegateIds,
                    "completedAgentIds": [longConversationDelegateIds[0]],
                ] as [String: Any],
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

    /// Suggested prompts carried by the last (assistant) message of
    /// `longConversationMessages` as a trailing `<!-- suggested-prompts -->`
    /// block, so the transcript's prompt rows — and the scroll transition
    /// when one is tapped — can be exercised against `--demo-data`.
    static let longConversationSuggestedPrompts = [
        "Open a PR for the deflake changes",
        "Show me the final evidence table",
        "Schedule the worker scaling follow-up",
    ]

    /// Tool rows the slim projection truncates (PROTOCOL §5.5), carried by
    /// the last assistant messages of `longConversationMessages` after their
    /// opening paragraph — the first entry by the very last message, the
    /// second by the assistant message of the exchange before it: a `view` of `file` whose
    /// `tool_result` is served as a bounded preview with `outputTruncated`,
    /// and whose full listing `agent.getMessageBlock` returns through
    /// `longConversationBlockHydrationGate`. Expanding the row re-measures
    /// it once the full body merges in — the late re-layout near the end of
    /// an already-settled transcript of intent-hq/ios#338.
    static let longConversationTruncatedToolCalls: [(id: String, file: String, symbol: String)] = [
        ("demo-long-slim-tool-1", "tests/payments/evidence/final_evidence_table.py", "render_final_evidence"),
        ("demo-long-slim-tool-2", "tests/payments/evidence/repro_loop_report.py", "summarize_repro_loop"),
    ]

    /// Characters of the full `tool_result` output the slim row keeps.
    static let longConversationTruncatedOutputPreviewLength = 160

    /// The full `tool_result` block (no truncation flags) for one of
    /// `longConversationTruncatedToolCalls` by its result block id, or nil.
    static func longConversationFullBlock(id blockId: String?) -> [String: Any]? {
        guard let call = longConversationTruncatedToolCalls.first(where: { "\($0.id)-result" == blockId }) else {
            return nil
        }
        return toolResultBlock(toolUseId: call.id, output: longConversationFullOutput(for: call))
    }

    /// The slim `tool_use` / `tool_result` pair for `call`: the full input,
    /// and the first `longConversationTruncatedOutputPreviewLength`
    /// characters of the listing flagged `outputTruncated`.
    private static func truncatedToolBlocks(_ call: (id: String, file: String, symbol: String)) -> [[String: Any]] {
        let output = longConversationFullOutput(for: call)
        var result = toolResultBlock(
            toolUseId: call.id, output: String(output.prefix(longConversationTruncatedOutputPreviewLength)))
        result["outputTruncated"] = true
        result["outputBytes"] = output.utf8.count
        return [
            toolUseBlock(id: call.id, name: "view", input: ["path": call.file]),
            result,
        ]
    }

    /// A ~60-line numbered listing of `call.file`, several screens of
    /// monospaced output once hydrated.
    private static func longConversationFullOutput(for call: (id: String, file: String, symbol: String)) -> String {
        var lines = [
            "\(call.file)",
            "   1 | \"\"\"Evidence rendering for the flake investigation.\"\"\"",
            "   2 | from dataclasses import dataclass",
            "   3 | from statistics import quantiles",
            "   4 | ",
            "   5 | ",
            "   6 | @dataclass(frozen=True)",
            "   7 | class RunSample:",
            "   8 |     workers: int",
            "   9 |     duration_seconds: float",
            "  10 |     failures: int",
            "  11 | ",
            "  12 | ",
            "  13 | def \(call.symbol)(samples: list[RunSample]) -> str:",
            "  14 |     rows = [\"| Run | Workers | Duration | Failures |\", \"|-----|---------|----------|----------|\"]",
        ]
        for run in 1...40 {
            let line = 14 + run
            let index = run - 1
            lines.append("  \(line) |     rows.append(f\"| \(run) | {samples[\(index)].workers} | "
                + "{samples[\(index)].duration_seconds:.1f}s | {samples[\(index)].failures} |\")")
        }
        lines += [
            "  55 |     p50, p90 = quantiles([s.duration_seconds for s in samples], n=10)[4], quantiles([s.duration_seconds for s in samples], n=10)[8]",
            "  56 |     rows.append(f\"| p50 | — | {p50:.1f}s | — |\")",
            "  57 |     rows.append(f\"| p90 | — | {p90:.1f}s | — |\")",
            "  58 |     return \"\\n\".join(rows)",
        ]
        return lines.joined(separator: "\n")
    }

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
    static var longConversationMessages: [[String: Any]] {
        let suggestedPromptsBlock = (["<!-- suggested-prompts"] + longConversationSuggestedPrompts + ["-->"])
            .joined(separator: "\n")
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

                \(suggestedPromptsBlock)
                """
            ),
        ]

        var rows: [LongConversationRow] = []
        for (index, exchange) in exchanges.enumerated() {
            rows.append(LongConversationRow(role: "user", contentBlocks: [textBlock(exchange.user)]))
            // The last assistant messages carry a slim-truncated tool row after
            // their opening paragraph (see `longConversationTruncatedToolCalls`):
            // below the navigation bar once the transcript rests at the end,
            // so a UI test can tap it, and above the closing paragraph.
            let truncatedCallIndex = exchanges.count - 1 - index
            let assistantBlocks: [[String: Any]]
            if truncatedCallIndex < longConversationTruncatedToolCalls.count,
               let paragraphBreak = exchange.assistant.range(of: "\n\n") {
                assistantBlocks = [textBlock(String(exchange.assistant[..<paragraphBreak.lowerBound]))]
                    + truncatedToolBlocks(longConversationTruncatedToolCalls[truncatedCallIndex])
                    + [textBlock(String(exchange.assistant[paragraphBreak.upperBound...]))]
            } else {
                assistantBlocks = [textBlock(exchange.assistant)]
            }
            rows.append(LongConversationRow(role: "assistant", contentBlocks: assistantBlocks))
            if index < exchanges.count - 1 {
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
                "contentBlocks": row.contentBlocks,
            ]
            if let metadata = row.metadata { message["metadata"] = metadata }
            return message
        }
    }

    /// One `longConversationMessages` row before its id and timestamp are
    /// assigned.
    private struct LongConversationRow {
        var role: String
        var contentBlocks: [[String: Any]]
        var metadata: [String: Any]?
    }

    private static func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    private static func toolUseBlock(id: String, name: String, input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    private static func toolResultBlock(toolUseId: String, output: String) -> [String: Any] {
        ["type": "tool_result", "id": "\(toolUseId)-result", "toolUseId": toolUseId, "output": output]
    }

    /// A user-role row sent by delegate `index` (PROTOCOL §5.5 agent-to-agent
    /// attribution on the row metadata and the text block's `messageMetadata`).
    private static func delegateRow(_ index: Int, text: String) -> LongConversationRow {
        let attribution: [String: Any] = [
            "type": "agent_message",
            "fromAgentId": longConversationDelegateIds[index],
            "fromAgentName": longConversationDelegateNames[index],
        ]
        var block = textBlock(text)
        block["messageMetadata"] = attribution
        return LongConversationRow(role: "user", contentBlocks: [block], metadata: attribution)
    }

    /// Per-round subject matter for `longConversationRound(_:)`; one entry
    /// per gap between handwritten exchanges.
    private static let longConversationRoundTopics: [(
        subject: String, file: String, symbol: String, command: String, metric: String
    )] = [
        ("stream id reuse after fork", "tests/payments/conftest.py", "PaymentClient.shared", "pytest tests/payments -n 4 --count 25", "7 timeouts in 100 runs"),
        ("the pre-warmed pool inheritance", "payments/client/pool.py", "Http2Pool.warm", "pytest tests/payments/test_capture.py -n 4", "20–30s first-request stalls"),
        ("the local reproduction loop", "scripts/repro_flake.sh", "run_loop", "scripts/repro_flake.sh --workers 4 --repeat 25", "7/100 failing, 0/100 single-worker"),
        ("the after_fork reset hook", "tests/payments/hooks.py", "_reset_payment_client", "pytest tests/payments -n 4 --count 25 -p hooks", "0 timeouts in 100 runs"),
        ("the stale ledger read", "tests/payments/test_refund.py", "test_refund_partial_amount", "pytest tests/payments/test_refund.py -n 4 --count 50", "3 stale reads in 50 runs"),
        ("the settlement status poll", "tests/payments/helpers/wait.py", "wait_until", "pytest tests/payments/test_refund.py --count 50", "settled p99 3.4s"),
        ("first-request latency per worker", "payments/client/metrics.py", "record_first_request", "scripts/repro_flake.sh --workers 4 --repeat 25 --metrics", "median 140ms, was 1.8s"),
        ("webhook test isolation", "tests/webhooks/test_delivery.py", "WebhookDeliveryTests", "pytest tests/webhooks -n 4", "48 passed, 0 shared-client uses"),
        ("the known-flake taxonomy", "docs/testing/flakes.md", "Known flake sources", "make docs-check", "3 rows, 3 links"),
        ("sandbox rate limiting", "payments/client/backoff.py", "RetryPolicy.for_429", "scripts/repro_flake.sh --workers 8 --repeat 10", "55 rps at 6 workers, 429s at 8"),
        ("the CI branch run", ".github/workflows/payments.yml", "payments-integration", "gh run watch 88123", "green in 5m12s"),
        ("the overnight matrix", ".github/workflows/payments-matrix.yml", "matrix.repeat", "gh workflow run payments-matrix.yml -f repeat=50", "50 scheduled, 10 min apart"),
        ("the duration distribution", "scripts/collect_durations.py", "percentiles", "scripts/collect_durations.py --runs 50", "p50 5m04s, p90 5m31s, max 6m02s"),
        ("the retry decorators", "tests/payments/test_capture.py", "@retry(3)", "rg -n 'retry\\(3\\)' tests/payments", "3 decorators removed"),
        ("the README sandbox key steps", "README.md", "PAYMENT_SANDBOX_KEY", "git clone … && make repro", "end to end in ~4 min"),
    ]

    /// The delegation round inserted after handwritten exchange `round`:
    /// nine rows of deliberately uneven height — a tool-call group, three
    /// agent-to-agent reports, a delegation tool call, markdown replies with
    /// code fences / tables / a thinking block, and one human follow-up.
    private static func longConversationRound(_ round: Int) -> [LongConversationRow] {
        let topic = longConversationRoundTopics[round]
        let ordinal = round + 1
        let toolPrefix = "demo-long-tool-\(ordinal)"
        let reporter = round % 3
        let secondReporter = (round + 1) % 3
        let thirdReporter = (round + 2) % 3
        let repeatedParagraph = "Nothing in the production path changes for this step; the only writes " +
            "are under `tests/` and the scripts folder, so review scope stays narrow."
        let filler = Array(repeating: repeatedParagraph, count: round % 3 + 1).joined(separator: "\n\n")

        let investigation = LongConversationRow(role: "assistant", contentBlocks: [
            textBlock("""
            <group:Investigating \(topic.subject)>
            Reading `\(topic.file)` around `\(topic.symbol)` and re-running the narrow command before delegating.
            """),
            toolUseBlock(id: "\(toolPrefix)-view", name: "view", input: [
                "path": topic.file,
                "search_query_regex": topic.symbol,
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
                "wait": true,
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
            """),
        ])

        let firstReportStatus = round % 2 == 0
            ? "Patch is ready; running the loop once more before I report it done"
            : "Still bisecting the second failure mode; will report within the hour"
        let firstReportCode = round % 2 == 0 ? """
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

        let table = round % 3 == 0 ? """

        | Run | Workers | Result |
        |-----|---------|--------|
        | 1 | 4 | \(topic.metric) |
        | 2 | 4 | \(topic.metric) |
        | 3 | 1 | clean |
        """ : ""
        let reply = LongConversationRow(role: "assistant", contentBlocks: [textBlock("""
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
        """)])

        let delegation = LongConversationRow(role: "assistant", contentBlocks: [
            textBlock("Delegating the verification of \(topic.subject) so it runs in parallel with the fix."),
            toolUseBlock(id: "\(toolPrefix)-delegate", name: "workspace_api", input: [
                "code": "return await ws.agent.delegate({ taskNoteId: \"demo-task-round-\(ordinal)\", specialist: \"verifier\", waitMode: \"after_all\" })",
                "summary": "Delegate verification of \(topic.subject)",
            ]),
            toolResultBlock(toolUseId: "\(toolPrefix)-delegate", output: """
            {"ok":true,"agentId":"\(longConversationDelegateIds[thirdReporter])","waitMode":"after_all","summary":{"started":1,"held":0,"skipped":0}}
            """),
            textBlock("Delegated; I will pick the evidence up when the group settles."),
        ])

        let secondReport = delegateRow(secondReporter, text: """
        Verification of \(topic.subject) is under way. First pass: `\(topic.command)` → \(topic.metric). \
        I am repeating it with `--count 50` to get a distribution rather than a single sample.
        """)

        var summaryBlocks: [[String: Any]] = []
        if round % 2 == 1 {
            summaryBlocks.append([
                "type": "thinking",
                "text": "Both delegates agree on \(topic.metric). The remaining risk is ordering, not connectivity; " +
                    "check the settlement path before closing round \(ordinal).",
            ])
        }
        let bullets = (0..<(round % 4 + 2)).map { bullet in
            "- Sample \(bullet + 1): `\(topic.command)` → \(topic.metric)"
        }.joined(separator: "\n")
        summaryBlocks.append(textBlock("""
        Round \(ordinal) summary for \(topic.subject):

        \(bullets)

        The fix stays inside `\(topic.file)`. \(filler)
        """))
        let summary = LongConversationRow(role: "assistant", contentBlocks: summaryBlocks)

        let followUp = LongConversationRow(role: "user", contentBlocks: [textBlock(
            round % 2 == 0
                ? "Does round \(ordinal) change anything for the webhook tests?"
                : "How long did round \(ordinal) take end to end?")])

        let bigTable = round % 4 == 0 ? """

        | Test | Before | After |
        |------|--------|-------|
        | capture_settles_after_authorization | 20–30s timeout | 140ms |
        | refund_partial_amount | stale balance | settled |
        | capture_3ds_challenge | 14s | 14s |
        | webhook_delivery_retry | 2.1s | 2.1s |
        | capture_idempotent_replay | 380ms | 120ms |
        | refund_full_amount | 900ms | 410ms |
        """ : ""
        let answerLead = round % 2 == 0
            ? "No: the webhook tests build their own `PaymentClient(base_url=...)` per test and never touch " +
                "the shared pool, so round \(ordinal) leaves them untouched."
            : "About \(9 + round) minutes end to end, most of it the `--count 50` loop; the patch itself was a few lines."
        let answer = LongConversationRow(role: "assistant", contentBlocks: [textBlock("""
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
        """)])

        let thirdReport = delegateRow(thirdReporter, text: """
        Evidence for \(topic.subject), 50 runs:

        | Metric | Value |
        |--------|-------|
        | Failures | 0 |
        | Median | 5m04s |
        | Max | 6m02s |

        Attached the per-run log to the task note and marked the verification complete.
        """)

        return [
            investigation, firstReport, reply, delegation, secondReport,
            summary, followUp, answer, thirdReport,
        ]
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
