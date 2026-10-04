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
    static let blockerText = """
    The sub-15-minute hosted CI measurement is held because current GitHub permissions cannot verify \
    macos-15-xlarge access (runner inventory returns 403). The user is checking with an organization admin. \
    Need confirmation that intent-ha/ios has runner access, paid usage and capacity before publication and the \
    one authorized hosted run. Local review and the single local gate are finished; no extra runs or settings \
    changes will be attempted.
    """

    var workspace: [String: Any] {
        [
            "id": Self.workspaceId, "title": "Workspace agent design", "branch": "design/agent-conversation",
            "baseRef": "main", "status": "active", "activity": isStreaming ? "agent_running" : "idle",
            "displayStatus": hasQuestions || scenario == .blocker ? "needs_attention" : "in_progress",
            "attention": hasQuestions || scenario == .blocker ? "unread" : "none",
            "lastActivity": Self.timestamp, "updatedAt": Self.timestamp,
            "repositoryOwner": "intent-ha", "repositoryName": "ios",
            "agentSummary": ["count": 1, "agents": [agent]]
        ]
    }

    var agent: [String: Any] {
        [
            "id": Self.agentId, "workspaceId": Self.workspaceId, "name": Self.agentName,
            "status": isStreaming ? "running" : "idle", "isResponding": isStreaming,
            "createdAt": Self.timestamp, "updatedAt": Self.timestamp, "lastActivity": Self.timestamp,
            "lastMessageRole": "assistant",
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
            "id": "spec", "title": "Spec", "isDefault": true, "content": "# Goal",
            "createdAt": Self.timestamp, "updatedAt": Self.timestamp
        ]
        return [spec] + titles.enumerated().map { index, title in
            [
                "id": "context-task-\(index)", "title": title, "parentId": "spec",
                "content": "Task details for \(title).", "metadata": ["task": ["status": "complete"]],
                "createdAt": "2026-09-26T09:42:0\(index)Z", "updatedAt": Self.timestamp
            ]
        }
    }

    var monitor: [String: Any] {
        [
            "monitorId": Self.monitorId, "workspaceId": Self.workspaceId, "agentId": Self.agentId,
            "repo": "intent-ha/ios", "prNumber": 56, "state": monitorCancelled ? "cancelled" : "active",
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
        var rows = [
            Self.message(id: "demo-design-assistant", role: "assistant", blocks: [DemoFixtures.textBlock(Self.assistantText)]),
            Self.message(id: "demo-design-user", role: "user", blocks: [DemoFixtures.textBlock(Self.userText)]),
            Self.message(id: "demo-design-tools", role: "assistant", blocks: Self.toolBlocks)
        ]
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
        var row = message(id: "demo-design-watcher", role: "user", blocks: [DemoFixtures.textBlock(
            "[Background hook \"\(name)\"] iOS Mermaid validation: \(payload)\n\n[This hook has retired.]"
        )])
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
