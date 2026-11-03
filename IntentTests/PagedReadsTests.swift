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

    @Test func requestAllPagesStopsOnRepeatedToken() async throws {
        var calls = 0
        let rows = try await PagedReads.requestAllPages(params: [:], field: "notes") { _ in
            calls += 1
            return ["notes": [["id": "n-\(calls)"]], "nextToken": "same"]
        }
        #expect(calls == 2)
        #expect(rows.count == 2)
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

    private static func source(_ requestPage: @escaping (String) async throws -> Any) -> PagedReads.PageSource {
        PagedReads.PageSource(field: "notes", requestPage: requestPage)
    }

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
            isCurrent: { true },
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
            sleep: { delay in sleeps.append(delay) }
        ) { rows in applied += Self.ids(rows) }
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
            isCurrent: { true },
            sleep: Self.noSleep
        ) { _ in applied += 1 }
        #expect(outcome == .failed)
        #expect(attempts == PagedReads.pageAttempts)
        #expect(applied == 0)
    }

    @Test func fillSnapshotStopsWhenSuperseded() async {
        var current = true
        var applied = 0
        let outcome = await PagedReads.fillSnapshot(
            from: "t1",
            source: Self.source { _ in
                current = false
                return ["notes": [["id": "b"]], "nextToken": "t2"]
            },
            isCurrent: { current },
            sleep: Self.noSleep
        ) { _ in applied += 1 }
        #expect(outcome == .superseded)
        #expect(applied == 0)
    }

    // MARK: - NoteContentPages

    /// A fake bounded `note.get`: serves `content` from `contentOffset` up to
    /// the next cut in `cuts` (UTF-8 byte offsets), with the §5.2 markers.
    private final class FakeNoteGet {
        let bytes: [UInt8]
        let cuts: [Int]
        var rev = 7
        var calls: [[String: Any]] = []
        var failOffsets: [Int: Int] = [:]
        var bumpRevAfterFirstCall = false

        init(content: String, cuts: [Int]) {
            bytes = Array(content.utf8)
            self.cuts = cuts
        }

        func reply(_ params: [String: Any]) throws -> Any {
            calls.append(params)
            let offset = params["contentOffset"] as? Int ?? 0
            if let remaining = failOffsets[offset], remaining > 0 {
                failOffsets[offset] = remaining - 1
                throw PageError()
            }
            let end = cuts.first { $0 > offset } ?? bytes.count
            var note: [String: Any] = [
                "id": "note-1",
                "title": "Big",
                "rev": rev,
                "updatedAt": "2026-11-03T00:00:00Z",
                "content": String(bytes: bytes[offset..<end], encoding: .utf8) ?? ""
            ]
            if end < bytes.count || offset > 0 {
                note["contentTruncated"] = true
                note["contentBytes"] = bytes.count
                note["contentOffset"] = offset
                note["nextContentOffset"] = end < bytes.count ? end : NSNull()
            }
            if bumpRevAfterFirstCall, calls.count == 1 { rev += 1 }
            return ["note": note]
        }
    }

    /// Byte offsets just after each character, i.e. valid cut points.
    private static func boundaries(_ text: String) -> [Int] {
        var offsets: [Int] = []
        var total = 0
        for scalar in text.unicodeScalars {
            total += String(scalar).utf8.count
            offsets.append(total)
        }
        return offsets
    }

    // swiftlint:disable:next discouraged_optional_collection
    private static func content(of result: Any) -> [String: Any]? {
        (result as? [String: Any])?["note"] as? [String: Any]
    }

    @Test(arguments: [
        "héllo wörld\n",
        "line one\r\nline two\r\n🌍🌍🌍 end",
        "日本語のノート🎉と絵文字👩‍👩‍👧"
    ])
    func wholeNoteJoinsPagesAtUTF8Boundaries(text: String) async throws {
        let full = String(repeating: text, count: 4)
        let marks = Self.boundaries(full)
        // Cut at three character boundaries, including inside a multi-scalar
        // emoji sequence where one exists (scalar, not grapheme, boundaries).
        let cuts = [marks[marks.count / 4], marks[marks.count / 2], marks[(marks.count * 3) / 4]]
        let daemon = FakeNoteGet(content: full, cuts: cuts)
        let result = try await NoteContentPages.readWholeNote(
            params: ["noteId": "note-1", "workspaceId": "ws-1"],
            sleep: Self.noSleep
        ) { params in try daemon.reply(params) }
        let note = try #require(Self.content(of: result))
        #expect(note["content"] as? String == full)
        #expect((note["content"] as? String)?.utf8.count == full.utf8.count)
        for key in ["contentTruncated", "contentBytes", "contentOffset", "nextContentOffset"] {
            #expect(note[key] == nil, "\(key) should be dropped from a whole read")
        }
        #expect(daemon.calls.map { $0["contentOffset"] as? Int } == [nil] + cuts.map { Optional($0) })
        #expect(daemon.calls.allSatisfy { $0["noteId"] as? String == "note-1" })
        let parsed = try #require(Note.parseNote(note))
        #expect(!parsed.contentTruncated)
    }

    @Test func wholeNoteFromOlderDaemonIsOneRead() async throws {
        let daemon = FakeNoteGet(content: "small note", cuts: [])
        let result = try await NoteContentPages.readWholeNote(params: ["noteId": "note-1"], sleep: Self.noSleep) {
            try daemon.reply($0)
        }
        #expect(Self.content(of: result)?["content"] as? String == "small note")
        #expect(daemon.calls.count == 1)
    }

    @Test func wholeNoteRestartsWhenTheNoteChanges() async throws {
        let full = String(repeating: "abc\n", count: 10)
        let daemon = FakeNoteGet(content: full, cuts: [12])
        daemon.bumpRevAfterFirstCall = true
        let result = try await NoteContentPages.readWholeNote(params: ["noteId": "note-1"], sleep: Self.noSleep) {
            try daemon.reply($0)
        }
        #expect(Self.content(of: result)?["content"] as? String == full)
        #expect(daemon.calls.map { $0["contentOffset"] as? Int } == [nil, 12, nil, 12])
    }

    @Test func wholeNoteRetriesAFailedPage() async throws {
        let full = String(repeating: "abc\n", count: 10)
        let daemon = FakeNoteGet(content: full, cuts: [12])
        daemon.failOffsets = [12: 2]
        let result = try await NoteContentPages.readWholeNote(params: ["noteId": "note-1"], sleep: Self.noSleep) {
            try daemon.reply($0)
        }
        #expect(Self.content(of: result)?["content"] as? String == full)
        #expect(daemon.calls.count == 4)
    }

    @Test func wholeNoteKeepsTheCutPrefixWhenAPageKeepsFailing() async throws {
        let full = String(repeating: "abc\n", count: 10)
        let daemon = FakeNoteGet(content: full, cuts: [12])
        daemon.failOffsets = [12: 99]
        let result = try await NoteContentPages.readWholeNote(params: ["noteId": "note-1"], sleep: Self.noSleep) {
            try daemon.reply($0)
        }
        let note = try #require(Self.content(of: result))
        #expect(note["content"] as? String == "abc\nabc\nabc\n")
        #expect(note["contentTruncated"] as? Bool == true)
        let parsed = try #require(Note.parseNote(note))
        #expect(parsed.contentTruncated)
        #expect(parsed.contentBytes == full.utf8.count)
    }

    @Test func wholeNoteKeepsTheCutPrefixWhenBytesDoNotAddUp() async throws {
        var calls = 0
        let result = try await NoteContentPages.readWholeNote(params: ["noteId": "note-1"], sleep: Self.noSleep) { _ in
            calls += 1
            let first = calls == 1
            let note: [String: Any] = [
                "id": "note-1",
                "title": "Big",
                "rev": 1,
                "content": first ? "abc\n" : "def",
                "contentTruncated": true,
                "contentBytes": 100,
                "contentOffset": first ? 0 : 4,
                "nextContentOffset": first ? 4 : NSNull()
            ]
            return ["note": note]
        }
        #expect(Self.content(of: result)?["content"] as? String == "abc\n")
        #expect(Self.content(of: result)?["contentTruncated"] as? Bool == true)
    }

    @Test func wholeNoteFirstReadErrorPropagates() async {
        await #expect(throws: PageError.self) {
            _ = try await NoteContentPages.readWholeNote(params: ["noteId": "note-1"], sleep: Self.noSleep) { _ in
                throw PageError()
            }
        }
    }
}
