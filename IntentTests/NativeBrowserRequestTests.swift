@testable import Intent
import SwiftUI
import Testing
import WebKit

@MainActor
@Suite(.serialized)
struct NativeBrowserRequestTests {
    @Test func repeatedExplicitNavigationReachesThePresentedPageAfterInPageNavigation() async throws {
        let connection = FakeConnectionManager()
        connection.connectionState = .connected
        connection.responseMap["workspace.list"] = ["workspaces": [["id": "workspace"]]]
        connection.responseMap["browser.syncTabs"] = ["drop": [String]()]
        let proxy = RecordingProxy()
        connection.browserProxyFactory = { proxy }
        let navigation = NativeBrowserNavigation(connection: connection)
        let windowID = UUID()
        navigation.setWindow(windowID, active: true)
        let address = "http://127.0.0.1:3000/a"
        let opened = await navigation.execute([
            "workspaceId": "workspace", "agentId": "owner", "actions": [["action": "openTab", "url": address]]
        ])
        #expect(opened["success"] as? Bool == true)
        let tabID = try #require(navigation.tabs.first?.id)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Host(navigation: navigation, windowID: windowID, connection: connection))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKey()
        }
        try await waitUntil("native page attached") { Self.webView(in: window) != nil }
        let webView = try #require(Self.webView(in: window))
        let page = try #require(webView.navigationDelegate as? WorkspaceBrowserPage)
        defer { page.stop() }
        try await page.navigate(to: "http://127.0.0.1:3000/b")
        try await waitUntil("in-page destination reported") { navigation.tabs.first?.url == "http://127.0.0.1:3000/b" }
        #expect(navigation.presentation(window: windowID)?.url == address)
        for _ in 0..<2 {
            let previousCount = proxy.addresses.count
            let reply = await navigation.execute([
                "workspaceId": "workspace", "agentId": "owner",
                "actions": [["action": "navigate", "tabId": tabID, "url": address]]
            ])
            #expect(reply["success"] as? Bool == true)
            try await waitUntil("explicit repeated destination reaches page") {
                proxy.addresses.count > previousCount && page.address == address
            }
            #expect(proxy.addresses.last == address)
            #expect(page.webView === webView)
            #expect(navigation.tabs.first?.id == tabID)
        }
    }

    private struct Host: View {
        let navigation: NativeBrowserNavigation
        let windowID: UUID
        let connection: FakeConnectionManager

        var body: some View {
            if let browser = navigation.presentation(window: windowID) {
                WorkspaceBrowserView(browser: browser, connection: connection, onClose: nil) { url, title in
                    navigation.pageChanged(browser.id, url: url, title: title)
                }
                .environment(\.scenePhase, .active)
            }
        }
    }

    private static func webView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        return view.subviews.lazy.compactMap { webView(in: $0) }.first
    }

    private final class RecordingProxy: BrowserProxySession {
        var addresses: [String] = []

        func forward(_ url: URL) throws -> URL {
            addresses.append(url.absoluteString)
            return try #require(URL(string: "about:blank"))
        }

        func close() {}
    }
}
