import Foundation
@testable import Intent
import Testing
import WebKit

@MainActor
struct WorkspaceBrowserPageTests {
    private let browser = WorkspaceBrowser(
        id: "browser",
        workspaceId: "workspace",
        title: "Preview",
        url: "http://localhost:3000/preview",
        command: nil
    )

    @Test func aFailedConnectionShowsAnErrorAndNoWebView() async {
        let page = WorkspaceBrowserPage()
        let connection = FakeConnectionManager()
        await page.open(browser, connection: connection)
        #expect(page.webView == nil)
        #expect(!page.isLoading)
        #expect(page.errorMessage != nil)
        page.stop()
        #expect(page.errorMessage == nil)
    }

    @Test func dismissingDuringForwardingClosesProxyAndRejectsLatePage() async throws {
        let page = WorkspaceBrowserPage()
        let connection = FakeConnectionManager()
        let proxy = BrowserPageTestProxy()
        connection.browserProxyFactory = { proxy }
        let opening = Task { await page.open(browser, connection: connection) }
        try await proxy.waitUntilForwarding()
        page.stop()
        try await proxy.waitUntilClosed()
        proxy.finishForwarding()
        await opening.value
        #expect(page.webView == nil)
        #expect(!page.isLoading)
        #expect(page.errorMessage == nil)
        #expect(proxy.closeCount == 1)
    }

    @Test func anOldAttemptCannotReplaceTheNewAttemptsError() async throws {
        let page = WorkspaceBrowserPage()
        let connection = FakeConnectionManager()
        let proxy = BrowserPageTestProxy()
        connection.browserProxyFactory = { proxy }
        let first = Task { await page.open(browser, connection: connection) }
        try await proxy.waitUntilForwarding()
        connection.browserProxyFactory = nil
        await page.open(browser, connection: connection)
        let error = page.errorMessage
        try await proxy.waitUntilClosed()
        proxy.finishForwarding()
        await first.value
        #expect(page.webView == nil)
        #expect(page.errorMessage == error)
        #expect(error != nil)
    }

    @Test func typedNavigationReusesTheWebViewAndRetainsTheRequestedAddress() async throws {
        let page = WorkspaceBrowserPage()
        let proxy = BrowserPageTestProxy()
        proxy.resolvesImmediately = true
        let connection = FakeConnectionManager()
        connection.browserProxyFactory = { proxy }
        await page.open(browser, connection: connection)
        let webView = try #require(page.webView)
        try await page.navigate(to: "daemon.localhost:4321/settings?view=phone#details")
        #expect(page.webView === webView)
        #expect(page.address == "http://127.0.0.1:4321/settings?view=phone#details")
        #expect(proxy.closeCount == 0)
        await #expect(throws: WorkspaceBrowserError.self) { try await page.navigate(to: "file:///tmp") }
        #expect(page.webView === webView)
        page.stop()
    }

    @Test func loadedPageTitleUpdatesTheBrowserChromeAndClearsOnClose() async throws {
        let page = WorkspaceBrowserPage()
        let proxy = BrowserPageTestProxy()
        proxy.resolvesImmediately = true
        let connection = FakeConnectionManager()
        connection.browserProxyFactory = { proxy }
        await page.open(browser, connection: connection)
        let webView = try #require(page.webView)
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.loadHTMLString("<html><head><title>Server preview</title></head><body>Ready</body></html>", baseURL: nil)
        try await waitUntil("page title reaches browser chrome", timeout: .seconds(10)) { page.title == "Server preview" }
        webView.loadHTMLString("<html><head><title>Settings</title></head><body>Updated</body></html>", baseURL: nil)
        try await waitUntil("browser title follows navigation", timeout: .seconds(10)) { page.title == "Settings" }
        page.stop()
        #expect(page.title.isEmpty)
    }

    @Test func closingDuringTypedNavigationRejectsLateResults() async throws {
        let page = WorkspaceBrowserPage()
        let proxy = BrowserPageTestProxy()
        proxy.resolvesImmediately = true
        let connection = FakeConnectionManager()
        connection.browserProxyFactory = { proxy }
        await page.open(browser, connection: connection)
        proxy.resolvesImmediately = false
        let navigation = Task { try await page.navigate(to: "localhost:4321/settings") }
        try await proxy.waitUntilForwarding()
        page.stop()
        proxy.finishForwarding()
        try await navigation.value
        #expect(page.webView == nil)
        #expect(page.address.isEmpty)
        #expect(!page.isLoading)
    }
}

@MainActor
struct WorkspaceBrowserLinkTests {
    @Test(arguments: ["localhost", "LOCALHOST", "daemon.localhost", "127.0.0.1", "0.0.0.0", "[::]", "[::1]"])
    func localWebLinksUseTheBrowserAndKeepTheirAddress(host: String) throws {
        let fixture = try WorkspaceBrowserFixture()
        let url = try #require(URL(string: "http://\(host):5173/preview?view=phone#details"))
        let opened = try MarkdownTextView.workspaceBrowser(for: url, workspaceId: "workspace", store: fixture.store)
        let browser = try #require(opened)
        #expect(browser.url == "http://127.0.0.1:5173/preview?view=phone#details")
        #expect(fixture.store.browsers(workspaceId: "workspace") == [browser])
        #expect(try MarkdownTextView.workspaceBrowser(for: url, workspaceId: "workspace", store: fixture.store) == browser)
        #expect(fixture.store.browsers(workspaceId: "workspace").count == 1)
    }

    @Test func secureLocalWebLinksUseTheBrowserWithoutAnExplicitPort() throws {
        let fixture = try WorkspaceBrowserFixture()
        let url = try #require(URL(string: "https://LOCALHOST/preview"))
        let opened = try MarkdownTextView.workspaceBrowser(for: url, workspaceId: "workspace", store: fixture.store)
        #expect(try #require(opened).url == "https://127.0.0.1/preview")
    }

    @Test(arguments: [
        "https://github.com/intent-hq/ios/pull/123",
        "http://example.com:5173/preview",
        "https://localhost.example.com/preview",
        "https://daemon.localhost.example.com/preview",
        "https://127.0.0.1.example.com/preview",
        "https://localhost@github.com/intent-hq/ios",
        "https://example.com/localhost?next=http://127.0.0.1:5173#daemon.localhost"
    ])
    func externalWebLinksKeepSystemRoutingWithoutSavingABrowser(address: String) throws {
        let fixture = try WorkspaceBrowserFixture()
        let url = try #require(URL(string: address))
        #expect(try MarkdownTextView.workspaceBrowser(for: url, workspaceId: "workspace", store: fixture.store) == nil)
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
    }

    @Test func savedExternalBrowserDoesNotInterceptExternalLinks() throws {
        let fixture = try WorkspaceBrowserFixture()
        let saved = try fixture.store.create(workspaceId: "workspace", url: "https://github.com/intent-hq/ios")
        let url = try #require(URL(string: saved.url))
        #expect(try MarkdownTextView.workspaceBrowser(for: url, workspaceId: "workspace", store: fixture.store) == nil)
        #expect(fixture.store.browsers(workspaceId: "workspace") == [saved])
    }

    @Test func nonWebLinksAndMissingContextKeepTheirExistingRouting() throws {
        let fixture = try WorkspaceBrowserFixture()
        for address in ["intent://local/note/spec", "intent://local/file/report.pdf", "mailto:hello@example.com", "file:///tmp/file"] {
            let url = try #require(URL(string: address))
            #expect(try MarkdownTextView.workspaceBrowser(for: url, workspaceId: "workspace", store: fixture.store) == nil)
        }
        let url = try #require(URL(string: "http://localhost:5173"))
        #expect(try MarkdownTextView.workspaceBrowser(for: url, workspaceId: nil, store: fixture.store) == nil)
        #expect(try MarkdownTextView.workspaceBrowser(for: url, workspaceId: "", store: fixture.store) == nil)
        #expect(try MarkdownTextView.workspaceBrowser(for: url, workspaceId: "workspace", store: nil) == nil)
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
    }

    @Test func credentialedWebLinksAreRejected() throws {
        let fixture = try WorkspaceBrowserFixture()
        let url = try #require(URL(string: "https://user:password@localhost:3000"))
        #expect(throws: WorkspaceBrowserError.self) {
            try MarkdownTextView.workspaceBrowser(for: url, workspaceId: "workspace", store: fixture.store)
        }
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
    }
}

@MainActor
private final class BrowserPageTestProxy: BrowserProxySession {
    var resolvesImmediately = false
    private var continuation: CheckedContinuation<URL, Error>?
    private var requestedURL: URL?
    private(set) var closeCount = 0

    func forward(_ url: URL) async throws -> URL {
        if resolvesImmediately { return url }
        requestedURL = url
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func close() async {
        closeCount += 1
    }

    func waitUntilForwarding() async throws {
        try await waitUntil("browser forwarding started") { continuation != nil }
    }

    func waitUntilClosed() async throws {
        try await waitUntil("browser proxy closed") { closeCount > 0 }
    }

    func finishForwarding() {
        if let requestedURL { continuation?.resume(returning: requestedURL) }
        continuation = nil
    }
}
