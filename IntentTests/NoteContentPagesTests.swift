import Foundation
@testable import Intent
import Testing

/// Whole-note reads through the `note.get` content cursor (PROTOCOL §5.2
/// "Bounded note and comment reads").
@MainActor
struct NoteContentPagesTests {
    private struct PageError: Error {}

    private static let noSleep: PagedReads.Sleep = { _ in }

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
        let result = try await NoteContentPages.readWholeNote(params: ["noteId": "note-1"], sleep: Self.noSleep) { params in
            try daemon.reply(params)
        }
        #expect(Self.content(of: result)?["content"] as? String == "small note")
        #expect(daemon.calls.count == 1)
    }

    @Test func wholeNoteRestartsWhenTheNoteChanges() async throws {
        let full = String(repeating: "abc\n", count: 10)
        let daemon = FakeNoteGet(content: full, cuts: [12])
        daemon.bumpRevAfterFirstCall = true
        let result = try await NoteContentPages.readWholeNote(params: ["noteId": "note-1"], sleep: Self.noSleep) { params in
            try daemon.reply(params)
        }
        #expect(Self.content(of: result)?["content"] as? String == full)
        #expect(daemon.calls.map { $0["contentOffset"] as? Int } == [nil, 12, nil, 12])
    }

    @Test func wholeNoteRetriesAFailedPage() async throws {
        let full = String(repeating: "abc\n", count: 10)
        let daemon = FakeNoteGet(content: full, cuts: [12])
        daemon.failOffsets = [12: 2]
        let result = try await NoteContentPages.readWholeNote(params: ["noteId": "note-1"], sleep: Self.noSleep) { params in
            try daemon.reply(params)
        }
        #expect(Self.content(of: result)?["content"] as? String == full)
        #expect(daemon.calls.count == 4)
    }

    @Test func wholeNoteKeepsTheCutPrefixWhenAPageKeepsFailing() async throws {
        let full = String(repeating: "abc\n", count: 10)
        let daemon = FakeNoteGet(content: full, cuts: [12])
        daemon.failOffsets = [12: 99]
        let result = try await NoteContentPages.readWholeNote(params: ["noteId": "note-1"], sleep: Self.noSleep) { params in
            try daemon.reply(params)
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
