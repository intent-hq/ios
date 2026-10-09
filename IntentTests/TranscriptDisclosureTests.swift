@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct TranscriptDisclosureTests {
    @Test func scopesChoicesToMessagesAndPrunesRemovedRows() {
        let first = TranscriptDisclosureStore()
        let second = TranscriptDisclosureStore()
        let state = first.state(for: "message")
        state.values[.tool("shared-block-id")] = true
        state.values[.toolInput("shared-block-id")] = false
        #expect(first.state(for: "message") === state)
        #expect(first.state(for: "other").values.isEmpty)
        #expect(second.state(for: "message").values.isEmpty)
        first.retainMessages(withIDs: ["message"])
        #expect(first.state(for: "message").values[.tool("shared-block-id")] == true)
        first.retainMessages(withIDs: [])
        #expect(first.state(for: "message").values.isEmpty)
    }

    @Test(arguments: [false, true])
    func expandedRowSurvivesMovingOutOfAndBackIntoTail(agentMessage: Bool) async throws {
        let state = ProbeState()
        let store = TranscriptDisclosureStore()
        let key: TranscriptDisclosureState.DisclosureKey = agentMessage ? .agentMessage : .tool("tool")
        let controller = UIHostingController(rootView: Probe(
            state: state, store: store, agentMessage: agentMessage, key: key
        ).environment(makeSession()).environment(\.workspaceTranscriptDesign, true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        controller.view.frame = window.bounds
        controller.beginAppearanceTransition(true, animated: false)
        window.addSubview(controller.view)
        window.isHidden = false
        controller.endAppearanceTransition()
        defer {
            controller.beginAppearanceTransition(false, animated: false)
            controller.view.removeFromSuperview()
            window.isHidden = true
            controller.endAppearanceTransition()
        }
        try await settle(controller)
        let collapsed = try #require(state.height)
        let binding = try #require(state.binding)
        binding.wrappedValue = true
        try await settle(controller)
        let expanded = try #require(state.height)
        #expect(expanded > collapsed)

        // Appending the thirteenth message moves row zero between ForEach parents.
        for count in [13, 12, 14] {
            let appearances = state.appearances
            state.count = count
            try await settle(controller)
            #expect(state.appearances > appearances, "The row must actually have been recreated")
            #expect(state.binding?.wrappedValue == true)
            #expect(abs((state.height ?? 0) - expanded) < 1, "The real disclosure must remain expanded")
        }
        state.binding?.wrappedValue = false
        try await settle(controller)
        #expect(abs((state.height ?? 0) - collapsed) < 1)
    }

    private func settle<Content: View>(_ controller: UIHostingController<Content>) async throws {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
    }

    @Observable final class ProbeState {
        var count = 12
        @ObservationIgnored var height: CGFloat?
        @ObservationIgnored var binding: Binding<Bool>?
        @ObservationIgnored var appearances = 0
    }

    private struct Probe: View {
        let state: ProbeState
        let store: TranscriptDisclosureStore
        let agentMessage: Bool
        let key: TranscriptDisclosureState.DisclosureKey
        private let tailLimit = 12

        var body: some View {
            VStack(spacing: 0) {
                ForEach(Array(0..<state.count).dropLast(tailLimit), id: \.self) { row($0) }
                VStack(spacing: 0) {
                    ForEach(Array(0..<state.count).suffix(tailLimit), id: \.self) { row($0) }
                }
            }
        }

        @ViewBuilder private func row(_ index: Int) -> some View {
            if index == 0 {
                HStack(spacing: 0) {
                    if agentMessage {
                        MessageView(message: message, workspaceId: "workspace")
                    } else {
                        ToolCallView(
                            block: ContentBlock(id: "tool", type: .toolUse, name: "shell"),
                            toolResult: ContentBlock(
                                id: "result",
                                type: .toolResult,
                                output: AnyCodable(String(repeating: "Details\n", count: 8))
                            )
                        )
                    }
                    BindingProbe(state: state, key: key).frame(width: 0, height: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.transcriptDisclosureState, store.state(for: "message"))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { state.height = $0 }
            } else {
                Color.clear.frame(height: 1)
            }
        }

        private var message: ConversationMessage {
            ConversationMessage(
                id: "message",
                role: .user,
                contentBlocks: [
                    ContentBlock(
                        id: "body",
                        type: .text,
                        text: String(repeating: "Expanded agent details.\n", count: 8),
                        messageMetadata: [
                            "type": AnyCodable("agent_message"),
                            "fromAgentId": AnyCodable("sender"),
                            "fromAgentName": AnyCodable("Sender")
                        ]
                    )
                ],
                timestamp: "2026-01-01T00:00:00Z"
            )
        }
    }

    private struct BindingProbe: View {
        let state: ProbeState
        let key: TranscriptDisclosureState.DisclosureKey
        var disclosure = TranscriptDisclosure()

        var body: some View {
            Color.clear.onAppear {
                state.binding = disclosure.binding(for: key)
                state.appearances += 1
            }
        }
    }

    private func makeSession() -> BackendSession {
        let connection = FakeConnectionManager()
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        return BackendSession(
            backendID: BackendID(UUID()),
            connection: connection,
            workspaceStore: WorkspaceStore(forTesting: true),
            coordinatorFactory: { _ in fatalError("Disclosure rendering must not create a coordinator") },
            githubRepoStore: GitHubRepoStore(connectionManager: connection),
            creationOptionsStore: CreationOptionsStore(connectionManager: connection),
            prMonitorsStore: WorkspacePrMonitorsStore(connectionManager: connection),
            attachmentUploadService: AttachmentUploadService(connection: connection),
            workspaceFileImageLoader: fileLoader,
            attachmentImageLoader: AttachmentImageLoader(connection: connection, fileLoader: fileLoader),
            attentionCueCenter: WorkspaceAttentionCueCenter {}
        )
    }
}
