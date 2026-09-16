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
        #expect(long.items.count >= 150)
        #expect(long.total == long.items.count)

        let messages = long.items.compactMap { ConversationMessage.parseMessage($0) }
        #expect(messages.count == long.items.count)
        #expect(messages.allSatisfy { $0.role == .user || $0.role == .assistant })
        #expect(messages.first?.role == .user)
        #expect(messages.last?.role == .assistant)
        #expect(Set(long.items.compactMap { $0["id"] as? String }).count == long.items.count)
        // Timestamps descend from the first message to the last.
        let timestamps = long.items.compactMap { $0["timestamp"] as? String }
        #expect(timestamps.count == long.items.count)
        #expect(timestamps == timestamps.sorted())

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
        // The anchors the transcript UI tests match on stay unique.
        #expect(long.items.filter { text(of: $0).contains(DemoFixtures.longConversationFirstSentence) }.count == 1)
        #expect(long.items.filter { text(of: $0).contains(DemoFixtures.longConversationLastSentence) }.count == 1)
    }

    /// The long transcript is coordinator-shaped (intent-hq/ios#304, #305):
    /// paired tool calls, agent-to-agent report rows attributed to the
    /// delegates the coordinator waits on, thinking blocks, and markdown
    /// with fenced code — so rows vary widely in height.
    @Test func longConversationMixesToolCallsAgentMessagesAndMarkdown() throws {
        let long = try conversationMessages(agentId: DemoFixtures.longConversationAgentId)
        let messages = long.items.compactMap { ConversationMessage.parseMessage($0) }
        let blocks = messages.flatMap { $0.contentBlocks ?? [] }

        let toolUses = blocks.filter { $0.type == .toolUse }
        let toolResults = blocks.filter { $0.type == .toolResult }
        #expect(toolUses.count >= 30)
        #expect(toolUses.allSatisfy { $0.resolvedName?.isEmpty == false })
        let resultIds = Set(toolResults.compactMap(\.resolvedToolUseId))
        #expect(toolUses.allSatisfy { resultIds.contains($0.id) })
        #expect(Set(toolUses.map(\.id)).count == toolUses.count)
        #expect(blocks.contains { $0.type == .thinking })

        let agentRows = messages.filter { $0.agentMessageAttribution != nil }
        #expect(agentRows.count >= 40)
        #expect(agentRows.allSatisfy { $0.role == .user })
        let senders = Set(agentRows.compactMap { $0.agentMessageAttribution?.fromAgentId })
        #expect(senders == Set(DemoFixtures.longConversationDelegateIds))
        #expect(agentRows.allSatisfy { row in
            let attribution = row.agentMessageAttribution
            return DemoFixtures.longConversationDelegateNames.contains(attribution?.rawName ?? "")
        })

        let texts = blocks.filter { $0.type == .text }.compactMap(\.resolvedText)
        #expect(texts.filter { $0.contains("```") }.count >= 30)
        // Tool-call groups: the open tag and the close tag sit in different
        // text blocks around the tool_use/tool_result pairs.
        #expect(texts.contains { $0.contains("<group:") && !$0.contains("</group>") })
        #expect(texts.contains { $0.contains("</group>") && !$0.contains("<group:") })
        #expect(texts.contains { $0.contains("| Percentile | Duration |") })
        #expect(messages.contains { ($0.contentBlocks?.count ?? 0) >= 5 })
    }

    @Test func subscriptionsReportTheDelegationGroupForTheLongConversationAgent() throws {
        let result = DemoFixtures.response(
            for: "agent.getSubscriptions",
            params: ["agentId": DemoFixtures.longConversationAgentId, "workspaceId": DemoFixtures.longConversationWorkspaceId])
        let dict = try #require(result as? [String: Any])
        let groups = try #require(dict["delegationGroups"] as? [[String: Any]])
        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(group["expectedAgentIds"] as? [String] == DemoFixtures.longConversationDelegateIds)
        #expect((group["completedAgentIds"] as? [String])?.count == 1)
        let subscriptions = try #require(dict["subscriptions"] as? [[String: Any]])
        #expect(subscriptions.allSatisfy { ($0["actorIds"] as? [String]).map { !$0.isEmpty } == true })

        let other = DemoFixtures.response(
            for: "agent.getSubscriptions", params: ["agentId": "demo-agent-implementor"])
        let otherDict = try #require(other as? [String: Any])
        #expect(otherDict.isEmpty)
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
            == [DemoFixtures.longConversationAgentId] + DemoFixtures.longConversationDelegateIds)

        let result = DemoFixtures.response(
            for: "agent.get", params: ["agentId": DemoFixtures.longConversationAgentId])
        let dict = try #require(result as? [String: Any])
        let agentDict = try #require(dict["agent"] as? [String: Any])
        #expect(agentDict["id"] as? String == DemoFixtures.longConversationAgentId)
        #expect(agentDict["status"] as? String == "idle")
    }

    /// The delegates are background sub-agents of the coordinator, so the
    /// coordinator stays the workspace's only foreground agent (the
    /// workspace row still auto-opens into its transcript) while the
    /// "Waiting for all" footer has rows to show.
    @Test func longConversationDelegatesAreBackgroundSubAgentsOfTheCoordinator() throws {
        let result = DemoFixtures.response(
            for: "agent.list", params: ["workspaceId": DemoFixtures.longConversationWorkspaceId])
        let dict = try #require(result as? [String: Any])
        let items = try #require(dict["agents"] as? [[String: Any]])
        let agents = items.compactMap { AgentSession.parseAgent($0) }
        #expect(agents.count == items.count)

        let foreground = agents.filter { !$0.isBackground && $0.createdByAgentId == nil }
        #expect(foreground.map(\.id) == [DemoFixtures.longConversationAgentId])
        let delegates = agents.filter { DemoFixtures.longConversationDelegateIds.contains($0.id) }
        #expect(delegates.count == DemoFixtures.longConversationDelegateIds.count)
        #expect(delegates.allSatisfy { $0.isBackground && $0.createdByAgentId == DemoFixtures.longConversationAgentId })
        #expect(delegates.contains { $0.isActive })

        for delegateId in DemoFixtures.longConversationDelegateIds {
            let fetched = DemoFixtures.response(for: "agent.get", params: ["agentId": delegateId])
            let fetchedDict = try #require(fetched as? [String: Any])
            let agentDict = try #require(fetchedDict["agent"] as? [String: Any])
            #expect(agentDict["id"] as? String == delegateId)
        }
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

    @Test func onlyTheLongConversationHookListAndBlockHydrationAreGated() {
        let long = ["workspaceId": DemoFixtures.longConversationWorkspaceId]
        #expect(DemoFixtures.responseGate(for: "hook.list", params: long)
            == DemoFixtures.longConversationHookListGate)
        #expect(DemoFixtures.responseGate(for: "hook.list", params: [:]) == nil)
        #expect(DemoFixtures.responseGate(for: "hook.list", params: ["workspaceId": "demo-ws-dashboard"]) == nil)
        #expect(DemoFixtures.responseGate(for: "agent.getConversation", params: long) == nil)
        #expect(DemoFixtures.responseGate(
            for: "agent.getConversation", params: ["agentId": DemoFixtures.longConversationAgentId]) == nil)
        #expect(DemoFixtures.responseGate(for: "prMonitor.list", params: long) == nil)

        let hydration = ["agentId": DemoFixtures.longConversationAgentId, "messageId": "m", "blockId": "b"]
        #expect(DemoFixtures.responseGate(for: "agent.getMessageBlock", params: hydration)
            == DemoFixtures.longConversationBlockHydrationGate)
        #expect(DemoFixtures.responseGate(for: "agent.getMessageBlock", params: [:]) == nil)
        #expect(DemoFixtures.responseGate(
            for: "agent.getMessageBlock", params: ["agentId": "demo-agent-implementor"]) == nil)
    }

    // MARK: - Slim-truncated tool rows near the end of the long conversation

    @Test func blockHydrationGateComesFromTheLaunchArguments() {
        #expect(DemoFixtures.blockHydrationGate(from: ["--demo-data"])
            == .delay(DemoFixtures.defaultBlockHydrationDelay))
        #expect(DemoFixtures.blockHydrationGate(from: ["--demo-data", "--demo-block-hydration-delay-ms=9000"])
            == .delay(.milliseconds(9_000)))
        #expect(DemoFixtures.blockHydrationDelay(from: ["--demo-block-hydration-delay-ms=0"]) == .zero)
        #expect(DemoFixtures.blockHydrationDelay(from: ["--demo-block-hydration-delay-ms=abc"])
            == DemoFixtures.defaultBlockHydrationDelay)
        #expect(DemoFixtures.blockHydrationGate(from: ["--demo-block-hydration-trigger-file=/tmp/a.trigger"])
            == .triggerFile(URL(fileURLWithPath: "/tmp/a.trigger")))
        #expect(DemoFixtures.blockHydrationGate(from: [
            "--demo-block-hydration-delay-ms=9000",
            "--demo-block-hydration-trigger-file=/tmp/a.trigger",
            "--demo-block-hydration-trigger-file=",
        ]) == .triggerFile(URL(fileURLWithPath: "/tmp/a.trigger")))
        // The two gates read their own arguments only.
        #expect(DemoFixtures.blockHydrationGate(from: ["--demo-hook-list-trigger-file=/tmp/a.trigger"])
            == .delay(DemoFixtures.defaultBlockHydrationDelay))
        #expect(DemoFixtures.hookListGate(from: ["--demo-block-hydration-trigger-file=/tmp/a.trigger"])
            == .delay(DemoFixtures.defaultHookListDelay))
    }

    @Test func lastAssistantMessagesCarrySlimTruncatedToolRowsThatHydrateInFull() throws {
        let long = try conversationMessages(agentId: DemoFixtures.longConversationAgentId)
        let messages = long.items.compactMap { ConversationMessage.parseMessage($0) }
        let calls = DemoFixtures.longConversationTruncatedToolCalls
        #expect(calls.count == 2)

        // The message right before the last one carries the first call, the
        // one before the assistant text message of the exchange before it
        // the second; no other row is truncated.
        let truncatedIndices = messages.indices.filter { index in
            messages[index].contentBlocks?.contains { $0.isSlimTruncated } == true
        }
        #expect(truncatedIndices.count == calls.count)
        #expect(truncatedIndices.last == messages.count - 2)
        let last = try #require(messages.last)
        #expect(last.role == .assistant)
        #expect(last.contentBlocks?.allSatisfy { $0.type == .text } == true)

        for (call, index) in zip(calls, truncatedIndices.reversed()) {
            let message = messages[index]
            let blocks = try #require(message.contentBlocks)
            // A tool-only assistant message (no text, so no copy context-menu
            // overlay claims the row's taps) right before a text message.
            #expect(message.role == .assistant)
            #expect(blocks.allSatisfy { $0.type == .toolUse || $0.type == .toolResult })
            let following = messages[index + 1]
            #expect(following.role == .assistant)
            #expect(following.contentBlocks?.contains { $0.type == .text } == true)
            let toolUse = try #require(blocks.first { $0.id == call.id })
            #expect(toolUse.type == .toolUse)
            #expect(toolUse.inputTruncated != true)
            #expect(toolUse.input?["path"]?.value as? String == call.file)
            let slimResult = try #require(blocks.first { $0.resolvedToolUseId == call.id })
            #expect(slimResult.type == .toolResult)
            #expect(slimResult.outputTruncated == true)
            let preview = try #require(slimResult.output?.value as? String)
            #expect(preview.count == DemoFixtures.longConversationTruncatedOutputPreviewLength)

            let hydrated = DemoFixtures.response(for: "agent.getMessageBlock", params: [
                "agentId": DemoFixtures.longConversationAgentId,
                "messageId": message.id,
                "blockId": slimResult.id,
            ])
            let dict = try #require(hydrated as? [String: Any])
            let blockDict = try #require(dict["block"] as? [String: Any])
            let full = try #require(ContentBlock.decode(blockDict))
            #expect(full.id == slimResult.id)
            #expect(full.type == .toolResult)
            #expect(full.resolvedToolUseId == call.id)
            #expect(full.outputTruncated != true)
            let fullOutput = try #require(full.output?.value as? String)
            #expect(fullOutput.hasPrefix(preview))
            #expect(fullOutput.utf8.count == slimResult.outputBytes)
            #expect(fullOutput.split(separator: "\n").count >= 50)
            #expect(fullOutput.contains(call.symbol))
        }

        let unknown = DemoFixtures.response(
            for: "agent.getMessageBlock",
            params: ["agentId": DemoFixtures.longConversationAgentId, "blockId": "demo-long-tool-1-view-result"])
        #expect(try #require(unknown as? [String: Any]).isEmpty)
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
