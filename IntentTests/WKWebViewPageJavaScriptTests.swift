import Foundation
@testable import Intent
import Testing
import WebKit

@MainActor
struct WKWebViewPageJavaScriptTests {
    @Test func awaitsPromisesAndPassesArguments() async throws {
        let webView = WKWebView(frame: .zero)
        let result = try await webView.callPageJavaScript(
            "return await new Promise(resolve => setTimeout(() => resolve(request.name + ':' + request.count), 10));",
            arguments: ["request": ["name": "café 👋", "count": 2]]
        )
        #expect(result == "café 👋:2")
    }

    @Test func nonStringResultsAreNil() async throws {
        let webView = WKWebView(frame: .zero)
        #expect(try await webView.callPageJavaScript("return 42;", arguments: [:]) == nil)
        #expect(try await webView.callPageJavaScript("await Promise.resolve();", arguments: [:]) == nil)
    }

    @Test func callJavaScriptReturnsNonStringValues() async throws {
        let webView = WKWebView(frame: .zero)
        #expect(try await webView.callJavaScript("return 40 + 2;", arguments: [:]) as? Int == 42)
        #expect(try await webView.callJavaScript("return flag;", arguments: ["flag": true]) as? Bool == true)
        #expect(try await webView.callJavaScript("await Promise.resolve();", arguments: [:]) == nil)
    }

    @Test func callJavaScriptRunsInTheRequestedContentWorld() async throws {
        let webView = WKWebView(frame: .zero)
        _ = try await webView.callJavaScript("window.intentWorldProbe = 'client';", arguments: [:], in: .defaultClient)
        let fromClient = try await webView.callJavaScript("return window.intentWorldProbe;", arguments: [:], in: .defaultClient)
        let fromPage = try await webView.callJavaScript("return window.intentWorldProbe ?? 'unset';", arguments: [:])
        #expect(fromClient as? String == "client")
        #expect(fromPage as? String == "unset")
    }

    @Test func javaScriptExceptionsThrow() async {
        let webView = WKWebView(frame: .zero)
        await #expect(throws: (any Error).self) {
            _ = try await webView.callPageJavaScript("throw new Error('boom');", arguments: [:])
        }
    }

    @Test func runsInThePageWorld() async throws {
        let webView = WKWebView(frame: .zero)
        _ = try await webView.callPageJavaScript("window.intentWorldProbe = 'page';", arguments: [:])
        // evaluateJavaScript(_:completionHandler:) always runs in the page world.
        let fromPage = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("window.intentWorldProbe") { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
        #expect(fromPage == "page")
    }
}
