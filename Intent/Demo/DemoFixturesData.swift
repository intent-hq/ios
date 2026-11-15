#if DEBUG
import Foundation

extension DemoFixtures {
    // MARK: - Workspaces

    // Literal numeric payloads keep the simulated daemon responses readable and auditable.
    // swiftlint:disable no_magic_numbers

    static var workspaces: [[String: Any]] {
        if LaunchOptions.current.contains("--demo-empty-workspaces") { return [] }
        guard LaunchOptions.current.contains("--demo-long-workspace-list") else { return baseWorkspaces }
        let extra = (0 ..< 20).map { index in
            var workspace = baseWorkspaces[index % baseWorkspaces.count]
            workspace["id"] = "demo-scroll-\(index)"
            workspace["title"] = "Workspace scroll fixture \(index)"
            workspace["lastActivity"] = iso(minutesAgo: Double(200 + index))
            return workspace
        }
        return baseWorkspaces + extra
    }

    private static var baseWorkspaces: [[String: Any]] {
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
                "pullRequests": [
                    [
                        "number": 482,
                        "status": "Open",
                        "title": "feat: usage analytics dashboard with CSV export",
                        "url": "https://github.com/nova-labs/console/pull/482",
                        "updatedAt": iso(minutesAgo: 25)
                    ],
                    [
                        "number": 476,
                        "status": "Merged",
                        "title": "refactor: extract analytics event schema",
                        "url": "https://github.com/nova-labs/console/pull/476",
                        "updatedAt": iso(minutesAgo: 60 * 26)
                    ]
                ] as [[String: Any]],
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
                "agentSummary": ["count": 0, "agents": [[String: Any]]()] as [String: Any],
                "statusImageAssetId": statusImageAssetId,
                "statusMessage": "Dark mode is ready for review across settings screens."
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
}

extension DemoFixtures {
    // MARK: - Notes

    static var notes: [[String: Any]] {
        [
            [
                "id": "demo-note-spec",
                "title": "Spec",
                "isDefault": true,
                "tags": ["spec"],
                "createdAt": iso(minutesAgo: 320),
                "updatedAt": iso(minutesAgo: 18),
                "content": """
                ## Goal

                Add a usage analytics dashboard to the console so admins can see seat activity, API call volume, and export the data for finance.

                ## Tasks

                - [x] [Add usage summary endpoint](intent://local/task/demo-note-summary-task)
                - [x] [Build daily and weekly usage charts](intent://local/task/demo-note-chart-task)
                - [x] [Connect the dashboard route](intent://local/task/demo-note-route-task)
                - [/] [CSV export with streamed download](intent://local/task/demo-note-csv-task)
                - [ ] [Feature flag rollout to beta orgs](intent://local/task/demo-note-rollout-task)

                ## Decisions

                - Reuse the existing `MetricsRollupJob` output table instead of querying raw events — keeps the dashboard queries under 50ms.
                - Export is capped at 90 days per request; longer ranges get a background job + email link in a follow-up.
                """
            ],
            [
                "id": "demo-note-summary-task",
                "title": "Add usage summary endpoint",
                "createdAt": iso(minutesAgo: 280),
                "updatedAt": iso(minutesAgo: 90),
                "metadata": ["task": ["status": "complete"]],
                "content": "Add `/api/usage/summary` with date-range parameters over the rollup table."
            ],
            [
                "id": "demo-note-chart-task",
                "title": "Build daily and weekly usage charts",
                "createdAt": iso(minutesAgo: 270),
                "updatedAt": iso(minutesAgo: 70),
                "metadata": ["task": ["status": "complete"]],
                "content": "Show active seats and API volume with a daily or weekly toggle and 30-day history."
            ],
            [
                "id": "demo-note-route-task",
                "title": "Connect the dashboard route",
                "createdAt": iso(minutesAgo: 260),
                "updatedAt": iso(minutesAgo: 50),
                "metadata": ["task": ["status": "complete"]],
                "content": "Add the dashboard route and navigation entry to the admin console."
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
                "id": "demo-note-rollout-task",
                "title": "Feature flag rollout to beta orgs",
                "createdAt": iso(minutesAgo: 230),
                "updatedAt": iso(minutesAgo: 30),
                "metadata": ["task": ["status": "not_started"]],
                "content": "Enable the usage dashboard for beta organizations and check query latency before broad rollout."
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
}

extension DemoFixtures {
    // MARK: - Agents

    static var agents: [[String: Any]] {
        [
            [
                "id": "demo-agent-implementor",
                "name": "Dashboard Implementor",
                "workspaceId": "demo-ws-dashboard",
                "status": "idle",
                "createdAt": iso(minutesAgo: 260),
                "updatedAt": iso(minutesAgo: 12),
                "lastActivity": iso(minutesAgo: 12),
                "lastMessageRole": "assistant",
                "digest": "[Review **CSV export**](https://github.com/intent-hq/ios)",
                "metadata": ["specialist": "implementor"]
            ],
            [
                "id": "demo-agent-reviewer",
                "name": "PR Reviewer",
                "workspaceId": "demo-ws-dashboard",
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

    /// Agents of `longConversationWorkspaceId`: the single top-level agent
    /// whose transcript is `longConversationMessages` (the only foreground
    /// row on the workspace overview), plus its three delegated sub-agents
    /// (`createdByAgentId`, background) that the coordinator waits on — the
    /// rows of the "Waiting for all" footer.
    static var longConversationAgents: [[String: Any]] {
        let delegateDigests = [
            "Done: after_fork reset landed, 100-run loop clean at 4 workers.",
            "Replacing the fixed 200ms poll with wait_until on refund status.",
            "Running WebhookDeliveryTests against the after_fork branch."
        ]
        let delegateStatuses = ["idle", "active", "streaming"]
        let delegates: [[String: Any]] = longConversationDelegateIds.indices.map { index in
            [
                "id": longConversationDelegateIds[index],
                "workspaceId": longConversationWorkspaceId,
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
                    "isBackground": true
                ] as [String: Any]
            ]
        }
        return [
            [
                "id": longConversationAgentId,
                "name": "Test Stabilizer",
                "workspaceId": longConversationWorkspaceId,
                "status": "idle",
                "isWaitingForOtherAgents": true,
                "waitingForAgentIds": Array(longConversationDelegateIds.dropFirst()),
                "createdAt": iso(minutesAgo: 250),
                "updatedAt": iso(minutesAgo: 42),
                "lastActivity": iso(minutesAgo: 42),
                "lastMessageRole": "assistant",
                "digest": "Payment integration suite is green across 50 consecutive runs.",
                "metadata": ["specialist": "implementor"]
            ]
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
                    "actorIds": longConversationDelegateIds
                ] as [String: Any]
            ],
            "delegationGroups": [
                [
                    "groupId": "demo-group-deflake",
                    "waitMode": "after_all",
                    "expectedAgentIds": longConversationDelegateIds,
                    "completedAgentIds": [longConversationDelegateIds[0]]
                ] as [String: Any]
            ]
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
                "perpetual": false
            ]
        ]
    }
}

extension DemoFixtures {
    // MARK: - Conversation

    static var conversationMessages: [[String: Any]] {
        [
            [
                "id": "demo-msg-1",
                "role": "user",
                "timestamp": transcriptIso(minutesAgo: 65),
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
                "timestamp": transcriptIso(minutesAgo: 62),
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
                "timestamp": transcriptIso(minutesAgo: 30),
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
                "timestamp": transcriptIso(minutesAgo: 12),
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
}

extension DemoFixtures {
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
}
// swiftlint:enable no_magic_numbers
#endif
