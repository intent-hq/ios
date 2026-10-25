import Foundation
@testable import Intent
import Network
import Testing
import WebKit

@MainActor
struct HTMLFileWebViewTests {
    @Test func rendersStaticMarkupWithoutScriptsOrExternalRequests() async throws {
        let server = try ImageServer()
        defer { server.stop() }
        try await waitUntil { (server.listener.port?.rawValue ?? 0) > 0 }
        let port = try #require(server.listener.port)
        let address = "http://127.0.0.1:\(port.rawValue)/pixel.png"

        // Positive control: the same WebKit runtime can reach and display this image.
        let control = try await loadUnprotectedImage(at: address, server: server)
        control.stopLoading()
        let baseline = server.requests
        let baselineConnections = server.acceptedConnections
        #expect(baseline > 0)
        print("HTML control requests", baseline, "connections", baselineConnections)

        let source = """
        <!doctype html><html><head><title>Static report</title>
        <meta http-equiv="Content-Security-Policy" content="default-src * 'unsafe-inline' data:">
        <base href="\(address)">
        <link rel="stylesheet" href="\(address)?css">
        <style>@import url('\(address)?import'); h1 { color: rgb(12, 34, 56); }</style>
        </head><body onload="document.title='Script ran'">
        <h1>Rendered report</h1><script>document.title='Script ran'</script>
        <img id="remote" src="\(address)"><img src="\(address)?srcset" srcset="\(address)?2x 2x">
        <img id="embedded" src="data:image/png;base64,\(ImageServer.pixel)">
        <div style="background-image:url('\(address)?background')">Static content</div>
        <iframe src="\(address)?frame"></iframe><object data="\(address)?object"></object>
        <script src="\(address)?script"></script><a id="link" href="\(address)">Leave</a>
        </body></html>
        """
        try await withPage(source) { webView in
            #expect(webView.configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
            #expect(!webView.configuration.websiteDataStore.isPersistent)
            #expect(!webView.allowsLinkPreview)
            #expect(try await evaluate("document.querySelector('h1').textContent", in: webView) as? String == "Rendered report")
            #expect(try await evaluate("getComputedStyle(document.querySelector('h1')).color", in: webView) as? String == "rgb(12, 34, 56)")
            #expect(try await evaluate("document.getElementById('embedded').naturalWidth", in: webView) as? Int == 1)
            #expect(try await evaluate("document.getElementById('remote').naturalWidth", in: webView) as? Int == 0)
            #expect(webView.title == "Static report")
            #expect(server.requests == baseline)

            try await checkInertLinks(in: webView, address: address, server: server, baseline: baseline)
            // WebKit may speculatively open a socket before cancelling navigation.
            // Count received HTTP bytes, not idle sockets, and allow late requests to surface.
            try await Task.sleep(for: .seconds(1))
            #expect(server.requests == baseline)
        }
    }

    @Test func metaRefreshCannotReplaceTheInitialDocument() async throws {
        try await withPage("<meta http-equiv='refresh' content='0;url=about:blank'><title>Keep this page</title><h1>Report</h1>") { webView in
            try await Task.sleep(for: .milliseconds(200))
            #expect(webView.title == "Keep this page")
            #expect(try await evaluate("document.querySelector('h1').textContent", in: webView) as? String == "Report")
        }
    }

    private func loadUnprotectedImage(at address: String, server: ImageServer) async throws -> WKWebView {
        let control = WKWebView()
        control.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        control.loadHTMLString("<img id='remote' src='\(address)'>", baseURL: nil)
        do {
            try await waitUntil { try await evaluate("document.getElementById('remote')?.naturalWidth === 1", in: control) as? Bool == true }
        } catch {
            let state = try await evaluate("JSON.stringify([document.readyState, document.getElementById('remote')?.complete, document.getElementById('remote')?.naturalWidth])", in: control)
            Issue.record("HTTP image control failed; requests: \(server.requests), document: \(String(describing: state))")
            throw error
        }
        return control
    }

    private func checkInertLinks(in webView: WKWebView, address: String, server: ImageServer, baseline: Int) async throws {
        for target in [address, "https://example.com", "file:///tmp/page.html", "about:blank", "data:text/html,Replaced", "intent://local/note/spec"] {
            _ = try await webView.callAsyncJavaScript(
                "document.getElementById('link').href = target; document.getElementById('link').click();",
                arguments: ["target": target],
                in: nil,
                contentWorld: .defaultClient
            )
            try await Task.sleep(for: .milliseconds(100))
            print("HTML target", target, "requests", server.requests, "connections", server.acceptedConnections)
            #expect(webView.url?.absoluteString == "about:blank")
            #expect(webView.title == "Static report")
            #expect(server.requests == baseline)
        }
    }

    private func withPage(_ source: String, check: (WKWebView) async throws -> Void) async throws {
        let bytes = Data(source.utf8)
        let file = try await WorkspaceTextFile.load(path: "report.html") { handle in
            try handle.write(contentsOf: bytes)
            return bytes.count
        }
        let rules = try await HTMLFileWebView.blockingRules()
        var failed = false
        let coordinator = HTMLFileWebView.Coordinator { failed = true }
        let webView = HTMLFileWebView.makeWebView(coordinator: coordinator, rules: rules)
        webView.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        defer { HTMLFileWebView.dismantleUIView(webView, coordinator: coordinator) }
        coordinator.load(file, in: webView)
        try await waitUntil {
            try await evaluate("document.readyState === 'complete' && document.querySelector('h1') !== null", in: webView) as? Bool == true
        }
        try await check(webView)
        #expect(!failed)
        #expect(try Data(contentsOf: file.url) == bytes, "Sharing preserves the original HTML without injected policy")
    }

    private func evaluate(_ expression: String, in webView: WKWebView) async throws -> Any? {
        // App-owned isolated-world inspection is allowed; page scripts remain disabled.
        try await webView.callAsyncJavaScript("return \(expression)", arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    private func waitUntil(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("WebKit did not finish the fixture within its deadline")
        throw URLError(.timedOut)
    }

    @MainActor
    private final class ImageServer {
        static let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
        let listener: NWListener
        private var connections: [NWConnection] = []
        var acceptedConnections: Int { connections.count }
        private(set) var requests = 0

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { @Sendable [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
        }

        private func accept(_ connection: NWConnection) {
            connections.append(connection)
            let image = Data(base64Encoded: Self.pixel) ?? Data()
            var reply = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(image.count)\r\nConnection: close\r\n\r\n".utf8)
            reply.append(image)
            let response = reply
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { @Sendable [weak self] data, _, _, error in
                guard let data, !data.isEmpty, error == nil else { return }
                Task { @MainActor in
                    self?.requests += 1
                    connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                }
            }
        }

        func stop() {
            listener.cancel()
            connections.forEach { $0.cancel() }
        }
    }
}
