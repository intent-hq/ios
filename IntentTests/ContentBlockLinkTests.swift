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
        "https://example.com/notes.txt",
        "https://example.com/report.pdf",
        "http://localhost:5173/report.pdf",
        "mailto:hello@example.com",
        "https://example.com/page.html",
        "intent://pair?payload=abc"
    ])
    func otherLinksKeepSystemRouting(_ address: String) throws {
        let url = try #require(URL(string: address))
        #expect(ContentBlockBody.textURLRoute(for: url, workspaceId: "current") == .system)
    }

    @Test(arguments: [
        ("intent://local/file/image.png", UnopenableLink.Reason.unsupportedIntentLink),
        ("intent://local/linked/file/image.PNG", .unsupportedIntentLink),
        ("intent://local/file/movie.mp4", .unsupportedIntentLink),
        ("intent://local/linked/file/movie.MP4", .unsupportedIntentLink),
        ("intent://local/file/movie.webm", .unsupportedIntentLink),
        ("intent://local/file/../notes.txt", .unsupportedIntentLink),
        ("intent://local/linked/file/%2E%2E/notes.txt", .unsupportedIntentLink),
        ("intent://local/file/reports%2Fnotes.txt", .unsupportedIntentLink),
        ("intent://remote/file/notes.txt", .unsupportedIntentLink),
        ("intent://local/file/../report.pdf", .unsupportedIntentLink),
        ("intent://local/file//report.pdf", .unsupportedIntentLink),
        ("intent://local/file", .unsupportedIntentLink),
        ("intent://local/settings", .unsupportedIntentLink),
        ("intent://local/file/../page.html", .unsupportedIntentLink),
        ("workspace-asset://current/notes.txt", .unsupportedLocation),
        // Path links that can't be resolved to a workspace file keep the message.
        ("../report.html", .unsupportedLocation),
        ("reports/../../report.html", .unsupportedLocation),
        ("./../report.html", .unsupportedLocation),
        ("reports//report.html", .unsupportedLocation),
        ("reports/", .unsupportedLocation),
        ("reports%5Creport.html", .unsupportedLocation),
        ("reports%2Freport.html", .unsupportedLocation),
        ("/Users/me/../report.html", .unsupportedLocation),
        ("/", .unsupportedLocation),
        ("#summary", .unsupportedLocation),
        ("C:/Users/me/report.html", .unsupportedLocation),
        ("file://server/share/report.html", .unsupportedLocation),
        ("file:report.html", .unsupportedLocation),
        ("file:///tmp/../report.pdf", .unsupportedLocation),
        ("reports/chart.png", .unsupportedLocation),
        ("file:///Users/me/movie.mp4", .unsupportedLocation)
    ])
    func unopenableLinksShowAMessage(address: String, reason: UnopenableLink.Reason) throws {
        let url = try #require(URL(string: address))
        #expect(ContentBlockBody.textURLRoute(for: url, workspaceId: "current") == .unopenable(reason))
    }

    @Test(arguments: [
        ("report.html", "report.html"),
        ("./report.html", "report.html"),
        (".intent/artifacts/report.html", ".intent/artifacts/report.html"),
        ("reports/Demo%20report.HTM", "reports/Demo report.HTM"),
        ("reports/report.html#summary", "reports/report.html"),
        ("reports/report.html?view=full", "reports/report.html"),
        ("/Users/me/project/report.html", "/Users/me/project/report.html"),
        ("file:///Users/me/project/report.html", "/Users/me/project/report.html"),
        ("FILE:///Users/me/project/report.html", "/Users/me/project/report.html"),
        ("file://localhost/Users/me/project/Demo%20report.html", "/Users/me/project/Demo report.html")
    ])
    func htmlPathLinksOpenRenderedPage(address: String, expectedPath: String) throws {
        let url = try #require(URL(string: address))
        #expect(ContentBlockBody.textURLRoute(for: url, workspaceId: "current") == .html(
            .init(workspaceId: "current", path: expectedPath)
        ))
    }

    @Test(arguments: [
        ("report.pdf", "report.pdf"),
        (".intent/artifacts/Review%20notes.PDF", ".intent/artifacts/Review notes.PDF"),
        ("/tmp/report.pdf", "/tmp/report.pdf"),
        ("file:///tmp/report.pdf", "/tmp/report.pdf")
    ])
    func pdfPathLinksOpenInViewer(address: String, expectedPath: String) throws {
        let url = try #require(URL(string: address))
        #expect(ContentBlockBody.textURLRoute(for: url, workspaceId: "current") == .pdf(
            .init(workspaceId: "current", path: expectedPath)
        ))
    }

    @Test(arguments: [
        ("README.md", "README.md"),
        ("docs/notes.txt", "docs/notes.txt"),
        ("./Sources/App.swift", "Sources/App.swift"),
        ("/Users/me/project/output.log", "/Users/me/project/output.log"),
        ("file:///Users/me/project/config.json", "/Users/me/project/config.json")
    ])
    func textPathLinksOpenInViewer(address: String, expectedPath: String) throws {
        let url = try #require(URL(string: address))
        #expect(ContentBlockBody.textURLRoute(for: url, workspaceId: "current") == .text(
            .init(workspaceId: "current", path: expectedPath)
        ))
    }

    @Test func chiefWorkspacePathLinkOpensInChiefWorkspace() throws {
        let url = try #require(URL(string: "reports/report.html"))
        #expect(ContentBlockBody.textURLRoute(for: url, workspaceId: Workspace.chiefWorkspaceId) == .html(
            .init(workspaceId: Workspace.chiefWorkspaceId, path: "reports/report.html")
        ))
    }
}
