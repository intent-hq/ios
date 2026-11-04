#if DEBUG
import Foundation

extension DemoDesignFixtures {
    // Exact fixture payload literals, not production layout or timing constants.
    // swiftlint:disable no_magic_numbers
    static let timestamp = "2026-09-26T09:41:00Z"
    static let assistantText = "Worth adding tests? There is no test runner configured, so verification stayed on the build plus browser inspection."
    static let userText = "Error isn't using the correct icon, it should use attention circle not fill"
    static let comparisonTable = """
    | Setup | Filed | Theme accuracy | Sub-theme accuracy | Duplicate names | Time | Peak memory |
    | :--- | ---: | ---: | ---: | :---: | ---: | ---: |
    | Baseline with descriptive theme names and a separate validation pass for every incoming document | 120 | 62.2% | 58.4% | 12 | 4.9 min | 512 MB |
    | Batched setup with shared context | 124 | 91.3% | 87.6% | 0 | 2.1 min | 384 MB |
    """
    // Four long parallel paths keep both axes larger than the inline phone viewport.
    static let mermaidDiagram = """
    Before the interactive diagram.

    ```mermaid
    flowchart TB
        A1[Collect requests] --> A2[Validate input] --> A3[Prepare records] --> A4[Write storage]
        A4 --> A5[Read results] --> A6[Review changes] --> A7[Publish update] --> A8[Archive request]
        B1[Collect events] --> B2[Validate events] --> B3[Prepare batches] --> B4[Write event log]
        B4 --> B5[Read event log] --> B6[Review events] --> B7[Publish events] --> B8[Archive events]
        C1[Collect metrics] --> C2[Validate metrics] --> C3[Prepare samples] --> C4[Write samples]
        C4 --> C5[Read samples] --> C6[Review metrics] --> C7[Publish metrics] --> C8[Archive metrics]
        D1[Collect reports] --> D2[Validate reports] --> D3[Prepare summaries] --> D4[Write summaries]
        D4 --> D5[Read summaries] --> D6[Review reports] --> D7[Publish reports] --> D8[Archive reports]
    ```

    After the interactive diagram.
    """
    static let blockerText = """
    The sub-15-minute hosted CI measurement is held because current GitHub permissions cannot verify \
    macos-15-xlarge access (runner inventory returns 403). The user is checking with an organization admin. \
    Need confirmation that intent-ha/ios has runner access, paid usage and capacity before publication and the \
    one authorized hosted run. Local review and the single local gate are finished; no extra runs or settings \
    changes will be attempted.
    """

    static var mermaidHistory: [[String: Any]] {
        (0..<4).flatMap { turn in
            let explanation = Array(repeating: "The app loads its transcript, prepares each message, and preserves the current reading position while diagrams render.", count: 8).joined(separator: "\n\n")
            let sectionCount = turn == 0 ? 3 : 2
            let sections = (0..<sectionCount).map { section in
                let diagram = mermaidDiagram.replacingOccurrences(
                    of: "flowchart TB", with: "flowchart TB\n    %% Architecture \(turn).\(section)"
                )
                return "## Architecture section \(turn + 1).\(section + 1)\n\n\(explanation)\n\n\(diagram)"
            }
            .joined(separator: "\n\n")
            return [
                message(id: "diagram-question-\(turn)", role: "user", blocks: [DemoFixtures.textBlock("Explain architecture section \(turn + 1).")]),
                message(id: "diagram-answer-\(turn)", role: "assistant", blocks: [DemoFixtures.textBlock("\(sections)\n\nArchitecture answer \(turn + 1) is complete.")])
            ]
        }
    }

    var workspace: [String: Any] {
        var result: [String: Any] = [
            "id": Self.workspaceId, "title": "Workspace agent design", "branch": "design/agent-conversation",
            "baseRef": "main", "status": "active", "activity": isStreaming ? "agent_running" : "idle",
            "displayStatus": hasQuestions || scenario == .blocker ? "needs_attention" : "in_progress",
            "attention": hasQuestions || scenario == .blocker ? "unread" : "none",
            "lastActivity": Self.timestamp, "updatedAt": Self.timestamp,
            "repositoryOwner": "intent-ha", "repositoryName": "ios",
            "agentSummary": ["count": 1, "agents": [agent]]
        ]
        if scenario == .context {
            result["title"] = "Build Spec Writer Page"
            result["taskStats"] = ["total": 3, "completed": 3, "inProgress": 0]
        }
        return result
    }

    var agent: [String: Any] {
        [
            "id": Self.agentId, "workspaceId": Self.workspaceId, "name": Self.agentName,
            "status": isStreaming ? "running" : "idle", "isResponding": isStreaming,
            "createdAt": Self.timestamp, "updatedAt": Self.timestamp, "lastActivity": Self.timestamp,
            "lastMessageRole": "assistant",
            "model": modelId, "provider": providerId, "reasoningEffort": reasoningEffort as Any? ?? NSNull(),
            "metadata": [
                "pendingQuestionsMessageId": pendingQuestionId,
                "dismissedQuestionsMessageId": questionsDismissed ? Self.questionMessageId : "",
                "lastSeenMessageId": (messages.last?["id"] as? String) ?? ""
            ]
        ]
    }

    var contextNotes: [[String: Any]] {
        let titles = [
            "Implement Figma discovery and safe icon swapping",
            "Build the icon gallery interface",
            "Verify plugin build and interaction coverage"
        ]
        let spec: [String: Any] = [
            "id": "spec", "title": "Spec", "isDefault": true, "content": "# Implementation Plan",
            "createdAt": Self.timestamp, "updatedAt": Self.timestamp
        ]
        let preferences: [String: Any] = [
            "id": "preferences", "title": "Preferences", "content": "# Document Preferences",
            "createdAt": Self.timestamp, "updatedAt": Self.timestamp
        ]
        return [spec, preferences] + titles.enumerated().map { index, title in
            [
                "id": "context-task-\(index)", "title": title, "parentId": "spec",
                "content": "Task details for \(title).", "metadata": ["task": ["status": "complete"]],
                "createdAt": "2026-09-26T09:42:0\(index)Z", "updatedAt": Self.timestamp
            ]
        }
    }

    var monitor: [String: Any] {
        let repo = ProcessInfo.processInfo.arguments.contains("--demo-long-pr-label") ? "intent-hq/intentd" : "intent-ha/ios"
        return [
            "monitorId": Self.monitorId, "workspaceId": Self.workspaceId, "agentId": Self.agentId,
            "repo": repo, "prNumber": 56, "state": monitorCancelled ? "cancelled" : "active",
            "title": "Use the attention circle icon", "createdAt": Self.timestamp, "updatedAt": Self.timestamp,
            "pendingChanges": [String](), "hasPendingChanges": false,
            "lastSnapshot": [
                "state": "OPEN", "isDraft": false, "hasConflicts": false, "isBehind": false,
                "mergeable": false, "checks": ["total": 2, "passed": 1, "failed": 0, "pending": 1],
                "approvals": ["decision": "REVIEW_REQUIRED", "have": 0, "needed": 1, "changesRequested": 0],
                "threads": ["unresolved": 0]
            ]
        ]
    }

    var initialMessages: [[String: Any]] {
        if scenario == .empty { return [] }
        if scenario == .mermaidHistory { return Self.mermaidHistory }
        if scenario == .claudeTools {
            let blocks = [
                DemoFixtures.toolUseBlock(id: "demo-claude-search", name: "ToolSearch", input: [
                    "_acpTitle": "ToolSearch", "max_results": 1,
                    "query": "select:mcp__workspace-mcp__workspace_api"
                ]),
                DemoFixtures.toolResultBlock(toolUseId: "demo-claude-search", output: "Loaded workspace_api"),
                DemoFixtures.toolUseBlock(id: "demo-claude-glob", name: "Glob", input: ["pattern": "src/**/*.swift"]),
                DemoFixtures.toolResultBlock(toolUseId: "demo-claude-glob", output: "src/main.swift")
            ]
            return [Self.message(id: "demo-claude-tools", role: "assistant", blocks: blocks)]
        }
        var rows = [
            Self.message(id: "demo-design-assistant", role: "assistant", blocks: [DemoFixtures.textBlock(Self.assistantText)]),
            Self.message(id: "demo-design-user", role: "user", blocks: [DemoFixtures.textBlock(Self.userText)]),
            Self.message(id: "demo-design-tools", role: "assistant", blocks: Self.toolBlocks)
        ]
        if scenario == .mermaid {
            rows.append(Self.message(id: "demo-design-mermaid", role: "assistant", blocks: [DemoFixtures.textBlock(Self.mermaidDiagram)]))
        }
        if scenario == .tables {
            let text = """
            Comparison results before the table.

            \(Self.comparisonTable)

            Comparison complete after the table.

            \(Array(repeating: "These results keep the original document order and include the validation pass.", count: 8).joined(separator: "\n\n"))

            End of the table comparison.
            """
            rows.append(Self.message(id: "demo-design-table", role: "assistant", blocks: [DemoFixtures.textBlock(text)]))
        }
        if scenario == .blocker {
            rows.append(Self.message(id: "demo-design-blocker", role: "system", blocks: [
                ["type": "text", "text": Self.blockerText, "meta": ["kind": "blocker-report"]]
            ]))
        }
        if hasQuestions {
            rows.append(Self.message(id: Self.questionMessageId, role: "assistant", blocks: questionBlocks))
        }
        if scenario == .watcher { rows.append(Self.watcherMessage) }
        return rows
    }

    private static var watcherMessage: [String: Any] {
        let name = "Watch iOS Mermaid validation"
        let payload = #"{"conclusion":"","jobs":[{"name":"SwiftLint","conclusion":"failure","status":"completed","steps":[{"name":"Lint sources","conclusion":"failure"}]},"#
            + #"{"name":"iOS Build","conclusion":"","status":"in_progress"},{"name":"Unit tests","conclusion":"success","status":"completed"}]}"#
        var row = message(id: "demo-design-watcher", role: "user", blocks: [
            DemoFixtures.textBlock(
                "[Background hook \"\(name)\"] iOS Mermaid validation: @context[github|123|Build report] \(payload)\n\n[This hook has retired.]"
            )
        ])
        row["metadata"] = [
            "type": "hook_wake", "hookName": name, "hookId": "demo-watcher",
            "reason": "dispatched", "hookStillActive": false
        ]
        return row
    }

    static func message(id: String, role: String, blocks: [[String: Any]]) -> [String: Any] {
        ["id": id, "role": role, "timestamp": timestamp, "contentBlocks": blocks]
    }

    private static var toolBlocks: [[String: Any]] {
        [
            DemoFixtures.toolUseBlock(id: "demo-design-read", name: "view", input: [
                "path": "design-system.astro", "view_range": [880, 900],
                "_acpTitle": "Read design-system.astro lines 880-900"
            ]),
            DemoFixtures.toolResultBlock(toolUseId: "demo-design-read", output: """
            880 | <section aria-label="Status icons">
            881 |   <h2>Attention</h2>
            882 |   <Icon name="attention-circle" />
            883 |   <p>Use an outline for the error state.</p>
            884 | </section>
            """),
            DemoFixtures.toolUseBlock(id: "demo-design-verify", name: "think", input: [
                "_acpTitle": "Verifying scaffold", "thought": "Checking the existing icon mapping before editing."
            ]),
            DemoFixtures.toolResultBlock(toolUseId: "demo-design-verify", output: "The scaffold uses the filled icon for errors."),
            DemoFixtures.toolUseBlock(id: "demo-design-edit", name: "str-replace-editor", input: [
                "path": "design-system.astro", "old_str_1": "attention-circle-fill", "new_str_1": "attention-circle",
                "_acpTitle": "Edit design-system.astro"
            ]),
            DemoFixtures.toolResultBlock(toolUseId: "demo-design-edit", output: assistantText)
        ]
    }

    private var questionBlocks: [[String: Any]] {
        var payloads = [
            """
            {"attachmentId":"tar-design-access","header":"Question One","question":"Can I access the repository?",
             "options":[{"label":"Yes, confirmed","description":"Repository access, billing/budget and capacity for one job are confirmed"},
                        {"label":"Not checked yet","description":"Keep the benchmark paused while I confirm with the organization admin."}]}
            """
        ]
        if scenario == .questionFlow {
            payloads.append("""
            {"attachmentId":"tar-design-checks","header":"Question Two","question":"Which checks should I run?","multiSelect":true,
             "options":[{"label":"Local tests","description":"Run the focused local gate."},
                        {"label":"Hosted benchmark","description":"Run the one authorized hosted job."}]}
            """)
        }
        if scenario == .questionCards {
            payloads = Self.questionCardPayloads
        }
        return payloads.enumerated().map { index, payload in
            [
                "id": "demo-design-question-\(index)", "type": "resource", "resource": [
                    "uri": "intent-question://design-\(index)", "mimeType": Question.resourceMimeType, "text": payload
                ]
            ]
        }
    }

    private static let questionCardPayloads = [
        """
        {"attachmentId":"tar-design-mixed","header":"Publish verified changes","question":"What should happen next?",
         "options":[{"label":"Push to the draft PR","description":"Publish the three verified commits and check CI. Keep the PR draft; do not merge, dispatch live workflows, or activate anything."},
                    {"label":"Keep working locally","description":"Do not publish yet."},
                    {"label":"Review the changes"}, {"label":"Wait for approval"}]}
        """,
        """
        {"attachmentId":"tar-design-short","header":"Short answers","question":"Which checks should I keep?","multiSelect":true,
         "options":[{"label":"Local tests"}, {"label":"Build"}, {"label":"Lint"},
                    {"label":"Review"}, {"label":"Screenshots"}, {"label":"Documentation"}]}
        """,
        """
        {"attachmentId":"tar-design-overflow","header":"Detailed answers","question":"Which details should I keep?",
         "options":[{"label":"Summary"}, {"label":"Checklist"}, {"label":"Notes"},
                    {"label":"Full review","description":"Review the changes, check local tests, inspect screenshots, and confirm accessibility. Keep live workflows disabled until the owner has approved the final result."}]}
        """
    ]
    // swiftlint:enable no_magic_numbers
}
#endif
