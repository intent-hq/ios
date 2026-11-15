import UIKit
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

    /// Evaluates `expression` like a console entry and returns its value; `nil` for `undefined`
    /// and for values WebKit cannot bridge. Uses the Objective-C method (see above).
    func evaluateExpression(_ expression: String) async throws -> Any? {
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JavaScriptResult, any Error>) in
            evaluateJavaScript(expression) { result, error in
                if let error = error as? NSError,
                   !(error.domain == WKError.errorDomain && error.code == WKError.javaScriptResultTypeIsUnsupported.rawValue) {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: JavaScriptResult(value: result))
                }
            }
        }
        return result.value
    }

    /// Captures the visible web view. Uses the Objective-C method (see above).
    func snapshot(_ configuration: WKSnapshotConfiguration) async throws -> UIImage {
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JavaScriptResult, any Error>) in
            takeSnapshot(with: configuration) { image, error in
                if let image {
                    continuation.resume(returning: JavaScriptResult(value: image))
                } else {
                    continuation.resume(throwing: error ?? WKError(.unknown))
                }
            }
        }
        guard let image = result.value as? UIImage else { throw WKError(.unknown) }
        return image
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
