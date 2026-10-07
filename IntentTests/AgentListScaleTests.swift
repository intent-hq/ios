import Foundation
@testable import Intent
import Testing

@MainActor
struct AgentListScaleTests {
    private let largeCount = 2000

    @Test func wideTreePreservesEveryAgentAndRefreshesMembership() throws {
        let model = AgentListViewModel()
        let children = try (0..<largeCount).map { try agent("child-\($0)", parent: "root") }
        model.agents = try [agent("root")] + children
        #expect(model.foregroundAgents.map(\.id) == ["root"])
        #expect(model.count(for: .delegated(parentId: "root")) == largeCount)
        model.toggle(.delegated(parentId: "root"))
        let visible = model.visibleTree(model.foregroundAgents)
        #expect(visible.count == largeCount + 1)
        #expect(Set(visible.map(\.id)) == Set(model.agents.map(\.id)))
        #expect(visible.dropFirst().allSatisfy { $0.depth == 1 })

        var retired = try agent("root")
        retired.retiredAt = "2026-10-01T00:00:00Z"
        model.agents = [retired] + Array(children.dropLast())
        #expect(model.foregroundAgents.count == largeCount - 1)
        #expect(model.delegatedAgents(for: "root").count == largeCount - 1)
        model.reset()
        #expect(model.foregroundAgents.isEmpty)
        #expect(model.delegatedAgents(for: "root").isEmpty)
    }

    @Test func deepTreeIsIterativeAndCollapseHidesOnlyDescendants() throws {
        let model = AgentListViewModel()
        model.agents = try (0..<largeCount).map { index in
            try agent("agent-\(index)", parent: index == 0 ? nil : "agent-\(index - 1)")
        }
        model.expandedGroups = Set(model.agents.map { .delegated(parentId: $0.id) })
        let visible = model.visibleTree(model.foregroundAgents)
        #expect(visible.map(\.id) == model.agents.map(\.id))
        #expect(visible.map(\.depth) == Array(0..<largeCount))
        let midpoint = largeCount / 2
        model.toggle(.delegated(parentId: "agent-\(midpoint)"))
        #expect(model.visibleTree(model.foregroundAgents).count == midpoint + 1)
    }

    @Test func cycleAndDuplicateRootsDoNotDuplicateVisibleRows() throws {
        let model = AgentListViewModel()
        model.agents = try [agent("first", parent: "second"), agent("second", parent: "first")]
        model.expandedGroups = [.delegated(parentId: "first"), .delegated(parentId: "second")]
        let visible = model.visibleTree(model.agents + model.agents)
        #expect(visible.map(\.id) == ["first", "second"])
        #expect(visible.map(\.depth) == [0, 1])
    }

    private func agent(_ id: String, parent: String? = nil) throws -> AgentSession {
        var wire: [String: Any] = [
            "id": id, "name": id, "status": "idle", "lastActivity": "2026-10-01T12:00:00.123Z"
        ]
        wire["parentAgentId"] = parent
        return try #require(AgentSession.parseAgent(wire))
    }
}
