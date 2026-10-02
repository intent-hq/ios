import Foundation
@testable import Intent
import Testing

struct AgentHistoryTests {
    private static let phone = UUID()
    private static let laptop = UUID()

    private func entry(
        _ agentId: String,
        on connectionId: UUID = Self.phone,
        workspaceId: String = "workspace",
        title: String? = "Workspace",
        at seconds: TimeInterval = 0
    ) -> AgentHistoryEntry {
        AgentHistoryEntry(
            connectionId: connectionId,
            workspaceId: workspaceId,
            workspaceTitle: title,
            agentId: agentId,
            agentName: agentId,
            visitedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test func revisitMovesTheAgentToTheFrontWithoutDuplicating() {
        let updated = AgentHistory.recording(entry("a", at: 10), in: [entry("b"), entry("a")])
        #expect(updated.map(\.agentId) == ["a", "b"])
        #expect(updated.first?.visitedAt == Date(timeIntervalSince1970: 10))
    }

    @Test func theSameAgentIdOnAnotherDeviceIsASeparateEntry() {
        let updated = AgentHistory.recording(entry("a", on: Self.laptop), in: [entry("a")])
        #expect(updated.map(\.connectionId) == [Self.laptop, Self.phone])
    }

    @Test func aVisitBeforeTheWorkspaceListLoadsKeepsTheKnownTitle() {
        let updated = AgentHistory.recording(entry("a", title: nil), in: [entry("a", title: "Known")])
        #expect(updated.first?.workspaceTitle == "Known")
    }

    @Test func theOldestVisitDropsOutAtTheLimit() {
        let updated = AgentHistory.recording(entry("new"), in: [entry("a"), entry("b"), entry("c")], limit: 3)
        #expect(updated.map(\.agentId) == ["new", "a", "b"])
    }

    @Test func removingAWorkspaceDropsOnlyThatDevicesEntriesForIt() {
        let history = [
            entry("kept"),
            entry("removed", workspaceId: "gone"),
            entry("other-device", on: Self.laptop, workspaceId: "gone")
        ]
        let pruned = AgentHistory.removing(workspaceId: "gone", on: Self.phone, from: history)
        #expect(pruned.map(\.agentId) == ["kept", "other-device"])
    }

    @Test func forgottenDevicesAreHidden() {
        let visible = AgentHistory.visible(
            [entry("a"), entry("b", on: Self.laptop)],
            savedConnectionIDs: [Self.laptop]
        )
        #expect(visible.map(\.agentId) == ["b"])
    }

    @Test @MainActor func historySurvivesARelaunch() throws {
        let suiteName = "AgentHistoryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())

        AgentHistoryStore(persistence: persistence).record(entry("a", on: Self.laptop))

        let relaunched = AgentHistoryStore(persistence: persistence)
        #expect(relaunched.entries.map(\.id) == ["\(Self.laptop.uuidString)/a"])
    }
}
