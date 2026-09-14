import Foundation

/// Launch-argument-driven demo mode for screenshot UI tests: with
/// `--demo-data` the app skips pairing and serves fixture data from
/// `DemoFixtures` instead of a live daemon connection. Zero-impact when the
/// arguments are absent.
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
            return ["agents": agents]
        case "agent.get":
            let agentId = params["agentId"] as? String
            let agent = agents.first { ($0["id"] as? String) == agentId } ?? agents[0]
            return ["agent": agent]
        case "agent.getConversation":
            return [
                "messages": conversationMessages,
                "truncated": false,
                "totalMessages": conversationMessages.count
            ] as [String: Any]
        case "agent.getQueue":
            return ["queue": [[String: Any]]()]
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
                            "lastActivity": iso(minutesAgo: 12)
                        ],
                        [
                            "id": "demo-agent-reviewer",
                            "name": "PR Reviewer",
                            "status": "running",
                            "specialist": "verifier",
                            "isResponding": true,
                            "lastActivity": iso(minutesAgo: 2)
                        ]
                    ] as [[String: Any]]
                ] as [String: Any],
                "activePullRequest": [
                    "number": 482,
                    "status": "Open",
                    "title": "feat: usage analytics dashboard with CSV export",
                    "updatedAt": iso(minutesAgo: 25)
                ] as [String: Any]
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
                            "lastActivity": iso(minutesAgo: 1)
                        ]
                    ] as [[String: Any]]
                ] as [String: Any]
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
                "agentSummary": ["count": 0, "agents": [[String: Any]]()] as [String: Any]
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
                            "lastActivity": iso(minutesAgo: 42)
                        ]
                    ] as [[String: Any]]
                ] as [String: Any]
            ]
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
                """
            ],
            [
                "id": "demo-note-csv-task",
                "title": "CSV export with streamed download",
                "createdAt": iso(minutesAgo: 240),
                "updatedAt": iso(minutesAgo: 20),
                "metadata": [
                    "task": [
                        "status": "in_progress",
                        "assignedAgentIds": ["demo-agent-implementor"]
                    ] as [String: Any]
                ] as [String: Any],
                "content": """
                # CSV export with streamed download

                Stream the usage rows as CSV instead of buffering the whole \
                range in memory — the 90-day export for large orgs is ~40MB.

                - [x] Chunked encoder over the rollup cursor
                - [x] Content-Disposition + progress header plumbing
                - [ ] Integration test for the 90-day cap error
                """
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
                """
            ]
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
                "metadata": ["specialist": "implementor"]
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
                "metadata": ["specialist": "verifier"]
            ]
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
                        "text": "Add the CSV export for the usage dashboard. Finance wants the same column layout as the old billing export."
                    ]
                ]
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
                        """
                    ]
                ]
            ],
            [
                "id": "demo-msg-3",
                "role": "user",
                "timestamp": iso(minutesAgo: 30),
                "contentBlocks": [
                    [
                        "type": "text",
                        "text": "What happens if someone requests more than 90 days?"
                    ]
                ]
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
                        """
                    ]
                ]
            ]
        ]
    }

    // MARK: - Tasks

    static var tasks: [[String: Any]] {
        [
            [
                "id": "demo-note-csv-task",
                "title": "CSV export with streamed download",
                "status": "in_progress",
                "updatedAt": iso(minutesAgo: 20)
            ],
            [
                "id": "demo-task-flag",
                "title": "Feature flag rollout to beta orgs",
                "status": "not_started",
                "updatedAt": iso(minutesAgo: 240)
            ]
        ]
    }

    // MARK: - Specialists

    static var specialists: [[String: Any]] {
        [
            [
                "id": "implementor",
                "name": "Implementor",
                "description": "Implements a scoped task end to end."
            ],
            [
                "id": "verifier",
                "name": "Verifier",
                "description": "Reviews and verifies completed work."
            ]
        ]
    }
}
