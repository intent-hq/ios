import CryptoKit
import Foundation
import os

nonisolated enum WebSocketTransportError: LocalizedError, Sendable {
    case invalidURL(host: String)
    case timedOut(host: String)
    case failed(host: String, message: String)
    case disconnected(host: String, code: Int, reason: String)
    case certificateMismatch(host: String, fingerprint: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let host):
            "Invalid WebSocket URL for \(host)"
        case .timedOut(let host):
            "Connection to \(host) timed out"
        case .failed(let host, let message):
            "Connection to \(host) failed: \(message)"
        case .disconnected(let host, let code, let reason):
            "Disconnected from \(host) (\(code)): \(reason)"
        case .certificateMismatch(let host, let fingerprint):
            "Certificate fingerprint mismatch for \(host). Received: \(fingerprint)"
        }
    }

    var isCertificateMismatch: Bool {
        if case .certificateMismatch = self { return true }
        return false
    }
}

actor WebSocketConnection {
    nonisolated let host: String

    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let didOpen: OSAllocatedUnfairLock<Bool>

    private init(
        host: String,
        session: URLSession,
        task: URLSessionWebSocketTask,
        didOpen: OSAllocatedUnfairLock<Bool>
    ) {
        self.host = host
        self.session = session
        self.task = task
        self.didOpen = didOpen
    }

    deinit {
        if didOpen.withLock({ $0 }) {
            task.cancel(with: .goingAway, reason: nil)
        } else {
            task.cancel()
        }
        session.invalidateAndCancel()
    }

    nonisolated static func makeRequest(
        host: String,
        port: Int,
        token: String,
        certFingerprint: String?
    ) throws -> URLRequest {
        let scheme = certFingerprint == nil ? "ws" : "wss"
        guard let url = URL(string: "\(scheme)://\(host):\(port)/ws") else {
            throw WebSocketTransportError.invalidURL(host: host)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    nonisolated static func connect(
        host: String,
        port: Int,
        token: String,
        certFingerprint: String?
    ) async throws -> WebSocketConnection {
        let request = try makeRequest(
            host: host,
            port: port,
            token: token,
            certFingerprint: certFingerprint)
        let mismatchFingerprint = OSAllocatedUnfairLock<String?>(initialState: nil)
        let didOpen = OSAllocatedUnfairLock(initialState: false)
        let (lifecycleEvents, lifecycleContinuation) = AsyncThrowingStream<Void, Error>.makeStream()
        let delegate = WebSocketSessionDelegate(
            host: host,
            pinnedFingerprint: certFingerprint,
            mismatchFingerprint: mismatchFingerprint,
            didOpen: didOpen,
            lifecycleContinuation: lifecycleContinuation)
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        let connection = WebSocketConnection(
            host: host, session: session, task: task, didOpen: didOpen)

        do {
            try await withTaskCancellationHandler {
                task.resume()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await _ in lifecycleEvents { return }
                        throw WebSocketTransportError.failed(
                            host: host, message: "Handshake ended before the socket opened")
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(4))
                        throw WebSocketTransportError.timedOut(host: host)
                    }
                    do {
                        guard let _ = try await group.next() else {
                            throw WebSocketTransportError.failed(
                                host: host, message: "Handshake produced no result")
                        }
                        group.cancelAll()
                    } catch {
                        group.cancelAll()
                        throw error
                    }
                }
            } onCancel: {
                if didOpen.withLock({ $0 }) {
                    task.cancel(with: .goingAway, reason: nil)
                } else {
                    task.cancel()
                }
                session.invalidateAndCancel()
            }
            try Task.checkCancellation()
            return connection
        } catch {
            if didOpen.withLock({ $0 }) {
                task.cancel(with: .goingAway, reason: nil)
            } else {
                task.cancel()
            }
            session.invalidateAndCancel()
            if let fingerprint = mismatchFingerprint.withLock({ $0 }) {
                throw WebSocketTransportError.certificateMismatch(
                    host: host, fingerprint: fingerprint)
            }
            if let transportError = error as? WebSocketTransportError {
                throw transportError
            }
            if error is CancellationError {
                throw error
            }
            throw WebSocketTransportError.failed(host: host, message: error.localizedDescription)
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        let task = task
        return try await withTaskCancellationHandler {
            do {
                return try await task.receive()
            } catch {
                let closeCode = task.closeCode
                if closeCode != .invalid {
                    let reason = task.closeReason
                        .flatMap { String(data: $0, encoding: .utf8) }
                        ?? "Connection closed"
                    throw WebSocketTransportError.disconnected(
                        host: host, code: closeCode.rawValue, reason: reason)
                }
                throw error
            }
        } onCancel: {
            task.cancel(with: .normalClosure, reason: nil)
        }
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func sendPing() async throws {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<Void, Error>?>(initialState: nil)
        let timeoutTask = Task { [host] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            let continuation = pending.withLock { state in
                defer { state = nil }
                return state
            }
            continuation?.resume(throwing: WebSocketTransportError.timedOut(host: host))
        }
        defer { timeoutTask.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let installed = pending.withLock { state in
                    guard !Task.isCancelled else { return false }
                    state = continuation
                    return true
                }
                guard installed else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                task.sendPing { error in
                    let continuation = pending.withLock { state in
                        defer { state = nil }
                        return state
                    }
                    if let error {
                        continuation?.resume(throwing: error)
                    } else {
                        continuation?.resume(returning: ())
                    }
                }
            }
        } onCancel: {
            let continuation = pending.withLock { state in
                defer { state = nil }
                return state
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func disconnect() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}

private nonisolated final class WebSocketSessionDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    private let host: String
    private let pinnedFingerprint: String?
    private let mismatchFingerprint: OSAllocatedUnfairLock<String?>
    private let didOpen: OSAllocatedUnfairLock<Bool>
    private let lifecycleContinuation: AsyncThrowingStream<Void, Error>.Continuation

    init(
        host: String,
        pinnedFingerprint: String?,
        mismatchFingerprint: OSAllocatedUnfairLock<String?>,
        didOpen: OSAllocatedUnfairLock<Bool>,
        lifecycleContinuation: AsyncThrowingStream<Void, Error>.Continuation
    ) {
        self.host = host
        self.pinnedFingerprint = pinnedFingerprint
        self.mismatchFingerprint = mismatchFingerprint
        self.didOpen = didOpen
        self.lifecycleContinuation = lifecycleContinuation
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        didOpen.withLock { $0 = true }
        lifecycleContinuation.yield()
        lifecycleContinuation.finish()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "Connection closed"
        lifecycleContinuation.finish(throwing: WebSocketTransportError.disconnected(
            host: host, code: closeCode.rawValue, reason: reasonText))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            lifecycleContinuation.finish(throwing: error)
        } else {
            lifecycleContinuation.finish(throwing: WebSocketTransportError.failed(
                host: host, message: "Connection ended before opening"))
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let pinnedFingerprint else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              SecTrustGetCertificateCount(serverTrust) > 0,
              let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let serverCert = certChain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let certData = SecCertificateCopyData(serverCert) as Data
        let fingerprint = SHA256.hash(data: certData)
            .map { String(format: "%02x", $0) }
            .joined(separator: ":")

        if fingerprint.lowercased() == pinnedFingerprint.lowercased() {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            AppLog.connection.error("[CertPinning] Fingerprint mismatch!")
            AppLog.connection.error("[CertPinning] Expected: \(pinnedFingerprint)")
            AppLog.connection.error("[CertPinning] Got:      \(fingerprint)")
            mismatchFingerprint.withLock { $0 = fingerprint }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
