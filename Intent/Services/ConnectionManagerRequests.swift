import Foundation

extension ConnectionManager {
    nonisolated private static let webSocketErrorDomain = "WebSocket"
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
    /// Preserves the request flow while classifying each local boundary.
    func request(
        _ method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval = ConnectionManager.defaultRequestTimeout
    ) async throws -> Any {
        #if DEBUG
        if DemoMode.isEnabled || servesDemoFixtures { return try await demoResponse(for: method, params: params) }
        #endif
        guard let currentSocket = socket else {
            let error = Self.localRequestError(
                code: Self.notConnectedErrorCode,
                message: "Not connected",
                classification: .notConnected
            )
            recordRequestFailure(error)
            throw error
        }

        let id = takeNextRequestId()

        var rpcDict: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty {
            rpcDict["params"] = params
        }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: rpcDict)
        } catch {
            let owned = DiagnosticErrorOwnership.attaching(
                to: error as NSError,
                failure: DiagnosticFailure(origin: .localRequest, classification: .encodingFailed)
            )
            recordRequestFailure(owned)
            throw owned
        }
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
                    self?.handleDisconnection(cause: .socketFailure, failure: TransportDiagnosticFailure.classify(error))
                }
            }
        }
    }

    private static func localRequestError(
        code: Int,
        message: String,
        classification: DiagnosticFailure.Classification,
        suppressed: Bool = false
    ) -> NSError {
        DiagnosticErrorOwnership.attaching(
            to: NSError(
                domain: webSocketErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: message]
            ),
            failure: DiagnosticFailure(origin: .localRequest, classification: classification),
            suppressed: suppressed
        )
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
                continuation.resume(throwing: Self.localRequestError(
                    code: Self.requestTimedOutErrorCode,
                    message: "Request timed out",
                    classification: .requestTimeout
                ))
            }
        }
        var writeTask: Task<Void, Never>?
        defer {
            timeoutTask.cancel()
            writeTask?.cancel()
        }
        do {
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
        } catch {
            recordRequestFailure(error)
            throw error
        }
    }

    func recordRequestFailure(_ error: any Error) {
        let owner = DiagnosticRequestContext.owner ?? .init(operation: .otherRequest, site: .connectionManager)
        guard owner.recording == .immediate, !Task.isCancelled else { return }
        let failure = DiagnosticErrorOwnership.failure(for: error)
        DiagnosticErrorOwnership.record(
            error,
            event: DiagnosticEvent(
                kind: owner.kind,
                operation: owner.operation,
                site: owner.site,
                stage: .request,
                outcome: owner.outcome,
                failure: failure,
                effect: Self.requestFailureEffect(for: failure)
            ),
            store: diagnostics
        )
    }

    nonisolated private static func requestFailureEffect(for failure: DiagnosticFailure) -> DiagnosticEvent.Effect {
        if failure.origin == .remoteRPC { return .remoteRejected }
        if failure.classification == .notConnected || failure.classification == .encodingFailed { return .notSent }
        return .unknown
    }

    nonisolated static func parseInboundFrame(_ text: String) -> InboundFrame? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let id = json["id"] as? Int {
            guard let error = json["error"] as? [String: Any] else {
                return .response(id: id, result: InboundJSONValue(value: json["result"] as Any))
            }
            let parsedCode = error["code"] as? Int
            let code = parsedCode ?? -1
            let topMessage = error["message"] as? String ?? "Unknown error"
            let errorData = error["data"] as? [String: Any]
            let dataMessage = (error["data"] as? String) ?? (errorData?["message"] as? String)
            let effectiveMessage = dataMessage.flatMap { $0.isEmpty ? nil : $0 } ?? topMessage
            let description = parsedCode == nil ? effectiveMessage : "\(effectiveMessage) (\(code))"
            var userInfo: [String: Any] = [NSLocalizedDescriptionKey: description]
            if let dataCode = errorData?["code"] as? String {
                userInfo[NSError.intentErrorDataCodeKey] = dataCode
            }
            return .error(
                id: id,
                error: DiagnosticErrorOwnership.attaching(
                    to: NSError(domain: Self.webSocketErrorDomain, code: code, userInfo: userInfo),
                    failure: .remoteRPC(code: code)
                )
            )
        }
        if let method = json["method"] as? String {
            let params = json["params"] as Any
            if let push = SubscriptionPush.parse(method: method, params: params) {
                return .subscriptionPush(push)
            }
            return .notification(method: method, params: InboundJSONValue(value: params))
        }
        return nil
    }

    func handleTextMessage(_ text: String) {
        let parseStart = CFAbsoluteTimeGetCurrent()
        guard let frame = Self.parseInboundFrame(text) else {
            recordMalformedFrame()
            return
        }
        let parseElapsed = CFAbsoluteTimeGetCurrent() - parseStart
        dispatchInboundFrame(
            frame,
            byteCount: text.utf8.count,
            parseElapsed: parseElapsed,
            waitElapsed: 0
        )
    }

    func dispatchInboundFrame(
        _ frame: InboundFrame,
        byteCount: Int,
        parseElapsed: TimeInterval,
        waitElapsed: TimeInterval
    ) {
        let dispatchStart = CFAbsoluteTimeGetCurrent()
        switch frame {
        case let .response(id, result):
            pendingRequests.removeValue(forKey: id)?.resume(returning: result.value)
        case let .error(id, error):
            pendingRequests.removeValue(forKey: id)?.resume(throwing: error)
        case .subscriptionPush(let push):
            subscriptionRouter.route(push)
        case let .notification(method, params):
            invalidatePrincipalIfNeeded(method: method, params: params.value)
            if !subscriptionRouter.route(method: method, params: params.value) {
                for handler in eventHandlers.values {
                    handler(method, params.value)
                }
            }
        }
        let dispatchElapsed = CFAbsoluteTimeGetCurrent() - dispatchStart
        if let line = Self.slowFrameLogLine(
            label: frame.label,
            byteCount: byteCount,
            parseElapsed: parseElapsed,
            waitElapsed: waitElapsed,
            dispatchElapsed: dispatchElapsed,
            threshold: Constants.Connection.slowFrameLogThreshold
        ) {
            AppLog.connection.info("\(line)")
        }
    }

    // Keep each frame metric and the reporting threshold explicit in this pure log formatter.
    // swiftlint:disable:next function_parameter_count
    nonisolated static func slowFrameLogLine(
        label: String,
        byteCount: Int,
        parseElapsed: TimeInterval,
        waitElapsed: TimeInterval,
        dispatchElapsed: TimeInterval,
        threshold: TimeInterval
    ) -> String? {
        guard parseElapsed > threshold || waitElapsed > threshold || dispatchElapsed > threshold else {
            return nil
        }
        return "[ConnectionManager] slow frame \(label) bytes=\(byteCount) "
            + "parse=\(Int(parseElapsed * millisecondsPerSecond))ms "
            + "wait=\(Int(waitElapsed * millisecondsPerSecond))ms "
            + "dispatch=\(Int(dispatchElapsed * millisecondsPerSecond))ms"
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

    nonisolated static let globalEventTypes = [
        "workspace:*", "note:*", "agent:*", "task:*", "specialists:changed", "settings:changed", "host:members-changed"
    ]
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

    // Keep retry ordering unchanged; owner context is scoped to each request.
    // swiftlint:disable:next function_body_length
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
                let owner = DiagnosticRequestContext.Owner(
                    operation: .subscriptionGlobal,
                    site: .connectionManager,
                    outcome: attempt >= Self.globalSubscriptionMaxAttempts ? .exhausted : .retrying,
                    kind: .subscriptionRecovery
                )
                _ = try await DiagnosticRequestContext.$owner.withValue(owner) {
                    try await request(
                        "events.subscribe",
                        params: [
                            "eventTypes": Self.globalEventTypes,
                            "replaceGroup": "global"
                        ]
                    )
                }
                guard !Task.isCancelled,
                      isCurrentGlobalSubscription(socket: currentSocket, generation: generation)
                else { return }
                globalSubscriptionState = .subscribed
                diagnostics.record(DiagnosticEvent(
                    kind: .subscriptionRecovery,
                    operation: .subscriptionGlobal,
                    site: .connectionManager,
                    stage: .response,
                    outcome: attempt == 1 ? .succeeded : .recovered
                ))
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
            continuation.resume(throwing: Self.localRequestError(
                code: Self.connectionClosedErrorCode,
                message: message,
                classification: .connectionClosed,
                suppressed: true
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
