import Foundation

extension ConnectionManager {
    private static let webSocketErrorDomain = "WebSocket"
    private static let requestTimedOutErrorCode = -2
    private static let connectionClosedErrorCode = -3
    private static let notConnectedErrorCode = -4

    // MARK: - Public API

    /// Default per-request RPC timeout. Individual calls may pass a longer
    /// `timeout` to `request(_:params:timeout:)` when the daemon operation is
    /// known to outlast this bound (e.g. `workspace.create`).
    static let defaultRequestTimeout: TimeInterval = 10

    /// Sends a JSON-RPC request and awaits its response.
    ///
    /// - Parameter timeout: Per-call timeout override in seconds (defaults to
    ///   `defaultRequestTimeout`). Long-running daemon operations must pass a
    ///   bound above the daemon's own budget so the daemon's structured result
    ///   (success or error) wins over a client-side transport timeout —
    ///   mirrors the per-call `timeoutMs` override in cloudlands-fe.
    func request(
        _ method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval = ConnectionManager.defaultRequestTimeout
    ) async throws -> Any {
        if DemoMode.isEnabled {
            return DemoFixtures.response(for: method, params: params)
        }
        guard let currentSocket = socket else {
            throw NSError(
                domain: Self.webSocketErrorDomain,
                code: Self.notConnectedErrorCode,
                userInfo: [NSLocalizedDescriptionKey: "Not connected"]
            )
        }

        let id = takeNextRequestId()

        var rpcDict: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty {
            rpcDict["params"] = params
        }
        let data = try JSONSerialization.data(withJSONObject: rpcDict)
        guard let requestText = String(data: data, encoding: .utf8) else {
            throw WebSocketTransportError.failed(
                host: currentSocket.host,
                message: "JSON-RPC request was not valid UTF-8"
            )
        }

        return try await awaitResponse(id: id, timeout: timeout) { [weak self] in
            AppLog.connection.debug("[ConnectionManager] Writing request id=\(id) method=\(method), socket=\(self?.socket != nil ? "exists" : "nil")")
            return Task { [weak self] in
                do {
                    try await currentSocket.send(requestText)
                    guard !Task.isCancelled else { return }
                    AppLog.connection.debug("[ConnectionManager] Write completed for request id=\(id) method=\(method)")
                } catch {
                    guard !Task.isCancelled else { return }
                    AppLog.connection.debug("[ConnectionManager] Write failed for request id=\(id) method=\(method): \(error.localizedDescription)")
                    guard self?.socket === currentSocket else { return }
                    self?.handleDisconnection()
                }
            }
        }
    }

    /// Registers a pending continuation for `id`, performs `write`, and races
    /// the response against `timeout`. Internal for test visibility (lets tests
    /// exercise the timeout race without a live socket).
    ///
    /// The continuation is resumed exactly once by whichever side wins:
    /// whoever removes the entry from `pendingRequests` (all on MainActor)
    /// owns the resume — a response via `handleTextMessage`, a disconnect via
    /// `failAllPending`, or the timeout task below. This guarantees a
    /// never-responding daemon still produces the timeout error instead of
    /// suspending forever (a suspended CheckedContinuation does not observe
    /// task cancellation).
    func awaitResponse(
        id: Int,
        timeout: TimeInterval,
        write: @escaping @MainActor () -> Task<Void, Never>?
    ) async throws -> Any {
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, timeout)))
            guard !Task.isCancelled else { return }
            if let continuation = self?.pendingRequests.removeValue(forKey: id) {
                continuation.resume(throwing: NSError(
                    domain: Self.webSocketErrorDomain,
                    code: Self.requestTimedOutErrorCode,
                    userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
                ))
            }
        }
        var writeTask: Task<Void, Never>?
        defer {
            timeoutTask.cancel()
            writeTask?.cancel()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingRequests[id] = continuation
                writeTask = write()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if let continuation = self?.pendingRequests.removeValue(forKey: id) {
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let id = json["id"] as? Int {
            if let continuation = pendingRequests.removeValue(forKey: id) {
                if let error = json["error"] as? [String: Any] {
                    let parsedCode = error["code"] as? Int
                    let code = parsedCode ?? -1
                    let hasCode = parsedCode != nil
                    let topMessage = error["message"] as? String ?? "Unknown error"
                    let errorData = error["data"] as? [String: Any]

                    // Extract error.data.message if present (daemon stashes real cause there)
                    var effectiveMessage = topMessage
                    if let dataMessage = errorData?["message"] as? String,
                       !dataMessage.isEmpty {
                        effectiveMessage = dataMessage
                    }

                    let description = hasCode ? "\(effectiveMessage) (\(code))" : effectiveMessage
                    var userInfo: [String: Any] = [NSLocalizedDescriptionKey: description]
                    // Preserve the error.data.code discriminator (PROTOCOL §3.3) so
                    // callers can distinguish "not-found" from "invalid-params".
                    if let dataCode = errorData?["code"] as? String {
                        userInfo[NSError.intentErrorDataCodeKey] = dataCode
                    }
                    continuation.resume(throwing: NSError(
                        domain: "WebSocket",
                        code: code,
                        userInfo: userInfo
                    ))
                } else {
                    continuation.resume(returning: json["result"] as Any)
                }
            }
        } else if let method = json["method"] as? String {
            let params = json["params"] as Any
            if subscriptionRouter.route(method: method, params: params) { return }
            // Broadcast other events to all legacy eventHandlers (subscription.push is NOT broadcast)
            for handler in eventHandlers.values {
                handler(method, params)
            }
        }
    }

    func removeEventHandler(id: UUID) {
        eventHandlers.removeValue(forKey: id)
    }

    @discardableResult
    func onEvent(_ handler: @escaping (String, Any) -> Void) -> UUID {
        let id = UUID()
        eventHandlers[id] = handler
        return id
    }

    // MARK: - Subscription Push Routing

    func registerSubscriptionHandler(id: String, handler: @escaping @MainActor (SubscriptionPush) -> Void) {
        subscriptionRouter.register(id: id, handler: handler)
    }

    var subscriptionHandlerCount: Int {
        subscriptionRouter.handlerCount
    }

    func unregisterSubscriptionHandler(id: String) {
        subscriptionRouter.unregister(id: id)
    }

    func hasBufferedSubscriptionPush(for id: String) -> Bool {
        subscriptionRouter.hasBufferedPush(for: id)
    }

    func hasRecentlyUnregisteredSubscription(id: String) -> Bool {
        subscriptionRouter.hasRecentlyUnregisteredId(id)
    }

    var bufferedSubscriptionPushCount: Int {
        subscriptionRouter.bufferedPushCount
    }

    /// Internal entry point for testing message dispatch.
    @MainActor
    func dispatchMessage(_ text: String) {
        handleTextMessage(text)
    }

    nonisolated static let globalEventTypes = ["workspace:*", "note:*", "agent:*", "task:*"]
    nonisolated static let globalSubscriptionMaxAttempts = 5
    nonisolated static let globalSubscriptionBackoffMaximumSeconds = 8
    nonisolated static let globalSubscriptionBackoffMaximumExponent = 3
    nonisolated static let globalSubscriptionBackoffMaximum: Duration = .seconds(
        globalSubscriptionBackoffMaximumSeconds
    )

    nonisolated static func globalSubscriptionBackoff(afterAttempt attempt: Int) -> Duration {
        let exponent = min(
            max(attempt, 1) - 1,
            Self.globalSubscriptionBackoffMaximumExponent
        )
        let backoff: Duration = .seconds(1 << exponent)
        return min(backoff, Self.globalSubscriptionBackoffMaximum)
    }

    private func isCurrentGlobalSubscription(
        socket currentSocket: WebSocketConnection,
        generation: Int
    ) -> Bool {
        connectionGeneration == generation && socket === currentSocket
    }

    private func runGlobalSubscription(
        socket currentSocket: WebSocketConnection,
        generation: Int,
        clock: any HeartbeatClock
    ) async {
        var attempt = 1
        while true {
            guard !Task.isCancelled,
                  isCurrentGlobalSubscription(socket: currentSocket, generation: generation)
            else { return }
            do {
                _ = try await request(
                    "events.subscribe",
                    params: [
                        "eventTypes": Self.globalEventTypes,
                        "replaceGroup": "global"
                    ]
                )
                guard !Task.isCancelled,
                      isCurrentGlobalSubscription(socket: currentSocket, generation: generation)
                else { return }
                globalSubscriptionState = .subscribed
                AppLog.connection.debug("[ConnectionManager] Subscribed to all events (attempt \(attempt))")
                return
            } catch {
                guard !Task.isCancelled,
                      isCurrentGlobalSubscription(socket: currentSocket, generation: generation)
                else { return }
                if attempt >= Self.globalSubscriptionMaxAttempts {
                    globalSubscriptionState = .failed(
                        attempts: attempt,
                        lastError: error.localizedDescription
                    )
                    AppLog.connection.error("[ConnectionManager] Failed to subscribe after \(attempt) attempts: \(error)")
                    return
                }
                let backoff = Self.globalSubscriptionBackoff(afterAttempt: attempt)
                attempt += 1
                globalSubscriptionState = .subscribing(attempt: attempt)
                do {
                    try await clock.sleep(for: backoff)
                } catch {
                    return
                }
            }
        }
    }

    func subscribeToAllEvents() {
        globalSubscriptionTask?.cancel()
        guard let currentSocket = socket else {
            globalSubscriptionState = .idle
            return
        }
        let generation = connectionGeneration
        let clock = heartbeatClock
        globalSubscriptionState = .subscribing(attempt: 1)
        globalSubscriptionTask = Task { [weak self] in
            await self?.runGlobalSubscription(
                socket: currentSocket,
                generation: generation,
                clock: clock
            )
        }
    }

    func retryGlobalSubscription() {
        guard connectionState == .connected, socket != nil else { return }
        subscribeToAllEvents()
    }

    func stopGlobalSubscription() {
        globalSubscriptionTask?.cancel()
        globalSubscriptionTask = nil
        globalSubscriptionState = .idle
    }

    func failAllPending(error message: String) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: NSError(
                domain: Self.webSocketErrorDomain,
                code: Self.connectionClosedErrorCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        }
    }
}

nonisolated protocol HeartbeatClock: Sendable {
    func sleep(for duration: Duration) async throws
}

nonisolated struct ContinuousHeartbeatClock: HeartbeatClock {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}
