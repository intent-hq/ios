import Foundation
@testable import Intent
import Testing

/// Page walks for bounded daemon reads (PROTOCOL §5.2 "Bounded note and
/// comment reads", §6.9 "Paged snapshots", workspace "Paged workspace lists").
@MainActor
struct PagedReadsTests {
    private struct PageError: Error {}

    private static let noSleep: PagedReads.Sleep = { _ in }

    // MARK: - requestAllPages

    @Test func requestAllPagesFollowsTokensAcrossPages() async throws {
        var sent: [[String: Any]] = []
        let replies: [[String: Any]] = [
            ["notes": [["id": "a"], ["id": "b"]], "nextToken": "t1"],
            ["notes": [["id": "c"]], "nextToken": "t2"],
            ["notes": [["id": "d"]], "nextToken": NSNull()]
        ]
        let rows = try await PagedReads.requestAllPages(
            params: ["workspaceId": "ws-1", "limit": 2],
            field: "notes"
        ) { params in
            sent.append(params)
            return replies[sent.count - 1]
        }
        #expect(rows.compactMap { $0["id"] as? String } == ["a", "b", "c", "d"])
        #expect(sent.map { $0["nextToken"] as? String } == [nil, "t1", "t2"])
        #expect(sent.allSatisfy { $0["workspaceId"] as? String == "ws-1" && $0["limit"] as? Int == 2 })
    }

    @Test func requestAllPagesAcceptsEmptyLastPage() async throws {
        var calls = 0
        let rows = try await PagedReads.requestAllPages(params: [:], field: "threads") { _ in
            calls += 1
            return calls == 1
                ? ["threads": [["threadId": "t-1"]], "nextToken": "next"]
                : ["threads": [[String: Any]](), "nextToken": NSNull()]
        }
        #expect(rows.count == 1)
        #expect(calls == 2)
    }

    @Test func requestAllPagesEndsOnUnpagedReply() async throws {
        var calls = 0
        let rows = try await PagedReads.requestAllPages(params: [:], field: "workspaces") { _ in
            calls += 1
            return ["workspaces": [["id": "ws-1"], ["id": "ws-2"]]]
        }
        #expect(rows.count == 2)
        #expect(calls == 1)
    }

    @Test func requestAllPagesFailsOnARepeatedToken() async {
        var calls = 0
        await #expect(throws: PagedReads.IncompleteWalk.self) {
            _ = try await PagedReads.requestAllPages(params: [:], field: "notes") { _ in
                calls += 1
                return ["notes": [["id": "n-\(calls)"]], "nextToken": "same"]
            }
        }
        #expect(calls == 2)
    }

    @Test func requestAllPagesFailsAtThePageLimit() async {
        var calls = 0
        await #expect(throws: PagedReads.IncompleteWalk.self) {
            _ = try await PagedReads.requestAllPages(params: [:], field: "notes") { _ in
                calls += 1
                return ["notes": [[String: Any]](), "nextToken": "t\(calls)"]
            }
        }
        #expect(calls == PagedReads.maxPages)
    }

    @Test func fillSnapshotFailsOnARepeatedToken() async {
        var applied = 0
        let outcome = await PagedReads.fillSnapshot(
            from: "t1",
            source: Self.source { _ in ["notes": [["id": "b"]], "nextToken": "t1"] },
            isCurrent: Self.alwaysCurrent,
            sleep: Self.noSleep
        ) { _ in applied += 1 }
        #expect(outcome == .failed)
        #expect(applied == 1)
    }

    @Test func fillSnapshotFailsAtThePageLimit() async {
        var calls = 0
        let outcome = await PagedReads.fillSnapshot(
            from: "t0",
            source: Self.source { _ in
                calls += 1
                return ["notes": [[String: Any]](), "nextToken": "t\(calls)"]
            },
            isCurrent: Self.alwaysCurrent,
            sleep: Self.noSleep
        ) { _ in }
        #expect(outcome == .failed)
        #expect(calls == PagedReads.maxPages)
    }

    @Test func requestAllPagesThrowsWhenAPageFails() async {
        var calls = 0
        await #expect(throws: PageError.self) {
            _ = try await PagedReads.requestAllPages(params: [:], field: "notes") { _ in
                calls += 1
                if calls == 2 { throw PageError() }
                return ["notes": [["id": "a"]], "nextToken": "t1"]
            }
        }
    }

    // MARK: - fillSnapshot

    private static func source(_ requestPage: @escaping @MainActor (String) async throws -> Any) -> PagedReads.PageSource {
        PagedReads.PageSource(field: "notes", requestPage: requestPage)
    }

    private static func alwaysCurrent() -> Bool { true }

    private static func ids(_ rows: [[String: Any]]) -> [String] {
        rows.compactMap { $0["id"] as? String }
    }

    @Test func fillSnapshotReadsEveryPage() async {
        var tokens: [String] = []
        var applied: [String] = []
        let outcome = await PagedReads.fillSnapshot(
            from: "t1",
            source: Self.source { token in
                tokens.append(token)
                return token == "t1"
                    ? ["notes": [["id": "b"]], "nextToken": "t2"]
                    : ["notes": [[String: Any]](), "nextToken": NSNull()]
            },
            isCurrent: Self.alwaysCurrent,
            sleep: Self.noSleep
        ) { rows in applied += Self.ids(rows) }
        #expect(outcome == .completed)
        #expect(tokens == ["t1", "t2"])
        #expect(applied == ["b"])
    }

    @Test func fillSnapshotRetriesAFailedPage() async {
        var attempts = 0
        var sleeps: [Duration] = []
        var applied: [String] = []
        let outcome = await PagedReads.fillSnapshot(
            from: "t1",
            source: Self.source { _ in
                attempts += 1
                if attempts < 3 { throw PageError() }
                return ["notes": [["id": "b"]], "nextToken": NSNull()]
            },
            isCurrent: { true },
            sleep: { delay in sleeps.append(delay) },
            applyPage: { rows in applied += Self.ids(rows) }
        )
        #expect(outcome == .completed)
        #expect(attempts == 3)
        #expect(sleeps == [.milliseconds(250), .milliseconds(500)])
        #expect(applied == ["b"])
    }

    @Test func fillSnapshotFailsAfterThreeAttempts() async {
        var attempts = 0
        var applied = 0
        let outcome = await PagedReads.fillSnapshot(
            from: "t1",
            source: Self.source { _ in
                attempts += 1
                throw PageError()
            },
            isCurrent: Self.alwaysCurrent,
            sleep: Self.noSleep
        ) { _ in applied += 1 }
        #expect(outcome == .failed)
        #expect(attempts == PagedReads.pageAttempts)
        #expect(applied == 0)
    }

    @Test func fillSnapshotStopsWhenSuperseded() async {
        var current = true
        var applied = 0
        func isCurrent() -> Bool { current }
        let outcome = await PagedReads.fillSnapshot(
            from: "t1",
            source: Self.source { _ in
                current = false
                return ["notes": [["id": "b"]], "nextToken": "t2"]
            },
            isCurrent: isCurrent,
            sleep: Self.noSleep
        ) { _ in applied += 1 }
        #expect(outcome == .superseded)
        #expect(applied == 0)
    }
}
