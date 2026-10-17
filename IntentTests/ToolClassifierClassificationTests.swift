@testable import Intent
import Testing

struct ToolClassifierClassificationTests {
    @Test func claudeToolSearchSelectorUsesReadableLoadingTitle() {
        let display = ToolClassifier.classify(name: "ToolSearch", input: [
            "_acpTitle": AnyCodable("ToolSearch"),
            "query": AnyCodable("select:mcp__workspace-mcp__workspace_api"),
            "max_results": AnyCodable(1)
        ])

        #expect(display.icon == .search)
        #expect(display.verb == "Loading tools")
        #expect(display.subject == nil)
        #expect(display.path == nil)
    }

    @Test func deferredToolLoadingMatchesDesktopTitleAndQueryForms() {
        let selector = "select:mcp__workspace-mcp__workspace_api"
        let fixtures: [(name: String, input: [String: AnyCodable])] = [
            ("ToolSearch", [:]),
            ("ToolSearch", ["query": AnyCodable("workspace tools")]),
            ("Search tools", ["query": AnyCodable(selector)]),
            ("Search tools", ["query": AnyCodable("select:mcp.workspace-mcp.workspace_api")]),
            ("Search tools", ["query": AnyCodable("select:mcp__workspace_api,mcp__workspace-mcp__workspace_api")]),
            ("Search \(selector)", [:]),
            ("ToolSearchTool", ["_acpTitle": AnyCodable("Search \(selector)")])
        ]

        for fixture in fixtures {
            let display = ToolClassifier.classify(name: fixture.name, input: fixture.input)
            #expect(display.icon == .search)
            #expect(display.verb == "Loading tools")
            #expect(display.subject == nil)
            #expect(display.path == nil)
        }
    }

    @Test func genuineSearchQueriesRemainVisible() {
        for query in ["how to use TypeScript generics", "select:focus css", "docs for select:mcp__server__tool"] {
            let display = ToolClassifier.classify(name: "web-search", input: [
                "query": AnyCodable(query)
            ])
            #expect(display.icon == .web)
            #expect(display.verb == "Search web")
            #expect(display.subject == query)
        }
    }

    private struct TitleFixture {
        let title: String
        let verb: String
        let subject: String
    }

    @Test func terminalTitleVerbsPreserveTheirDisplaySemantics() {
        let fixtures = [
            TitleFixture(title: "Run `swift test`", verb: "Run", subject: "swift test"),
            TitleFixture(title: "Launch `pnpm dev`", verb: "Launch", subject: "pnpm dev"),
            TitleFixture(title: "Read terminal 5", verb: "Read", subject: "terminal 5"),
            TitleFixture(title: "List processes", verb: "List", subject: "processes"),
            TitleFixture(title: "Kill terminal 5", verb: "Kill", subject: "terminal 5"),
            TitleFixture(title: "Write terminal 5", verb: "Write to", subject: "terminal 5")
        ]

        for fixture in fixtures {
            let display = ToolClassifier.classify(name: "launch-process", input: [
                "_acpTitle": AnyCodable(fixture.title)
            ])
            #expect(display.icon == .terminal)
            #expect(display.verb == fixture.verb)
            #expect(display.subject == fixture.subject)
        }
    }

    @Test func explicitCommandTakesPrecedenceOverTitleFallback() {
        let display = ToolClassifier.classify(name: "launch-process", input: [
            "command": AnyCodable("swift test\nignored second line"),
            "_acpTitle": AnyCodable("Kill terminal 5")
        ])

        #expect(display.icon == .terminal)
        #expect(display.verb == "Run")
        #expect(display.subject == "swift test")
    }

    @Test func terminalOperationNameTakesPrecedenceOverCommandAndTitle() {
        let display = ToolClassifier.classify(name: "read-process", input: [
            "command": AnyCodable("swift test"),
            "_acpTitle": AnyCodable("Kill terminal 5")
        ])

        #expect(display.icon == .terminal)
        #expect(display.verb == "Read")
        #expect(display.subject == "terminal")
    }

    @Test func commandInputPreservesTerminalPrecedenceForOtherwiseUnknownTool() {
        let display = ToolClassifier.classify(name: "unrecognized-tool", input: [
            "command": AnyCodable("echo hello"),
            "_acpTitle": AnyCodable("Summarize recent activity for the user")
        ])

        #expect(display.icon == .terminal)
        #expect(display.verb == "Run")
        #expect(display.subject == "echo hello")
    }

    @Test func malformedTerminalTitleFallsBackToGenericRunDisplay() {
        let display = ToolClassifier.classify(name: "launch-process", input: [
            "_acpTitle": AnyCodable("Inspect repository")
        ])

        #expect(display.icon == .terminal)
        #expect(display.verb == "Run")
        #expect(display.subject == nil)
    }

    @Test func workspaceApiRawNameFormsUseSummary() {
        let names = [
            "workspace_api",
            "mcp__workspace-mcp__workspace_api",
            "workspace_api_workspace-mcp",
            "workspace_api-workspace-mcp",
            "mcp.workspace-mcp.workspace_api"
        ]
        let summary = "Inspect the coordinates of the swipes recorded by hosted UI tests"

        for name in names {
            let display = ToolClassifier.classify(name: name, input: [
                "_acpTitle": AnyCodable(name),
                "summary": AnyCodable(summary)
            ])
            #expect(display.icon == .workspace)
            #expect(display.verb == summary)
            #expect(display.subject == nil)
            #expect(display.path == nil)
        }
    }

    @Test func codexWorkspaceApiInputShapeUsesSummary() {
        let summary = "Inspect the coordinates of the swipes recorded by hosted UI tests"
        let display = ToolClassifier.classify(name: "tool", input: [
            "_acpTitle": AnyCodable(" \nmcp.workspace-mcp.workspace_api\t "),
            "code": AnyCodable("return await ws.workspace.details()"),
            "summary": AnyCodable(" \n\(summary)\t ")
        ])

        #expect(display.icon == .workspace)
        #expect(display.verb == summary)
        #expect(display.subject == nil)
    }

    @Test func workspaceApiReadableTitlesKeepPrecedenceOverSummary() {
        let titles = [
            "Read spec and task note",
            "Inspect swipes",
            "mcp.workspace-mcp.workspace_api status"
        ]

        for title in titles {
            let display = ToolClassifier.classify(name: "workspace_api", input: [
                "_acpTitle": AnyCodable(" \n\(title)\t "),
                "summary": AnyCodable("Inspect the coordinates of the recorded swipes")
            ])
            #expect(display.verb == title)
        }
    }

    @Test func workspaceApiMissingOrBlankTitleUsesSummary() {
        let titles: [String?] = [nil, "", " \t\n "]
        for title in titles {
            var input = ["summary": AnyCodable(" \nInspect recorded swipes\t ")]
            if let title { input["_acpTitle"] = AnyCodable(title) }

            let display = ToolClassifier.classify(name: "mcp.workspace-mcp.workspace_api", input: input)
            #expect(display.verb == "Inspect recorded swipes")
        }
    }

    @Test func workspaceApiUnusableSummaryKeepsRawTitle() {
        let summaries: [AnyCodable?] = [nil, AnyCodable(""), AnyCodable(" \t\n "), AnyCodable(false)]
        let title = "mcp.workspace-mcp.workspace_api"
        for summary in summaries {
            var input = ["_acpTitle": AnyCodable(title)]
            if let summary { input["summary"] = summary }

            let display = ToolClassifier.classify(name: "workspace_api", input: input)
            #expect(display.verb == title)
            #expect(display.subject == nil)
        }
    }

    @Test func workspaceApiWithoutLabelsKeepsWorkspaceFallback() {
        for name in ["workspace_api", "mcp.workspace-mcp.workspace_api"] {
            let display = ToolClassifier.classify(name: name, input: [:])
            #expect(display.icon == .workspace)
            #expect(display.verb == "Workspace")
            #expect(display.subject == nil)
        }
    }

    @Test func unrelatedDottedToolKeepsExistingClassification() {
        let display = ToolClassifier.classify(name: "mcp.browser.inspect", input: [
            "_acpTitle": AnyCodable("mcp.browser.inspect"),
            "summary": AnyCodable("Inspect the page")
        ])
        #expect(display.icon == .browser)
        #expect(display.verb == "Browser")
        #expect(display.subject == nil)
    }
}

extension ConversationStoreLiveStateTests {
    @Test func claudeToolSearchLiveAndReloadedRowsKeepDetailsWithReadableTitle() async throws {
        let (liveStore, _) = makeStore()
        let (reloadedStore, _) = makeStore()
        let selector = "select:mcp__workspace-mcp__workspace_api"
        let input: [String: Any] = ["_acpTitle": "ToolSearch", "query": selector, "max_results": 1]
        let started: [String: Any] = [
            "type": "tool_use", "id": "msg-1:0", "name": "ToolSearch",
            "input": input, "toolCallId": "call-1",
            "metadata": ["toolKind": "search", "status": "started"]
        ]
        var completed = started
        completed["metadata"] = ["toolKind": "search", "status": "completed"]
        let result: [String: Any] = [
            "type": "tool_result", "id": "msg-1:1", "toolUseId": "call-1",
            "output": "Loaded workspace_api"
        ]

        liveStore.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        liveStore.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: "msg-1", block: started)
        ]))
        let initial = try #require(liveStore.messages.first?.contentBlocks.first)
        #expect(initial.metadata["status"]?.value as? String == "started")
        let initialDisplay = ToolClassifier.classify(name: initial.resolvedName ?? "tool", input: initial.input)
        #expect(initialDisplay.verb == "Loading tools")
        #expect(initialDisplay.subject == nil)

        let completedDelta = deltaParams(
            seq: 2,
            added: [blockEntity(messageId: "msg-1", block: result)],
            updated: [blockEntity(messageId: "msg-1", block: completed)]
        )
        liveStore.handleStreamEvent("subscription.push", params: completedDelta)
        reloadedStore.handleStreamEvent("subscription.push", params: snapshotParams(messages: [
            [
                "id": "msg-1", "role": "assistant", "contentBlocks": [completed, result],
                "timestamp": "2026-10-17T00:00:00.000Z"
            ]
        ]))

        for store in [liveStore, reloadedStore] {
            try expectReadableToolSearchDetails(store)
        }
    }

    private func expectReadableToolSearchDetails(_ store: ConversationStore) throws {
        #expect(store.messages.count == 1)
        let blocks = try #require(store.messages.first?.contentBlocks)
        #expect(blocks.count == 2)
        let tool = try #require(blocks.first { $0.type == .toolUse })
        let output = try #require(blocks.first { $0.type == .toolResult })
        #expect(tool.id == "msg-1:0")
        #expect(tool.resolvedName == "ToolSearch")
        #expect(tool.toolCallId == "call-1")
        #expect(tool.input["_acpTitle"]?.value as? String == "ToolSearch")
        #expect(tool.input["query"]?.value as? String == "select:mcp__workspace-mcp__workspace_api")
        #expect(tool.input["max_results"]?.value as? Int == 1)
        #expect(tool.metadata["status"]?.value as? String == "completed")
        #expect(output.toolUseId == "call-1")
        #expect(output.output?.value as? String == "Loaded workspace_api")
        let display = ToolClassifier.classify(name: tool.resolvedName ?? "tool", input: tool.input)
        #expect(display.icon == .search)
        #expect(display.verb == "Loading tools")
        #expect(display.subject == nil)
        #expect(display.path == nil)
    }
}
