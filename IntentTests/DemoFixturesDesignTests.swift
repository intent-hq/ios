#if DEBUG
import Foundation
@testable import Intent
import Testing

extension DemoFixturesTests {
    @Test func designScenariosRequireExplicitDemoOptIn() {
        for scenario in DemoDesignScenario.allCases {
            let argument = "--demo-design-scenario=\(scenario.rawValue)"
            #expect(DemoDesignScenario.requested(by: [argument]) == nil)
            #expect(DemoDesignScenario.requested(by: ["--pretend-paired", argument]) == nil)
            #expect(DemoDesignScenario.requested(by: ["--demo-data", argument]) == scenario)
        }
        #expect(DemoDesignScenario.requested(by: ["--demo-data"]) == nil)
        #expect(DemoDesignScenario.requested(by: ["--demo-data", "--demo-design-scenario=unknown"]) == nil)
        #expect(DemoDesignScenario.requested(by: ["--demo-data", "--demo-design-scenario=questions-extra"]) == nil)
    }

    /// Guards compatibility with actual load/parsing, not just dictionaries:
    /// broken wire keys must fail before screenshots.
    @Test(arguments: DemoDesignScenario.allCases)
    func designScenarioLoadsThroughConversationStores(_ scenario: DemoDesignScenario) async throws {
        let connection = DesignFixtureConnection(scenario: scenario)
        let viewModel = designViewModel(connection)
        defer { viewModel.teardownLiveStores() }
        await viewModel.load()

        #expect(!viewModel.isLoading)
        if scenario == .empty {
            #expect(viewModel.messages.isEmpty)
            return
        }
        #expect(viewModel.totalMessageCount == viewModel.messages.count + (scenario == .history ? 100 : 0))
        if scenario == .mermaidHistory {
            assertDiagramHistory(viewModel)
        } else if scenario == .claudeTools {
            try assertClaudeToolDetails(viewModel)
        } else {
            #expect(viewModel.messages.first?.joinedTextContent.hasPrefix("Worth adding tests?") == true)
            #expect(viewModel.messages.contains { $0.role == .user && $0.joinedTextContent.contains("attention circle not fill") })
            let tools = try #require(viewModel.messages.first { $0.id == "demo-design-tools" })
            #expect(tools.contentBlocks.filter { $0.type == .toolUse }.count == 3)
            #expect(tools.contentBlocks.filter { $0.type == .toolResult }.count == 3)
        }
        #expect(viewModel.isStreaming == (scenario == .streaming || scenario == .queue))
        if scenario == .automatedMessages {
            let agent = try #require(viewModel.messages.first { $0.id == "demo-design-agent-message" })
            #expect(agent.agentMessageAttribution?.rawName == "Coordinator")
            let script = try #require(viewModel.messages.first { $0.id == "demo-design-script-wake" })
            #expect(script.scriptMonitorWakeAttribution?.reason == .finished)
        }
        if scenario == .blocker {
            let notice = try #require(viewModel.messages.last?.attentionNotice)
            #expect(notice.kind == .blockerReport)
            #expect(notice.reason.contains("runner inventory returns 403"))
        }
        if scenario == .turnFailure {
            let summary = try #require(viewModel.messages.last?.attentionNotice?.turnFailureSummary)
            #expect(summary.category == .usageLimit)
            #expect(summary.rawDetails == DemoDesignFixtures.turnFailureText)
        }
        if scenario == .questions || scenario == .questionFlow || scenario == .questionCards {
            let questions = try #require(viewModel.pendingQuestions)
            let expectedQuestion = scenario == .questionCards ? "What should happen next?" : "Can I access the repository?"
            let expectedCount = scenario == .questionCards ? 3 : (scenario == .questionFlow ? 2 : 1)
            #expect(questions.questions.first?.question == expectedQuestion)
            #expect(questions.questions.count == expectedCount)
            #expect(viewModel.store.pendingQuestionsMessageId == questions.messageId)
            #expect(!viewModel.isPendingQuestionRecoveryLoading)
        } else {
            #expect(viewModel.pendingQuestions == nil)
        }
        #expect(viewModel.monitoredPrStore.activeMonitors.count == (scenario == .conversation ? 1 : 0))
    }

    private func assertClaudeToolDetails(_ viewModel: ConversationViewModel) throws {
        let message = try #require(viewModel.messages.first)
        #expect(viewModel.messages.count == 1)
        let tools = message.contentBlocks.filter { $0.type == .toolUse }
        #expect(tools.map(\.resolvedName) == ["ToolSearch", "Glob"])
        #expect(tools.first?.input["query"]?.value as? String == "select:mcp__workspace-mcp__workspace_api")
        #expect(message.contentBlocks.filter { $0.type == .toolResult }.count == tools.count)
    }

    private func assertDiagramHistory(_ viewModel: ConversationViewModel) {
        let firstAnswerDiagramCount = 3
        let laterAnswerDiagramCount = 2
        let expectedDiagramCounts = [firstAnswerDiagramCount, laterAnswerDiagramCount, laterAnswerDiagramCount, laterAnswerDiagramCount]
        let turns = expectedDiagramCounts.indices
        #expect(viewModel.messages.count == turns.count * 2)
        #expect(viewModel.messages.map(\.id) == turns.flatMap { ["diagram-question-\($0)", "diagram-answer-\($0)"] })
        let questions = viewModel.messages.filter { $0.role == .user }
        #expect(questions.map(\.joinedTextContent) == turns.map { "Explain architecture section \($0 + 1)." })
        let answers = viewModel.messages.filter { $0.role == .assistant }
        let diagrams = answers.map { Array(MarkdownContentCache.shared.preparedContent(for: $0.joinedTextContent).mermaidSources.values) }
        #expect(diagrams.map(\.count) == expectedDiagramCounts)
        #expect(Set(diagrams.flatMap { $0 }).count == expectedDiagramCounts.reduce(0, +))
        #expect(answers.last?.joinedTextContent.hasSuffix("Architecture answer 4 is complete.") == true)
    }

    @Test func designDemoSendStopAndReloadKeepTheActualSentMessage() async throws {
        let connection = DesignFixtureConnection(scenario: .composer)
        let viewModel = designViewModel(connection)
        defer { viewModel.teardownLiveStores() }
        await viewModel.load()
        await viewModel.sendMessage("Make the logo bigger")

        let sent = try #require(viewModel.messages.last)
        #expect(sent.role == .user)
        #expect(sent.joinedTextContent == "Make the logo bigger")
        #expect(viewModel.messages.filter { $0.id == sent.id }.count == 1)
        #expect(viewModel.store.sendAttempts.last?.status == .accepted)
        #expect(viewModel.isStreaming)
        await viewModel.stopStreaming()
        try await waitUntil("design demo stopped") { !viewModel.isStreaming }

        // Re-enter via the ordinary subscribe path, not a directly seeded store.
        viewModel.teardownLiveStores()
        await viewModel.load()
        #expect(!viewModel.isStreaming)
        #expect(viewModel.messages.last?.id == sent.id)
        #expect(viewModel.messages.last?.joinedTextContent == "Make the logo bigger")
    }

    @Test func designDemoQuestionAnswerClearsTheHoldAcrossReload() async throws {
        let connection = DesignFixtureConnection(scenario: .questionFlow)
        let viewModel = designViewModel(connection)
        defer { viewModel.teardownLiveStores() }
        await viewModel.load()
        let set = try #require(viewModel.pendingQuestions)
        let first = try #require(set.questions.first)
        let last = try #require(set.questions.last)
        #expect(last.multiSelect)
        let answers = [
            QuestionAnswer(question: first, selectedLabels: [], freeText: "The admin confirmed access.", skipped: false),
            QuestionAnswer(question: last, selectedLabels: ["Local tests", "Hosted benchmark"], freeText: "", skipped: false)
        ]
        await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: set.messageId)
        #expect(viewModel.pendingQuestions == nil)
        let sent = try #require(viewModel.messages.last)
        #expect(sent.role == .user)
        #expect(sent.joinedTextContent.contains("The admin confirmed access."))
        #expect(sent.joinedTextContent.contains("Local tests"))
        #expect(sent.joinedTextContent.contains("Hosted benchmark"))
        await viewModel.stopStreaming()
        try await waitUntil("answered design demo stopped") { !viewModel.isStreaming }
        viewModel.teardownLiveStores()
        await viewModel.load()
        #expect(viewModel.pendingQuestions == nil)
        #expect(viewModel.store.pendingQuestionsMessageId?.isEmpty == true)
        #expect(viewModel.messages.last?.id == sent.id)
    }

    @Test func designDemoDismissalPersistsWithoutSendingAnAnswer() async throws {
        let connection = DesignFixtureConnection(scenario: .questions)
        let viewModel = designViewModel(connection)
        defer { viewModel.teardownLiveStores() }
        await viewModel.load()
        let set = try #require(viewModel.pendingQuestions)
        let originalIds = viewModel.messages.map(\.id)
        await viewModel.dismissQuestions(messageId: set.messageId)
        #expect(viewModel.dismissQuestionsError == nil)
        #expect(viewModel.pendingQuestions == nil)
        viewModel.teardownLiveStores()
        await viewModel.load()
        #expect(viewModel.pendingQuestions == nil)
        #expect(viewModel.store.dismissedQuestionsMessageId == set.messageId)
        #expect(viewModel.messages.map(\.id) == originalIds)
    }

    @Test func designDemoMonitorCancellationReachesTheStoreAndStaysCancelled() async throws {
        let connection = DesignFixtureConnection(scenario: .conversation)
        let viewModel = designViewModel(connection)
        defer { viewModel.teardownLiveStores() }
        await viewModel.load()
        let monitor = try #require(viewModel.monitoredPrStore.activeMonitors.first)
        #expect(monitor.prNumber == 56)
        await viewModel.monitoredPrStore.cancel(monitorId: monitor.id)
        try await waitUntil("demo monitor cancellation") { viewModel.monitoredPrStore.activeMonitors.isEmpty }
        viewModel.teardownLiveStores()
        await viewModel.load()
        #expect(viewModel.monitoredPrStore.activeMonitors.isEmpty)
    }

    private func designViewModel(_ connection: DesignFixtureConnection) -> ConversationViewModel {
        ConversationViewModel(
            agentId: DemoDesignFixtures.agentId,
            workspaceId: DemoDesignFixtures.workspaceId,
            agentName: DemoDesignFixtures.agentName,
            connection: connection,
            uploadService: AttachmentUploadService(connection: connection),
            optionsStore: CreationOptionsStore(connectionManager: connection)
        )
    }
}

/// Transport-only adapter. All scenario data and command effects come from
/// the same fixture used by the app; the real router/store apply the pushes.
/// This adapter does not implement send, stop, question or monitor behavior.
@MainActor
private final class DesignFixtureConnection: FakeConnectionManager {
    private let fixture: DemoDesignFixtures
    private let router = ConnectionSubscriptionRouter()

    init(scenario: DemoDesignScenario) {
        fixture = DemoDesignFixtures(scenario: scenario)
        super.init()
    }

    override func request(
        _ method: String,
        params: [String: Any] = [:],
        timeout _: TimeInterval = ConnectionManager.defaultRequestTimeout
    ) async -> Any {
        let response = fixture.response(for: method, params: params) ?? DemoFixtures.response(for: method, params: params)
        if let push = fixture.subscriptionPush(for: method, params: params) { router.route(push) }
        if let event = fixture.event(for: method, params: params) { deliverEvent(method: "event", params: event) }
        return response
    }

    override func registerSubscriptionHandler(id: String, handler: @escaping @MainActor (SubscriptionPush) -> Void) {
        router.register(id: id, handler: handler)
    }

    override func unregisterSubscriptionHandler(id: String) {
        router.unregister(id: id)
    }
}
#endif
