import Foundation
import Testing
@testable import Intent

@MainActor
struct DemoFixturesTests {

    // MARK: - Launch-argument gating

    @Test func demoModeInactiveWithoutArguments() {
        #expect(!DemoMode.demoDataRequested(by: []))
        #expect(!DemoMode.demoDataRequested(by: ["/path/to/Intent"]))
        #expect(!DemoMode.pretendPairedRequested(by: ["/path/to/Intent"]))
    }

    @Test func demoModeIgnoresSimilarArguments() {
        #expect(!DemoMode.demoDataRequested(by: ["--demo-data-extra", "demo-data", "--demo"]))
        #expect(!DemoMode.pretendPairedRequested(by: ["pretend-paired", "--pretend"]))
    }

    @Test func demoDataArgumentEnablesDemoMode() {
        #expect(DemoMode.demoDataRequested(by: ["/path/to/Intent", "--demo-data"]))
    }

    @Test func demoDataImpliesPretendPaired() {
        #expect(DemoMode.pretendPairedRequested(by: ["--demo-data"]))
    }

    @Test func pretendPairedAloneDoesNotEnableFixtures() {
        #expect(DemoMode.pretendPairedRequested(by: ["--pretend-paired"]))
        #expect(!DemoMode.demoDataRequested(by: ["--pretend-paired"]))
    }

    @Test func normalLaunchLeavesDemoModeOff() {
        // The live values are computed from the real process arguments; the
        // test runner never passes the demo flags, so both must be false.
        #expect(!DemoMode.isEnabled)
        #expect(!DemoMode.pretendPaired)
    }

    // MARK: - Fixture shape: parses through the real store parsers

    @Test func workspaceListFixtureParses() {
        let result = DemoFixtures.response(for: "workspace.list", params: [:])
        let workspaces = WorkspaceStore.parseWorkspaces(from: result)
        #expect(workspaces.count == 4)
        #expect(workspaces.allSatisfy { !$0.title.isEmpty })
        // At least one workspace carries an agent summary for the detail screen
        #expect(workspaces.contains { ($0.agentSummaryAgents?.count ?? 0) > 0 })
    }

    @Test func noteListFixtureParses() throws {
        let result = DemoFixtures.response(for: "note.list", params: [:])
        let dict = try #require(result as? [String: Any])
        let items = try #require(dict["notes"] as? [[String: Any]])
        let notes = items.compactMap { Note.parseNote($0) }
        #expect(notes.count == items.count)
        #expect(notes.contains { $0.isDefault })
        // A task note with checkboxes is present for the note detail screenshot
        #expect(notes.contains { $0.taskStatus != nil && $0.content.contains("- [ ]") })
    }

    @Test func agentListFixtureParses() throws {
        let result = DemoFixtures.response(for: "agent.list", params: [:])
        let dict = try #require(result as? [String: Any])
        let items = try #require(dict["agents"] as? [[String: Any]])
        let agents = items.compactMap { AgentSession.parseAgent($0) }
        #expect(agents.count == items.count)
        #expect(agents.count >= 2)
    }

    @Test func conversationFixtureParses() throws {
        let result = DemoFixtures.response(for: "agent.getConversation", params: [:])
        let dict = try #require(result as? [String: Any])
        let items = try #require(dict["messages"] as? [[String: Any]])
        let messages = items.compactMap { ConversationMessage.parseMessage($0) }
        #expect(messages.count == items.count)
        #expect(messages.contains { $0.role == .user })
        #expect(messages.contains { $0.role == .assistant })
        // Every message renders at least one text block
        #expect(messages.allSatisfy { message in
            message.contentBlocks?.contains { $0.resolvedText?.isEmpty == false } == true
        })
    }

    // MARK: - Per-agent conversation routing

    private func conversationMessages(agentId: String?) throws -> (items: [[String: Any]], total: Int) {
        var params: [String: Any] = [:]
        if let agentId { params["agentId"] = agentId }
        let result = DemoFixtures.response(for: "agent.getConversation", params: params)
        let dict = try #require(result as? [String: Any])
        let items = try #require(dict["messages"] as? [[String: Any]])
        let total = try #require(dict["totalMessages"] as? Int)
        return (items, total)
    }

    private func text(of message: [String: Any]) -> String {
        let blocks = message["contentBlocks"] as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined()
    }

    @Test func conversationDefaultsToScreenshotTranscript() throws {
        let noAgent = try conversationMessages(agentId: nil)
        let implementor = try conversationMessages(agentId: "demo-agent-implementor")
        let reviewer = try conversationMessages(agentId: "demo-agent-reviewer")
        for conversation in [noAgent, implementor, reviewer] {
            #expect(conversation.items.count == 4)
            #expect(conversation.total == 4)
            #expect(conversation.items.contains { text(of: $0).contains("more than 90 days") })
        }
    }

    @Test func longConversationRoutesByAgentId() throws {
        let long = try conversationMessages(agentId: DemoFixtures.longConversationAgentId)
        #expect(long.items.count >= 30)
        #expect(long.total == long.items.count)

        let messages = long.items.compactMap { ConversationMessage.parseMessage($0) }
        #expect(messages.count == long.items.count)
        for (index, message) in messages.enumerated() {
            #expect(message.role == (index.isMultiple(of: 2) ? .user : .assistant))
        }
        #expect(Set(long.items.compactMap { $0["id"] as? String }).count == long.items.count)

        let first = try #require(long.items.first)
        let last = try #require(long.items.last)
        #expect(text(of: first).hasPrefix(DemoFixtures.longConversationFirstSentence))
        // The last message carries the suggested-prompts block after its
        // closing sentence; the rendered (stripped) text still ends there.
        let lastText = text(of: last)
        #expect(SuggestedPrompts.parse(lastText) == DemoFixtures.longConversationSuggestedPrompts)
        #expect(DemoFixtures.longConversationSuggestedPrompts.count == 3)
        #expect(SuggestedPrompts.stripBlocks(from: lastText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix(DemoFixtures.longConversationLastSentence))
        #expect(!long.items.contains { text(of: $0).contains("more than 90 days") })
    }

    @Test func agentListRoutesByWorkspaceId() throws {
        func agentIds(workspaceId: String?) throws -> [String] {
            var params: [String: Any] = [:]
            if let workspaceId { params["workspaceId"] = workspaceId }
            let result = DemoFixtures.response(for: "agent.list", params: params)
            let dict = try #require(result as? [String: Any])
            let items = try #require(dict["agents"] as? [[String: Any]])
            return items.compactMap { AgentSession.parseAgent($0)?.id }
        }
        #expect(try agentIds(workspaceId: nil).contains("demo-agent-implementor"))
        #expect(try agentIds(workspaceId: "demo-ws-dashboard").contains("demo-agent-implementor"))
        #expect(try agentIds(workspaceId: DemoFixtures.longConversationWorkspaceId)
            == [DemoFixtures.longConversationAgentId])

        let result = DemoFixtures.response(
            for: "agent.get", params: ["agentId": DemoFixtures.longConversationAgentId])
        let dict = try #require(result as? [String: Any])
        let agentDict = try #require(dict["agent"] as? [String: Any])
        #expect(agentDict["id"] as? String == DemoFixtures.longConversationAgentId)
        #expect(agentDict["status"] as? String == "idle")
    }

    // MARK: - Delayed hooks row for the long conversation

    private func hooks(workspaceId: String?) throws -> [BackgroundHook] {
        var params: [String: Any] = [:]
        if let workspaceId { params["workspaceId"] = workspaceId }
        let result = DemoFixtures.response(for: "hook.list", params: params)
        let dict = try #require(result as? [String: Any])
        let items = try #require(dict["hooks"] as? [[String: Any]])
        let hooks = items.compactMap { BackgroundHook.parseHook($0) }
        #expect(hooks.count == items.count)
        return hooks
    }

    @Test func hookListServesOneActiveHookForTheLongConversationAgent() throws {
        let hooks = try hooks(workspaceId: DemoFixtures.longConversationWorkspaceId)
        let hook = try #require(hooks.first)
        #expect(hooks.count == 1)
        #expect(hook.isActive)
        #expect(hook.agentId == DemoFixtures.longConversationAgentId)
        #expect(hook.workspaceId == DemoFixtures.longConversationWorkspaceId)
        #expect(hook.name == DemoFixtures.longConversationHookName)
        #expect(hook.nextRunAt != nil)
    }

    @Test func hookListIsEmptyForOtherWorkspaces() throws {
        #expect(try hooks(workspaceId: nil).isEmpty)
        #expect(try hooks(workspaceId: "demo-ws-dashboard").isEmpty)
    }

    @Test func hookListDelayComesFromTheLaunchArgumentWhenPresent() {
        #expect(DemoFixtures.hookListDelay(from: ["--demo-data"]) == DemoFixtures.defaultHookListDelay)
        #expect(DemoFixtures.hookListDelay(from: ["--demo-data", "--demo-hook-list-delay-ms=9000"])
            == .milliseconds(9_000))
        #expect(DemoFixtures.hookListDelay(from: ["--demo-hook-list-delay-ms=0"]) == .zero)
        #expect(DemoFixtures.hookListDelay(from: ["--demo-hook-list-delay-ms=abc"])
            == DemoFixtures.defaultHookListDelay)
        #expect(DemoFixtures.hookListDelay(from: ["--demo-hook-list-delay-ms=-5"])
            == DemoFixtures.defaultHookListDelay)
        #expect(DemoFixtures.hookListDelay(from: ["--demo-hook-list-delay-ms=100", "--demo-hook-list-delay-ms=250"])
            == .milliseconds(250))
    }

    @Test func hookListGateIsATriggerFileWhenTheLaunchArgumentNamesOne() {
        #expect(DemoFixtures.hookListGate(from: ["--demo-data"]) == .delay(DemoFixtures.defaultHookListDelay))
        #expect(DemoFixtures.hookListGate(from: ["--demo-data", "--demo-hook-list-delay-ms=9000"])
            == .delay(.milliseconds(9_000)))
        #expect(DemoFixtures.hookListGate(from: ["--demo-hook-list-trigger-file=/tmp/a.trigger"])
            == .triggerFile(URL(fileURLWithPath: "/tmp/a.trigger")))
        // The trigger file wins over a delay; the last non-empty path wins.
        #expect(DemoFixtures.hookListGate(from: [
            "--demo-hook-list-delay-ms=9000",
            "--demo-hook-list-trigger-file=/tmp/a.trigger",
            "--demo-hook-list-trigger-file=/tmp/b.trigger",
            "--demo-hook-list-trigger-file=",
        ]) == .triggerFile(URL(fileURLWithPath: "/tmp/b.trigger")))
        #expect(DemoFixtures.hookListGate(from: ["--demo-hook-list-trigger-file="])
            == .delay(DemoFixtures.defaultHookListDelay))
    }

    @Test func triggerFileGateOpensOnceTheFileExists() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-fixtures-\(UUID().uuidString).trigger")
        defer { try? FileManager.default.removeItem(at: url) }

        let opened = OpenedFlag()
        let gate = Task {
            try await DemoFixtures.wait(for: .triggerFile(url))
            await opened.set()
        }
        // Several poll intervals without the file: still closed.
        try await Task.sleep(for: .milliseconds(400))
        #expect(await opened.value == false)

        try Data().write(to: url)
        // Bounded: a gate that never opens must fail the test, not hang it.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(5))
            gate.cancel()
        }
        try await gate.value
        watchdog.cancel()
        #expect(await opened.value == true)
    }

    private actor OpenedFlag {
        private(set) var value = false
        func set() { value = true }
    }

    @Test func triggerFileGateWaitIsCancellable() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-fixtures-\(UUID().uuidString).never")
        let gate = Task { try await DemoFixtures.wait(for: .triggerFile(url)) }
        gate.cancel()
        await #expect(throws: CancellationError.self) { try await gate.value }
    }

    @Test func onlyTheLongConversationHookListIsGated() {
        let long = ["workspaceId": DemoFixtures.longConversationWorkspaceId]
        #expect(DemoFixtures.responseGate(for: "hook.list", params: long)
            == DemoFixtures.longConversationHookListGate)
        #expect(DemoFixtures.responseGate(for: "hook.list", params: [:]) == nil)
        #expect(DemoFixtures.responseGate(for: "hook.list", params: ["workspaceId": "demo-ws-dashboard"]) == nil)
        #expect(DemoFixtures.responseGate(for: "agent.getConversation", params: long) == nil)
        #expect(DemoFixtures.responseGate(for: "prMonitor.list", params: long) == nil)
    }

    @Test func taskListFixtureParses() throws {
        let result = DemoFixtures.response(for: "task.list", params: [:])
        let dict = try #require(result as? [String: Any])
        let items = try #require(dict["tasks"] as? [[String: Any]])
        let tasks = items.compactMap { WorkspaceTask.parseTask($0) }
        #expect(tasks.count == items.count)
    }

    @Test func noteGetReturnsRequestedNote() throws {
        let result = DemoFixtures.response(
            for: "note.get", params: ["noteId": "demo-note-research"])
        let dict = try #require(result as? [String: Any])
        let noteDict = try #require(dict["note"] as? [String: Any])
        #expect(noteDict["id"] as? String == "demo-note-research")
    }

    @Test func unknownMethodReturnsEmptyDictionary() throws {
        let result = DemoFixtures.response(for: "note.subscribe", params: [:])
        let dict = try #require(result as? [String: Any])
        // No subscriptionId → stores fall back to their legacy fetch paths
        #expect(dict["subscriptionId"] == nil)
        #expect(dict.isEmpty)
    }

    @Test func fixturesContainNoPlaceholderOrSecretContent() throws {
        let payload: [Any] = [
            DemoFixtures.response(for: "workspace.list", params: [:]),
            DemoFixtures.response(for: "note.list", params: [:]),
            DemoFixtures.response(for: "agent.list", params: [:]),
            DemoFixtures.response(
                for: "agent.list", params: ["workspaceId": DemoFixtures.longConversationWorkspaceId]),
            DemoFixtures.response(for: "agent.getConversation", params: [:]),
            DemoFixtures.response(
                for: "agent.getConversation", params: ["agentId": DemoFixtures.longConversationAgentId]),
            DemoFixtures.response(
                for: "hook.list", params: ["workspaceId": DemoFixtures.longConversationWorkspaceId]),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = try #require(String(data: data, encoding: .utf8)).lowercased()
        #expect(!text.contains("lorem"))
        #expect(!text.contains("ipsum"))
        #expect(!text.contains("token"))
        #expect(!text.contains("bearer"))
    }
}
