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
        ("intent://local/file/note/notes.txt", "current", "note/notes.txt"),
        ("intent://local/file/README.md", "current", "README.md"),
        ("intent://local/file/config.json", "current", "config.json"),
        ("intent://local/file/output.log", "current", "output.log"),
        ("intent://local/file/data.csv", "current", "data.csv"),
        ("intent://local/file/config.yaml", "current", "config.yaml"),
        ("intent://local/file/Sources/App.swift", "current", "Sources/App.swift"),
        ("intent://local/file/README.MD", "current", "README.MD"),
        ("intent://local/file/Makefile", "current", "Makefile"),
        ("intent://local/file/LICENSE", "current", "LICENSE"),
        ("intent://local/file/.env.example", "current", ".env.example"),
        ("intent://local/linked/file/README.md", "linked", "README.md"),
        ("intent://local/file/notes.txt/child", "current", "notes.txt/child"),
        ("intent://local/file/report.pdf/child", "current", "report.pdf/child"),
        ("intent://local/file/report", "current", "report"),
        ("intent://local/file/archive.zip", "current", "archive.zip"),
        ("intent://local/file/database.sqlite", "current", "database.sqlite"),
        ("intent://local/file/page.html.txt", "current", "page.html.txt")
    ])
    func textLinksOpenInViewer(address: String, expectedWorkspace: String, expectedPath: String) throws {
        let url = try #require(URL(string: address))
        #expect(ContentBlockBody.textURLRoute(for: url, workspaceId: "current") == .text(
            .init(workspaceId: expectedWorkspace, path: expectedPath)
        ))
    }

    @Test(arguments: [
        ("intent://local/file/page.html", "current", "page.html"),
        ("intent://local/linked/file/page.HTM", "linked", "page.HTM"),
        ("intent://local/file/Review%20%231%2EHTML?backend=other#section", "current", "Review #1.HTML")
    ])
    func htmlLinksOpenRenderedPage(address: String, expectedWorkspace: String, expectedPath: String) throws {
        let url = try #require(URL(string: address))
        #expect(ContentBlockBody.textURLRoute(for: url, workspaceId: "current") == .html(
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
        ("intent://local/note/notes.txt", "current", "notes.txt"),
        ("intent://local/note/page.html", "current", "page.html")
    ])
    func noteLinksKeepNavigation(address: String, expectedWorkspace: String, expectedNote: String) throws {
        let url = try #require(URL(string: address))
        #expect(ContentBlockBody.textURLRoute(for: url, workspaceId: "current") == .note(
            id: expectedNote, workspaceId: expectedWorkspace
        ))
    }

    @Test(arguments: [
        "intent://local/file/image.png",
        "intent://local/linked/file/image.PNG",
        "intent://local/file/movie.mp4",
        "intent://local/linked/file/movie.MP4",
        "intent://local/file/movie.webm",
        "intent://local/file/../notes.txt",
        "intent://local/linked/file/%2E%2E/notes.txt",
        "intent://local/file/reports%2Fnotes.txt",
        "intent://remote/file/notes.txt",
        "workspace-asset://current/notes.txt",
        "https://example.com/notes.txt",
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
        "mailto:hello@example.com",
        "https://example.com/page.html",
        "intent://local/file/../page.html",
        "workspace-asset://current/page.html"
    ])
    func otherLinksKeepSystemRouting(_ address: String) throws {
        let url = try #require(URL(string: address))
        #expect(ContentBlockBody.textURLRoute(for: url, workspaceId: "current") == .system)
    }
}
