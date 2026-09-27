import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceBrowserPageTests {
    private let browser = WorkspaceBrowser(
        id: "browser", workspaceId: "workspace", title: "Preview",
        url: "http://localhost:3000/preview", command: nil
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
}

@MainActor
private final class BrowserPageTestProxy: BrowserProxySession {
    private var continuation: CheckedContinuation<URL, Error>?
    private var requestedURL: URL?
    private(set) var closeCount = 0

    func forward(_ url: URL) async throws -> URL {
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
