import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceSubtitleResolverTests {
    private func makeWorkspace(id: String, title: String) -> Workspace {
        WorkspaceStore.parseWorkspace(["id": id, "title": title])!
    }

    @Test func resolvesTitleForKnownWorkspace() async {
        let workspaces = [
            makeWorkspace(id: "ws-1", title: "Alpha"),
            makeWorkspace(id: "ws-2", title: "Beta")
        ]
        #expect(WorkspaceSubtitleResolver.subtitle(
            forWorkspaceId: "ws-2",
            in: workspaces
        ) == "Beta")
    }

    @Test func returnsNilForUnknownWorkspace() async {
        let workspaces = [makeWorkspace(id: "ws-1", title: "Alpha")]
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

    @Test func returnsNilForBlankTitle() async {
        // Never show a blank subtitle line — hide it instead.
        let workspaces = [makeWorkspace(id: "ws-1", title: "   ")]
        #expect(WorkspaceSubtitleResolver.subtitle(
            forWorkspaceId: "ws-1",
            in: workspaces
        ) == nil)
    }

    @Test func resolvesAgainstTestStoreWorkspaces() async {
        let store = WorkspaceStore(forTesting: true)
        store.publishFetchedWorkspaces([makeWorkspace(id: "ws-1", title: "My Workspace")])
        #expect(WorkspaceSubtitleResolver.subtitle(
            forWorkspaceId: "ws-1",
            in: store.workspaces
        ) == "My Workspace")
    }
}
