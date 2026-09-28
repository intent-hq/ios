import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceStatusMessageTests {
    @Test func statusMessageSurvivesWireParsingAndCodableRoundTrip() throws {
        let summary = "Waiting for review before shipping."
        let workspace = try #require(WorkspaceStore.parseWorkspace([
            "id": "ws-summary", "title": "Summary", "statusMessage": summary
        ]))
        #expect(workspace.statusMessage == summary)
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        #expect(decoded.statusMessage == summary)
    }

    @Test func missingAndClearedMessagesRemainOptional() throws {
        var row: [String: Any] = ["id": "ws-summary", "title": "Summary"]
        let oldData = try JSONSerialization.data(withJSONObject: row)
        #expect(try JSONDecoder().decode(Workspace.self, from: oldData).statusMessage == nil)
        #expect(WorkspaceStore.parseWorkspace(row)?.statusMessage == nil)
        row["statusMessage"] = NSNull()
        #expect(WorkspaceStore.parseWorkspace(row)?.statusMessage == nil)
        let clearedData = try JSONSerialization.data(withJSONObject: row)
        #expect(try JSONDecoder().decode(Workspace.self, from: clearedData).statusMessage == nil)
    }
}
