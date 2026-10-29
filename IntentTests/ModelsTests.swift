import Foundation
@testable import Intent
import Testing

struct ModelsTests {
    /// Records saved before the tcAddress field existed must keep decoding
    /// (the optional field defaults to nil).
    @Test func pairedServerDecodesLegacyJSONWithoutTcAddress() throws {
        let legacy = Data("""
        {"hosts":["192.168.1.1"],"port":3000,"name":"My Mac","pairedAt":1000}
        """.utf8)
        let decoded = try JSONDecoder().decode(PairedServer.self, from: legacy)
        #expect(decoded.tcAddress == nil)
        #expect(decoded.hosts == ["192.168.1.1"])
    }

    // MARK: - Workspace.pullRequests (PROTOCOL §5.1 / §7.6)

    @Test func workspaceDecodesPullRequests() throws {
        let json = Data("""
        {
            "id": "ws-1",
            "title": "Test",
            "pullRequests": [
                {
                    "id": "pr-1",
                    "number": 42,
                    "title": "feat: add thing",
                    "url": "https://github.com/acme/app/pull/42",
                    "status": "Open",
                    "createdAt": "2026-08-01T10:00:00Z",
                    "updatedAt": "2026-08-02T10:00:00Z"
                },
                {
                    "number": 43,
                    "status": "Merged"
                }
            ]
        }
        """.utf8)
        let workspace = try JSONDecoder().decode(Workspace.self, from: json)
        let pullRequests = workspace.pullRequests
        #expect(pullRequests.count == 2)
        #expect(pullRequests[0].number == 42)
        #expect(pullRequests[0].title == "feat: add thing")
        #expect(pullRequests[0].url == "https://github.com/acme/app/pull/42")
        #expect(pullRequests[0].status == "Open")
        #expect(pullRequests[0].createdAt == "2026-08-01T10:00:00Z")
        #expect(pullRequests[0].updatedAt == "2026-08-02T10:00:00Z")
        #expect(pullRequests[1].number == 43)
        #expect(pullRequests[1].status == "Merged")
        #expect(pullRequests[1].title == nil)
        #expect(pullRequests[1].url == nil)
    }

    @Test func workspaceDecodesAbsentPullRequestsAsUnreportedEmptyPool() throws {
        let json = Data("""
        {"id": "ws-1", "title": "Test"}
        """.utf8)
        let workspace = try JSONDecoder().decode(Workspace.self, from: json)
        #expect(workspace.pullRequests.isEmpty)
        #expect(workspace.pullRequestsWereReported == false)
    }

    @Test func workspacePullRequestKeepsUnknownStatusRaw() throws {
        // Future status variants pass through as raw strings (lenient).
        let json = Data("""
        {"id": "ws-1", "title": "Test", "pullRequests": [{"number": 7, "status": "SomeFutureStatus"}]}
        """.utf8)
        let workspace = try JSONDecoder().decode(Workspace.self, from: json)
        #expect(workspace.pullRequests.count == 1)
        #expect(workspace.pullRequests.first?.status == "SomeFutureStatus")
    }

    // MARK: - Workspace.activePullRequest (PROTOCOL §5.1 / §7.6)

    @Test func workspaceDecodesActivePullRequest() throws {
        let json = Data("""
        {
            "id": "ws-1",
            "title": "Test",
            "activePullRequest": {
                "id": "pr-1",
                "number": 42,
                "title": "feat: add thing",
                "url": "https://github.com/acme/app/pull/42",
                "status": "Open",
                "createdAt": "2026-08-01T10:00:00Z",
                "updatedAt": "2026-08-02T10:00:00Z"
            }
        }
        """.utf8)
        let workspace = try JSONDecoder().decode(Workspace.self, from: json)
        let pullRequest = try #require(workspace.activePullRequest)
        #expect(pullRequest.number == 42)
        #expect(pullRequest.status == "Open")
        #expect(pullRequest.title == "feat: add thing")
        #expect(pullRequest.url == "https://github.com/acme/app/pull/42")
        #expect(pullRequest.createdAt == "2026-08-01T10:00:00Z")
        #expect(pullRequest.updatedAt == "2026-08-02T10:00:00Z")
    }

    @Test func workspaceDecodesAbsentActivePullRequestAsNil() throws {
        let json = Data("""
        {"id": "ws-1", "title": "Test"}
        """.utf8)
        let workspace = try JSONDecoder().decode(Workspace.self, from: json)
        #expect(workspace.activePullRequest == nil)
    }
}
