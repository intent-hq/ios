import WebKit

extension WKWebView {
    /// Runs `functionBody` as an async JavaScript function in the main frame's page world and
    /// returns its result when that is a string.
    ///
    /// Use this, never WebKit's Swift `callAsyncJavaScript(_:arguments:in:contentWorld:)`.
    /// With the iOS 18.0 deployment target, that method binds to
    /// `/usr/lib/swift/libswiftWebKit.dylib`, and the iOS 18.4–18.5 simulator runtimes cannot
    /// load it, so the app aborts before `main` (ios#905, WebKit bug 293831). This calls the
    /// Objective-C method, which lives in WebKit.framework on every supported iOS version.
    /// `scripts/check-webkit-overlay-linkage.sh` fails the build lane if the overlay comes back.
    func callPageJavaScript(_ functionBody: String, arguments: [String: Any]) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            __callAsyncJavaScript(functionBody, arguments: arguments, inFrame: nil, in: .page) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result as? String)
                }
            }
        }
    }
}
