import WebKit

extension WKWebView {
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

    func callPageJavaScript(_ functionBody: String, arguments: [String: Any]) async throws -> String? {
        try await callJavaScript(functionBody, arguments: arguments) as? String
    }
}
