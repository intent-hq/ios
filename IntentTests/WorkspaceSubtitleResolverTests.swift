import Foundation
@testable import Intent
import Testing

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
}
