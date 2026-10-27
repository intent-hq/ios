import Foundation
@testable import Intent
import Observation
import SwiftUI
import Testing
import UIKit

@MainActor
struct WorkspaceSubtitleResolverTests {
    private func makeWorkspace(id: String, title: String) throws -> Workspace {
        try #require(WorkspaceStore.parseWorkspace(["id": id, "title": title]))
    }

    @Test func resolvesTitleForKnownWorkspace() async throws {
        let workspaces = [
            try makeWorkspace(id: "ws-1", title: "Alpha"),
            try makeWorkspace(id: "ws-2", title: "Beta")
        ]
        #expect(WorkspaceSubtitleResolver.subtitle(
            forWorkspaceId: "ws-2",
            in: workspaces
        ) == "Beta")
    }

    @Test func returnsNilForUnknownWorkspace() async throws {
        let workspaces = [try makeWorkspace(id: "ws-1", title: "Alpha")]
        #expect(WorkspaceSubtitleResolver.subtitle(
            forWorkspaceId: "ws-missing",
            in: workspaces
        ) == nil)
    }

    @Test func returnsNilForEmptyStore() async {
        // Cold start / deep link before the first fetch lands.
        #expect(WorkspaceSubtitleResolver.subtitle(
            forWorkspaceId: "ws-1",
            in: []
        ) == nil)
    }

    @Test func returnsNilForBlankTitle() async throws {
        // Never show a blank subtitle line — hide it instead.
        let workspaces = [try makeWorkspace(id: "ws-1", title: "   ")]
        #expect(WorkspaceSubtitleResolver.subtitle(
            forWorkspaceId: "ws-1",
            in: workspaces
        ) == nil)
    }

    @Test func resolvesAgainstTestStoreWorkspaces() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.publishFetchedWorkspaces([try makeWorkspace(id: "ws-1", title: "My Workspace")])
        #expect(WorkspaceSubtitleResolver.subtitle(
            forWorkspaceId: "ws-1",
            in: store.workspaces
        ) == "My Workspace")
    }

    @Test func subtitleVisibilityChangesRetainFocusedEditor() async throws {
        let session = WorkspaceDetailViewTests().makePinnedSession(connection: FakeConnectionManager())
        session.workspaceStore.publishFetchedWorkspaces([try makeWorkspace(id: "ws-1", title: "Workspace")])
        let state = SubtitleEditorState()
        let content = SubtitleEditorHost(state: state)
            .environment(session)
            .transaction { $0.disablesAnimations = true }
        try await SyntheticBadgeHost.render(content, width: 600, height: 800) { host, window in
            let previousKey = window.windowScene?.keyWindow
            window.makeKey()
            defer {
                window.endEditing(true)
                previousKey?.makeKey()
            }
            try await waitUntil("the editor appears") { subtitleEditor(in: host) != nil }
            let editor = try #require(subtitleEditor(in: host))
            let draft = "Keep this selected draft"
            let selection = NSRange(location: 5, length: 4)
            editor.text = draft
            editor.selectedRange = selection
            try #require(editor.becomeFirstResponder())

            for workspaceId in ["ws-1", "", "ws-1"] {
                state.workspaceId = workspaceId
                state.revision += 1
                try await waitUntil("the subtitle change reaches the native editor") {
                    subtitleEditor(in: host)?.accessibilityValue == String(state.revision)
                }
                let updatedEditor = try #require(subtitleEditor(in: host))
                #expect(updatedEditor === editor)
                #expect(updatedEditor.isFirstResponder)
                #expect(updatedEditor.text == draft)
                #expect(updatedEditor.selectedRange == selection)
            }
        }
    }

    private func subtitleEditor(in view: UIView) -> UITextView? {
        if let editor = view as? UITextView, editor.accessibilityIdentifier == "subtitle.editor" { return editor }
        return view.subviews.lazy.compactMap { subtitleEditor(in: $0) }.first
    }
}

@MainActor @Observable
private final class SubtitleEditorState {
    var workspaceId = ""
    var revision = 0
}

private struct SubtitleEditorHost: View {
    let state: SubtitleEditorState

    var body: some View {
        NavigationStack {
            SubtitleEditor(revision: state.revision)
                .workspaceNavigationSubtitle(title: "Agent", workspaceId: state.workspaceId)
        }
    }
}

private struct SubtitleEditor: UIViewRepresentable {
    let revision: Int

    func makeUIView(context _: Context) -> UITextView {
        let editor = UITextView()
        editor.accessibilityIdentifier = "subtitle.editor"
        return editor
    }

    func updateUIView(_ editor: UITextView, context _: Context) {
        editor.accessibilityValue = String(revision)
    }
}
