import Observation
import SwiftUI
import Testing
import UIKit

@testable import Intent

@MainActor
@Suite(.serialized)
struct AssistantPromptRenderingTests {
    private static let greeting = "Hey bro — what’s on your mind?"
    private static let prompt = "Show me what needs my attention."
    private static let secondPrompt = "Help me start something new."
    private static let hostWidth: CGFloat = 390
    private static let hostHeight: CGFloat = 600
    private static let observationTimeout: TimeInterval = 3
    private static let observationInterval: Duration = .milliseconds(20)

    @Observable final class Model {
        var message: ConversationMessage

        init(message: ConversationMessage) {
            self.message = message
        }
    }

    private struct Transcript: View {
        let model: Model

        var body: some View {
            MessageView(message: model.message, workspaceId: Workspace.chiefWorkspaceId)
        }
    }

    @Test(arguments: [false, true])
    func closingStreamedPromptBlockRemovesItsRenderedText(splitAcrossBlocks: Bool) async throws {
        let prefix = Self.greeting + "\n\n<!-- suggested-prompts\n"
        let body = Self.prompt + "\n" + Self.secondPrompt
        let blocks = splitAcrossBlocks
            ? [
                ContentBlock(id: "text", type: .text, text: prefix),
                ContentBlock(id: "prompts", type: .text, text: body)
            ]
            : [ContentBlock(id: "text", type: .text, text: prefix + body)]
        let model = Model(message: ConversationMessage(
            id: "streaming-reply",
            role: .assistant,
            contentBlocks: blocks,
            timestamp: "2026-09-24T23:31:32Z",
            streamingState: .streaming
        ))
        let coordinator = try makeCoordinator()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: Transcript(model: model).environment(coordinator))
        window.frame = CGRect(x: 0, y: 0, width: Self.hostWidth, height: Self.hostHeight)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        try await observe(in: controller.view) { $0.contains(Self.greeting) && $0.contains(Self.prompt) }
        let lastIndex = model.message.contentBlocks.count - 1
        let previousText = try #require(model.message.contentBlocks[lastIndex].text)
        model.message.contentBlocks[lastIndex].text = previousText + "\n-->"
        model.message.streamingState = .complete
        #expect(SuggestedPrompts.parse(contentBlocks: model.message.contentBlocks).prompts == [
            Self.prompt, Self.secondPrompt
        ])
        try await observe(in: controller.view) { text in
            text.contains(Self.greeting) && !text.contains("suggested-prompts")
                && !text.contains(Self.prompt) && !text.contains(Self.secondPrompt)
        }
    }

    private func makeCoordinator() throws -> AppCoordinator {
        _ = TestKeychainStorage.installed
        let suite = "AssistantPromptRenderingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: FakeConnectionManager(),
            persistence: PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
        )
    }

    private func observe(in host: UIView, matching predicate: (String) -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: Self.observationTimeout)
        var labels = ""
        repeat {
            try await Task.sleep(for: Self.observationInterval)
            host.layoutIfNeeded()
            var visited: Set<ObjectIdentifier> = []
            labels = accessibilityText(under: host, visited: &visited).joined(separator: "\n")
            if predicate(labels) { return }
        } while Date() < deadline
        try #require(predicate(labels), "Unexpected rendered reply: \(labels)")
    }

    private func accessibilityText(
        under root: NSObject,
        visited: inout Set<ObjectIdentifier>,
        depth: Int = 12
    ) -> [String] {
        guard depth > 0, visited.insert(ObjectIdentifier(root)).inserted else { return [] }
        var children = (root.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        let count = root.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            children += (0..<count).compactMap { root.accessibilityElement(at: $0) as? NSObject }
        }
        if let view = root as? UIView { children += view.subviews }
        return [root.accessibilityLabel, root.accessibilityValue].compactMap { $0 }
            + children.flatMap { accessibilityText(under: $0, visited: &visited, depth: depth - 1) }
    }
}
