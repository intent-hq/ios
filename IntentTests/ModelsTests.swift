import Foundation
import Testing
@testable import Intent

struct ModelsTests {
    @Test func pairedServerCodable() async throws {
        let server = PairedServer(hosts: ["192.168.1.1"], port: 3000, name: "My Mac", pairedAt: Date(timeIntervalSince1970: 1000))
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(PairedServer.self, from: data)
        #expect(decoded == server)
    }

    @Test func pairedServerCodableWithFingerprint() async throws {
        let server = PairedServer(
            hosts: ["192.168.1.1"], port: 3000, name: "My Mac",
            pairedAt: Date(timeIntervalSince1970: 1000),
            certFingerprint: "AA:BB:CC:DD:EE:FF"
        )
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(PairedServer.self, from: data)
        #expect(decoded == server)
        #expect(decoded.certFingerprint == "AA:BB:CC:DD:EE:FF")
    }

    @Test func pairedServerCodableWithoutFingerprint() async throws {
        let server = PairedServer(
            hosts: ["192.168.1.1"], port: 3000, name: "My Mac",
            pairedAt: Date(timeIntervalSince1970: 1000)
        )
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(PairedServer.self, from: data)
        #expect(decoded == server)
        #expect(decoded.certFingerprint == nil)
    }

    @Test func pairedServerCodableMultipleHosts() async throws {
        let server = PairedServer(
            hosts: ["192.168.1.1", "100.64.0.1"], port: 3000, name: "My Mac",
            pairedAt: Date(timeIntervalSince1970: 1000)
        )
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(PairedServer.self, from: data)
        #expect(decoded == server)
        #expect(decoded.hosts.count == 2)
        #expect(decoded.hosts[0] == "192.168.1.1")
        #expect(decoded.hosts[1] == "100.64.0.1")
    }

    @Test func workspaceEquality() async throws {
        let ws1 = Workspace(id: "1", title: "Test", branch: "main", baseRef: nil, status: "Active", lastActivity: nil, updatedAt: nil, repositoryOwner: "org", repositoryName: "repo", prStatus: nil, prNumber: nil, diffSummaryTotalFiles: nil, taskStatsTotal: nil, taskStatsCompleted: nil, taskStatsInProgress: nil, agentSummaryCount: nil, agentSummaryAgents: nil)
        let ws2 = Workspace(id: "1", title: "Test", branch: "main", baseRef: nil, status: "Active", lastActivity: nil, updatedAt: nil, repositoryOwner: "org", repositoryName: "repo", prStatus: nil, prNumber: nil, diffSummaryTotalFiles: nil, taskStatsTotal: nil, taskStatsCompleted: nil, taskStatsInProgress: nil, agentSummaryCount: nil, agentSummaryAgents: nil)
        #expect(ws1 == ws2)
    }

    @Test func workspaceInequalityDifferentId() async throws {
        let ws1 = Workspace(id: "1", title: "Test", branch: nil, baseRef: nil, status: nil, lastActivity: nil, updatedAt: nil, repositoryOwner: nil, repositoryName: nil, prStatus: nil, prNumber: nil, diffSummaryTotalFiles: nil, taskStatsTotal: nil, taskStatsCompleted: nil, taskStatsInProgress: nil, agentSummaryCount: nil, agentSummaryAgents: nil)
        let ws2 = Workspace(id: "2", title: "Test", branch: nil, baseRef: nil, status: nil, lastActivity: nil, updatedAt: nil, repositoryOwner: nil, repositoryName: nil, prStatus: nil, prNumber: nil, diffSummaryTotalFiles: nil, taskStatsTotal: nil, taskStatsCompleted: nil, taskStatsInProgress: nil, agentSummaryCount: nil, agentSummaryAgents: nil)
        #expect(ws1 != ws2)
    }
}

