import Foundation
@testable import Intent
import Testing

@MainActor
struct ContentBlockLinkTests {
    @Test(arguments: [
        ("intent://local/file/report.pdf", "current", "report.pdf"),
        ("intent://local/linked/file/report.pdf", "linked", "report.pdf"),
        ("intent://local/file/reports/Review%20notes.PDF?backend=other#page=2", "current", "reports/Review notes.PDF"),
        ("intent://local/linked/file/Review%20%231%3F%25%2Epdf", "linked", "Review #1?%.pdf"),
        ("intent://local/file/note/report.pdf", "current", "note/report.pdf")
    ])
    func pdfLinksOpenInViewer(address: String, expectedWorkspace: String, expectedPath: String) throws {
        let url = try #require(URL(string: address))
        #expect(ContentBlockBody.textURLRoute(for: url, workspaceId: "current") == .pdf(
            .init(workspaceId: expectedWorkspace, path: expectedPath)
        ))
    }

    @Test(arguments: [
        ("intent://local/file/notes.txt", "current", "notes.txt"),
        ("intent://local/linked/file/notes.TXT", "linked", "notes.TXT"),
        ("intent://local/file/reports/Review%20notes.TxT?backend=other#section", "current", "reports/Review notes.TxT"),
        ("intent://local/linked/file/Review%20%231%3F%25%2Etxt", "linked", "Review #1?%.txt"),
        ("intent://local/file/report.pdf.txt", "current", "report.pdf.txt"),
        ("intent://local/file/note/notes.txt", "current", "note/notes.txt")
    ])
    func textLinksOpenInViewer(address: String, expectedWorkspace: String, expectedPath: String) throws {
        let url = try #require(URL(string: address))
        #expect(ContentBlockBody.textURLRoute(for: url, workspaceId: "current") == .text(
            .init(workspaceId: expectedWorkspace, path: expectedPath)
        ))
    }

    @Test func chiefWorkspaceTextLinkKeepsExplicitTarget() throws {
        let url = try #require(URL(string: "intent://local/linked/file/notes.txt"))
        #expect(ContentBlockBody.textURLRoute(for: url, workspaceId: Workspace.chiefWorkspaceId) == .text(
            .init(workspaceId: "linked", path: "notes.txt")
        ))
    }

    @Test(arguments: [
        ("intent://local/note/spec", "current", "spec"),
        ("intent://local/task/task-1", "current", "task-1"),
        ("intent://local/linked/note/spec", "linked", "spec"),
        ("intent://local/linked/task/task-1", "linked", "task-1"),
        ("intent://local/note/report.pdf", "current", "report.pdf"),
        ("intent://local/note/notes.txt", "current", "notes.txt")
    ])
    func noteLinksKeepNavigation(address: String, expectedWorkspace: String, expectedNote: String) throws {
        let url = try #require(URL(string: address))
        #expect(ContentBlockBody.textURLRoute(for: url, workspaceId: "current") == .note(
            id: expectedNote, workspaceId: expectedWorkspace
        ))
    }

    @Test(arguments: [
        "intent://local/file/image.png",
        "intent://local/file/movie.mp4",
        "intent://local/file/readme.md",
        "intent://local/file/output.log",
        "intent://local/file/data.csv",
        "intent://local/file/config.json",
        "intent://local/file/notes.txt/child",
        "intent://local/file/../notes.txt",
        "intent://local/linked/file/%2E%2E/notes.txt",
        "intent://local/file/reports%2Fnotes.txt",
        "intent://remote/file/notes.txt",
        "workspace-asset://current/notes.txt",
        "https://example.com/notes.txt",
        "intent://local/file/report.pdf/child",
        "intent://local/file/report",
        "intent://local/file/../report.pdf",
        "intent://local/linked/file/%2E%2E/report.pdf",
        "intent://local/file/reports%2Freport.pdf",
        "intent://local/file//report.pdf",
        "intent://remote/file/report.pdf",
        "intent://local/file",
        "workspace-asset://current/report.pdf",
        "https://example.com/report.pdf",
        "http://localhost:5173/report.pdf",
        "file:///tmp/report.pdf",
        "mailto:hello@example.com"
    ])
    func otherLinksKeepSystemRouting(_ address: String) throws {
        let url = try #require(URL(string: address))
        #expect(ContentBlockBody.textURLRoute(for: url, workspaceId: "current") == .system)
    }
}
