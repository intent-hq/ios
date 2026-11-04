import WebKit

extension WKWebView {
    /// Runs `functionBody` as an async JavaScript function in the main frame of `contentWorld`
    /// and returns its result.
    ///
    /// Use this, never WebKit's Swift `callAsyncJavaScript(_:arguments:in:contentWorld:)`.
    /// With the iOS 18.0 deployment target, that method binds to
    /// `/usr/lib/swift/libswiftWebKit.dylib`, and the iOS 18.4–18.5 simulator runtimes cannot
    /// load it, so the app aborts before `main` (ios#905, WebKit bug 293831). This calls the
    /// Objective-C method, which lives in WebKit.framework on every supported iOS version.
    /// `scripts/check-webkit-overlay-linkage.sh` fails the build lane if the overlay comes back.
    func callJavaScript(
        _ functionBody: String,
        arguments: [String: Any],
        in contentWorld: WKContentWorld = .page
    ) async throws -> Any? {
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JavaScriptResult, any Error>) in
            __callAsyncJavaScript(functionBody, arguments: arguments, inFrame: nil, in: contentWorld) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: JavaScriptResult(value: result))
                }
            }
        }
        return result.value
    }

    /// `@unchecked Sendable`: WebKit calls the completion handler on the main thread and the
    /// awaiting caller is main-actor isolated, so the bridged value never leaves the main actor.
    nonisolated private struct JavaScriptResult: @unchecked Sendable {
        let value: Any?
    }

    /// Like ``callJavaScript(_:arguments:in:)`` in the page world, returning the result when it
    /// is a string.
    func callPageJavaScript(_ functionBody: String, arguments: [String: Any]) async throws -> String? {
        try await callJavaScript(functionBody, arguments: arguments) as? String
    }
}
