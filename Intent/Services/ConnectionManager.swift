import Combine
import CryptoKit
import Foundation
import Starscream

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
}

// MARK: - ConnectionManagerRouting

/// The subset of ConnectionManager surface that subscribe-channel stores depend on.
/// Exists to allow tests to inject a fake; ConnectionManager conforms as-is.
@MainActor
protocol ConnectionManagerRouting: AnyObject {
    var connectionState: ConnectionState { get }
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> { get }
    func request(_ method: String, params: [String: Any], timeout: TimeInterval) async throws -> Any
    @discardableResult func onEvent(_ handler: @escaping (String, Any) -> Void) -> UUID
    func removeEventHandler(id: UUID)
    func registerSubscriptionHandler(id: String, handler: @escaping @MainActor (SubscriptionPush) -> Void)
    func unregisterSubscriptionHandler(id: String)
}

extension ConnectionManagerRouting {
    /// Convenience for calling request without params. Preserves existing call sites.
    func request(_ method: String) async throws -> Any {
        return try await request(method, params: [:], timeout: ConnectionManager.defaultRequestTimeout)
    }

    /// Convenience for calling request without a timeout override. Preserves existing call sites.
    func request(_ method: String, params: [String: Any]) async throws -> Any {
        return try await request(method, params: params, timeout: ConnectionManager.defaultRequestTimeout)
    }
}

@MainActor
class ConnectionManager: ObservableObject {
    static let shared = ConnectionManager()

    @Published var connectionState: ConnectionState = .disconnected
    @Published var certMismatchDetected = false

    private var socket: WebSocket?
    var pendingRequests: [Int: CheckedContinuation<Any, Error>] = [:]
    private var nextRequestId = 1
    private var connectionGeneration: Int = 0
    private var reconnectTask: Task<Void, Never>?
    private var pingTimer: Timer?
    private var lastPongReceived: Date = Date()
    private static let pingInterval: TimeInterval = 15  // Send ping every 15s
    private static let pongTimeout: TimeInterval = 30   // Dead if no pong in 30s
    private var hosts: [String] = []
    private var host: String?
    private var port: Int?
    private var token: String?
    private var certFingerprint: String?
    var eventHandlers: [UUID: (String, Any) -> Void] = [:]

    // MARK: - Subscription Push Routing

    /// Registry of per-subscriptionId handlers for subscription.push dispatch.
    /// Each store registers its handler after capturing its subscriptionId from the
    /// subscribe RPC response. This eliminates the need for stores to filter pushes
    /// themselves and ensures single-source-of-truth routing.
    private var subscriptionHandlers: [String: @MainActor (SubscriptionPush) -> Void] = [:]

    /// A subscription.push that arrived before any handler was registered for its
    /// subscriptionId (e.g. the seq-0 snapshot racing the store's handler registration,
    /// which runs one or more actor hops after the subscribe response continuation resumes).
    struct BufferedPush {
        let push: SubscriptionPush
        let receivedAt: Date
    }

    /// Unrouted pushes buffered in arrival order, replayed when a handler is registered
    /// for their subscriptionId. Bounded: at most `unroutedPushBufferLimit` frames total
    /// (oldest evicted first) and each frame held at most `unroutedPushBufferTTL` seconds.
    /// Internal for test visibility.
    var unroutedPushBuffer: [BufferedPush] = []
    static let unroutedPushBufferLimit = 64
    static let unroutedPushBufferTTL: TimeInterval = 30

    /// SubscriptionIds recently unregistered, mapped to when. Unrouted pushes for these
    /// ids are dropped instead of buffered — they belong to a dead subscription that will
    /// never be re-registered (server ids are unique per subscribe), so buffering them
    /// would only add eviction pressure on the shared buffer. Entries expire after
    /// `unroutedPushBufferTTL`. Internal for test visibility.
    var recentlyUnregisteredIds: [String: Date] = [:]

    private init() {}

    /// Publisher for connectionState changes. Satisfies ConnectionManagerRouting protocol.
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        $connectionState.eraseToAnyPublisher()
    }

    // MARK: - Connection lifecycle

    func connect(hosts: [String], port: Int, token: String, certFingerprint: String? = nil) async throws {
        let connectStart = CFAbsoluteTimeGetCurrent()
        disconnect()
        connectionGeneration += 1
        let myGeneration = connectionGeneration
        self.hosts = hosts
        self.port = port
        self.token = token
        self.certFingerprint = certFingerprint
        connectionState = .connecting

        let raceStart = CFAbsoluteTimeGetCurrent()
        print("[ConnectionManager] Connect: raceHosts starting at +\(Int((raceStart - connectStart) * 1000))ms")

        let winningSocket = try await raceHosts(hosts, port: port, token: token, certFingerprint: certFingerprint)

        let raceEnd = CFAbsoluteTimeGetCurrent()
        print("[ConnectionManager] Connect: raceHosts completed in \(Int((raceEnd - raceStart) * 1000))ms (at +\(Int((raceEnd - connectStart) * 1000))ms)")
        print("[ConnectionManager] Race won by \(winningSocket.request.url?.host ?? "?"), generation=\(myGeneration)")

        // Check if we've been superseded by a newer connect() call
        guard connectionGeneration == myGeneration else {
            print("[ConnectionManager] Generation mismatch after race: current=\(connectionGeneration), mine=\(myGeneration)")
            winningSocket.disconnect(closeCode: CloseCode.normal.rawValue)
            throw CancellationError()
        }

        self.socket = winningSocket
        self.host = winningSocket.request.url?.host
        configureSocketEventHandler()

        let setupEnd = CFAbsoluteTimeGetCurrent()
        print("[ConnectionManager] Connect: socket setup completed in \(Int((setupEnd - raceEnd) * 1000))ms (at +\(Int((setupEnd - connectStart) * 1000))ms)")

        connectionState = .connected
        subscribeToAllEvents()
        startPingTimer()
        scheduleHostRoutesRefresh()

        let totalElapsed = CFAbsoluteTimeGetCurrent() - connectStart
        print("[ConnectionManager] Connect: total elapsed \(Int(totalElapsed * 1000))ms, connected to \(self.host ?? "?")")
    }

    func disconnect() {
        stopPingTimer()
        reconnectTask?.cancel()
        reconnectTask = nil
        socket?.disconnect(closeCode: CloseCode.normal.rawValue)
        socket = nil
        connectionState = .disconnected
        failAllPending(error: "Connection closed")
    }

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
    func request(_ method: String, params: [String: Any] = [:],
                 timeout: TimeInterval = ConnectionManager.defaultRequestTimeout) async throws -> Any {
        guard socket != nil else {
            throw NSError(domain: "WebSocket", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }

        let id = nextRequestId
        nextRequestId += 1

        var rpcDict: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty {
            rpcDict["params"] = params
        }
        let data = try JSONSerialization.data(withJSONObject: rpcDict)
        let str = String(data: data, encoding: .utf8)!

        return try await awaitResponse(id: id, timeout: timeout) { [weak self] in
            print("[ConnectionManager] Writing request id=\(id) method=\(method), socket=\(self?.socket != nil ? "exists" : "nil")")
            self?.socket?.write(string: str, completion: {
                print("[ConnectionManager] Write completed for request id=\(id) method=\(method)")
            })
            print("[ConnectionManager] Queued write for request id=\(id) method=\(method)")
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
    func awaitResponse(id: Int, timeout: TimeInterval,
                       write: @escaping @MainActor () -> Void) async throws -> Any {
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if let continuation = self?.pendingRequests.removeValue(forKey: id) {
                continuation.resume(throwing: NSError(
                    domain: "WebSocket", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Request timed out"]))
            }
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            pendingRequests[id] = continuation
            write()
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

    /// Register a handler for subscription.push notifications with the given subscriptionId.
    /// The handler will be invoked (on MainActor) whenever a subscription.push with matching
    /// subscriptionId is received. Stores should call this immediately after capturing their
    /// subscriptionId from the subscribe RPC response, in the same MainActor tick, to ensure
    /// register-before-first-push.
    ///
    /// - Parameters:
    ///   - id: The subscriptionId returned by the subscribe RPC
    ///   - handler: The MainActor-isolated handler to invoke for pushes with this subscriptionId
    func registerSubscriptionHandler(id: String, handler: @escaping @MainActor (SubscriptionPush) -> Void) {
        subscriptionHandlers[id] = handler
        recentlyUnregisteredIds.removeValue(forKey: id)
        print("[ConnectionManager] Registered subscription handler for id=\(id)")
        replayBufferedPushes(for: id, to: handler)
    }

    /// Unregister the handler for the given subscriptionId. After this call, pushes for this
    /// subscriptionId will be dropped (logged at debug and discarded).
    ///
    /// Stores should call this when:
    /// - Unsubscribing explicitly
    /// - Changing subscriptionId (unregister old id before registering new one)
    /// - On disconnect/reset
    /// - On deinit (if the store is deallocated)
    ///
    /// - Parameter id: The subscriptionId to unregister
    func unregisterSubscriptionHandler(id: String) {
        subscriptionHandlers.removeValue(forKey: id)
        // Any buffered pushes belong to the now-dead subscription — drop them so they
        // can never replay into a future handler, and tombstone the id so straggler
        // pushes arriving before the daemon processes the unsubscribe are not buffered.
        pruneExpiredBufferedPushes()
        unroutedPushBuffer.removeAll { $0.push.subscriptionId == id }
        recentlyUnregisteredIds[id] = Date()
        print("[ConnectionManager] Unregistered subscription handler for id=\(id)")
    }

    /// Buffer an unrouted subscription.push so it can be replayed when a handler is
    /// registered for its subscriptionId (fixes the dropped seq-0 snapshot race).
    private func bufferUnroutedPush(_ push: SubscriptionPush) {
        pruneExpiredBufferedPushes()
        if recentlyUnregisteredIds[push.subscriptionId] != nil {
            // An initial snapshot (seq 0) means the daemon legitimately reused the id
            // for a brand-new subscription (ids reset on daemon restart) — revive it
            // so the fresh snapshot isn't lost to the tombstone. Anything else is a
            // straggler from the dead subscription.
            if push.kind == .snapshot && push.seq == 0 {
                recentlyUnregisteredIds.removeValue(forKey: push.subscriptionId)
            } else {
                print("[ConnectionManager] Dropped subscription.push for recently unregistered id=\(push.subscriptionId) seq=\(push.seq)")
                return
            }
        }
        unroutedPushBuffer.append(BufferedPush(push: push, receivedAt: Date()))
        if unroutedPushBuffer.count > Self.unroutedPushBufferLimit {
            unroutedPushBuffer.removeFirst(unroutedPushBuffer.count - Self.unroutedPushBufferLimit)
        }
        print("[ConnectionManager] Buffered unrouted subscription.push for id=\(push.subscriptionId) seq=\(push.seq) (no handler registered yet, buffered=\(unroutedPushBuffer.count))")
    }

    /// Replay buffered pushes for the given subscriptionId, in arrival order, to the
    /// newly registered handler. Buffered entries are removed before delivery so a push
    /// is either routed live or replayed once — never both.
    private func replayBufferedPushes(for id: String, to handler: @MainActor (SubscriptionPush) -> Void) {
        pruneExpiredBufferedPushes()
        let matching = unroutedPushBuffer.filter { $0.push.subscriptionId == id }
        guard !matching.isEmpty else { return }
        unroutedPushBuffer.removeAll { $0.push.subscriptionId == id }
        print("[ConnectionManager] Replaying \(matching.count) buffered push(es) for id=\(id)")
        for entry in matching {
            handler(entry.push)
        }
    }

    /// Drop buffered pushes and unregister tombstones older than the TTL.
    /// Internal for test visibility.
    func pruneExpiredBufferedPushes(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.unroutedPushBufferTTL)
        unroutedPushBuffer.removeAll { $0.receivedAt < cutoff }
        recentlyUnregisteredIds = recentlyUnregisteredIds.filter { $0.value >= cutoff }
    }

    /// Internal entry point for testing message dispatch.
    @MainActor
    func dispatchMessage(_ text: String) {
        handleTextMessage(text)
    }

    // MARK: - Host route refresh

    /// Fire-and-forget wrapper around `refreshHostRoutes()`. Called from every
    /// successful connect path (initial connect and reconnect) so route refresh
    /// never delays the connection becoming usable.
    private func scheduleHostRoutesRefresh() {
        Task { await self.refreshHostRoutes() }
    }

    /// Shared post-connect hook: queries `system.status` for the daemon's
    /// `localIps` and merges them into the known host routes — both the
    /// in-memory list used by reconnect racing and the persisted
    /// `StoredConnection` record (the active connection, verified against the
    /// live token + port; updated by record id since `upsertConnection`
    /// matches by host set + port and would duplicate the record when the
    /// host set grows).
    ///
    /// Failures are non-fatal: older daemons without `localIps` and transport
    /// errors are skipped silently and the connection proceeds unchanged.
    func refreshHostRoutes() async {
        guard connectionState == .connected, let token = token, let port = port else { return }
        let myGeneration = connectionGeneration

        guard let result = try? await request("system.status") else {
            print("[ConnectionManager] Host route refresh: system.status failed (skipping)")
            return
        }
        guard let reported = Self.localIps(fromSystemStatus: result), !reported.isEmpty else {
            print("[ConnectionManager] Host route refresh: no localIps reported (skipping)")
            return
        }

        // A newer connect() may have superseded us while the RPC was in flight.
        guard connectionGeneration == myGeneration else { return }

        let merged = Self.mergeHosts(existing: hosts, reported: reported)
        if merged != hosts {
            print("[ConnectionManager] Host route refresh: hosts \(hosts) -> \(merged)")
            hosts = merged
        }

        // Persist to the record we actually connected through: the active
        // connection. Token + port must match the live connection — during
        // initial pairing the active record is still the previous one (or
        // absent) until ConnectionPairing.finalize saves + activates the new
        // record and re-triggers this refresh. Matching by token + port alone
        // would be ambiguous: the same daemon can be saved as separate records
        // with different host sets at the same port.
        //
        // Merge against the STORED hosts, not just the in-memory merge: this
        // session may have connected with a narrower host list than the
        // record holds (e.g. a single-host manual re-pair while the record
        // also has a NAT hostname), and persisting the in-memory merge alone
        // would drop those hosts.
        if let stored = PersistenceManager.shared.activeConnection(),
            stored.token == token, stored.server.port == port {
            let persistedHosts = Self.mergeHosts(existing: stored.server.hosts, reported: merged)
            if stored.server.hosts != persistedHosts {
                PersistenceManager.shared.updateConnectionHosts(id: stored.id, hosts: persistedHosts)
            }
        }
    }

    /// Extracts the `localIps` array from a `system.status` result. Returns nil
    /// when the field is absent (older daemon) or malformed.
    static func localIps(fromSystemStatus result: Any) -> [String]? {
        guard let status = result as? [String: Any],
              let ips = status["localIps"] as? [String] else { return nil }
        return ips
    }

    /// Merges daemon-reported IPs into the existing host list: existing hosts
    /// (originally paired/entered) keep their order and are never dropped;
    /// reported IPs not already present are appended, deduped.
    static func mergeHosts(existing: [String], reported: [String]) -> [String] {
        var merged = existing
        var seen = Set(existing)
        for ip in reported {
            let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            merged.append(trimmed)
            seen.insert(trimmed)
        }
        return merged
    }

    // MARK: - Private

    private func raceHosts(_ hosts: [String], port: Int, token: String, certFingerprint: String?) async throws -> WebSocket {
        let scheme = certFingerprint != nil ? "wss" : "ws"

        // Track all racing sockets for cleanup
        let racingSockets = NSMutableArray()
        let socketsLock = NSLock()

        return try await withThrowingTaskGroup(of: WebSocket.self) { group in
            for host in hosts {
                group.addTask { [certFingerprint, token] in
                    let url = URL(string: "\(scheme)://\(host):\(port)/ws")!
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 4
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    // Suppress Starscream's auto-generated Origin header. Native WebSocket clients
                    // (RFC 6455 §10.2) don't need it, and the desktop server accepts connections
                    // without one. Starscream only auto-fills Origin when the request doesn't
                    // already have it (see Starscream HTTPHandler.swift:57-64), so an empty value
                    // here prevents the URL-derived default from being sent.
                    request.setValue("", forHTTPHeaderField: "Origin")

                    let ws: WebSocket
                    if let fp = certFingerprint {
                        let pinner = CertFingerprintPinner(pinnedFingerprint: fp)
                        ws = WebSocket(request: request, certPinner: pinner)
                    } else {
                        ws = WebSocket(request: request)
                    }
                    ws.callbackQueue = DispatchQueue(label: "com.intent.ws.race.\(host)")

                    // Track this socket for cleanup
                    socketsLock.lock()
                    racingSockets.add(ws)
                    socketsLock.unlock()

                    let hostStart = CFAbsoluteTimeGetCurrent()
                    print("[ConnectionManager] Racing host \(host):\(port)")

                    // Declare resumeOnce, lock, resumed, and timeoutWork outside
                    // withTaskCancellationHandler so onCancel can access them.
                    // This ensures that when cancelAll() fires, the onCancel handler
                    // can immediately resume the continuation and cancel the GCD timeout,
                    // rather than waiting for Starscream to fire a .cancelled event.
                    var resumed = false
                    let lock = NSLock()
                    // Use a mutable container so the closure can capture the reference
                    // and we can assign the real DispatchWorkItem after creating it.
                    class TimeoutHolder { var work: DispatchWorkItem? }
                    let timeoutHolder = TimeoutHolder()
                    // Similarly, hold the resumeOnce closure so onCancel can call it.
                    class ResumeHolder { var resume: ((Result<WebSocket, Error>) -> Void)? }
                    let resumeHolder = ResumeHolder()

                    return try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { continuation in

                            func resumeOnce(_ result: Result<WebSocket, Error>) {
                                lock.lock()
                                defer { lock.unlock() }
                                guard !resumed else { return }
                                resumed = true
                                switch result {
                                case .success(let s): continuation.resume(returning: s)
                                case .failure(let e): continuation.resume(throwing: e)
                                }
                            }

                            // Store resumeOnce so onCancel can use it
                            lock.lock()
                            resumeHolder.resume = resumeOnce
                            lock.unlock()

                            // Timeout (cancellable)
                            let timeoutWork = DispatchWorkItem {
                                let elapsed = Int((CFAbsoluteTimeGetCurrent() - hostStart) * 1000)
                                print("[ConnectionManager] Host \(host) timed out in \(elapsed)ms")
                                ws.disconnect()
                                resumeOnce(.failure(NSError(domain: "WebSocket", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "Connection to \(host) timed out"])))
                            }
                            timeoutHolder.work = timeoutWork
                            DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: timeoutWork)

                            ws.onEvent = { event in
                                switch event {
                                case .connected:
                                    let elapsed = Int((CFAbsoluteTimeGetCurrent() - hostStart) * 1000)
                                    print("[ConnectionManager] Host \(host) connected in \(elapsed)ms")
                                    timeoutWork.cancel()
                                    resumeOnce(.success(ws))
                                case .error(let error):
                                    let elapsed = Int((CFAbsoluteTimeGetCurrent() - hostStart) * 1000)
                                    print("[ConnectionManager] Host \(host) failed in \(elapsed)ms: \(String(describing: error))")
                                    timeoutWork.cancel()
                                    resumeOnce(.failure(error ?? NSError(domain: "WebSocket", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "Connection to \(host) failed"])))
                                case .disconnected(let reason, _):
                                    let elapsed = Int((CFAbsoluteTimeGetCurrent() - hostStart) * 1000)
                                    print("[ConnectionManager] Host \(host) disconnected in \(elapsed)ms: \(reason)")
                                    timeoutWork.cancel()
                                    resumeOnce(.failure(NSError(domain: "WebSocket", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "Disconnected from \(host): \(reason)"])))
                                case .cancelled:
                                    let elapsed = Int((CFAbsoluteTimeGetCurrent() - hostStart) * 1000)
                                    print("[ConnectionManager] Host \(host) cancelled in \(elapsed)ms")
                                    timeoutWork.cancel()
                                    resumeOnce(.failure(NSError(domain: "WebSocket", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "Connection to \(host) cancelled"])))
                                default: break
                                }
                            }
                            ws.connect()
                        }
                    } onCancel: {
                        timeoutHolder.work?.cancel()
                        ws.disconnect()
                        resumeHolder.resume?(.failure(CancellationError()))
                    }
                }
            }

            var lastError: Error?
            while let result = await group.nextResult() {
                switch result {
                case .success(let ws):
                    group.cancelAll()
                    // Disconnect all losing sockets
                    socketsLock.lock()
                    let allSockets = racingSockets.compactMap { $0 as? WebSocket }
                    socketsLock.unlock()
                    for s in allSockets where s !== ws {
                        s.disconnect()
                    }
                    return ws
                case .failure(let error):
                    lastError = error
                    print("[ConnectionManager] Host racing: \(error.localizedDescription)")
                    continue
                }
            }
            throw lastError ?? NSError(domain: "WebSocket", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No reachable host found"])
        }
    }

    private func configureSocketEventHandler() {
        let currentSocket = socket
        socket?.onEvent = { [weak self] event in
            guard let self = self else { return }
            guard self.socket === currentSocket else {
                print("[ConnectionManager] Ignoring event from stale socket")
                return
            }
            switch event {
            case .text(let text):
                let preview = String(text.prefix(100))
                print("[ConnectionManager] Received text: \(preview)...")
                Task { @MainActor in self.handleTextMessage(text) }
            case .connected(let headers):
                print("[ConnectionManager] Socket connected, headers: \(headers)")
            case .disconnected(let reason, let code):
                print("[ConnectionManager] Socket disconnected: reason=\(reason), code=\(code)")
                Task { @MainActor in self.handleDisconnection() }
            case .cancelled:
                print("[ConnectionManager] Socket cancelled")
                Task { @MainActor in self.handleDisconnection() }
            case .error(let error):
                print("[ConnectionManager] Socket error: \(String(describing: error))")
                Task { @MainActor in self.handleDisconnection() }
            case .binary(let data):
                print("[ConnectionManager] Received binary: \(data.count) bytes")
            case .pong(_):
                print("[ConnectionManager] Received pong")
                Task { @MainActor in self.lastPongReceived = Date() }
            case .ping(_):
                print("[ConnectionManager] Received ping")
            case .viabilityChanged(let viable):
                print("[ConnectionManager] Viability changed: \(viable)")
                if !viable {
                    Task { @MainActor in self.handleDisconnection() }
                }
            case .reconnectSuggested(let suggested):
                print("[ConnectionManager] Reconnect suggested: \(suggested)")
                if suggested {
                    Task { @MainActor in self.handleDisconnection() }
                }
            case .peerClosed:
                print("[ConnectionManager] Peer closed")
                Task { @MainActor in self.handleDisconnection() }
            }
        }
    }

    @MainActor
    private func handleTextMessage(_ text: String) {
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
                        userInfo: userInfo))
                } else {
                    continuation.resume(returning: json["result"] as Any)
                }
            }
        } else if let method = json["method"] as? String {
            let params = json["params"] as Any

            // Route subscription.push to the registered handler for that subscriptionId.
            // Legacy eventHandlers must NOT receive subscription.push (router is the single source).
            if let push = SubscriptionPush.parse(method: method, params: params) {
                if let handler = subscriptionHandlers[push.subscriptionId] {
                    handler(push)  // Already on MainActor, call directly
                } else {
                    // No handler yet — buffer for replay on registration instead of dropping.
                    // Dropping here loses the seq-0 snapshot when the push races the store's
                    // handler registration after the subscribe response resumes.
                    bufferUnroutedPush(push)
                }
                return  // Do NOT fall through to legacy eventHandlers
            }

            // If subscription.push parse failed (malformed), drop it with a warning
            if method == "subscription.push" {
                let paramsDict = params as? [String: Any] ?? [:]
                let subscriptionId = paramsDict["subscriptionId"] as? String ?? "nil"
                let keys = paramsDict.keys.sorted().joined(separator: ", ")
                print("[ConnectionManager] Warning: Malformed subscription.push dropped (subscriptionId=\(subscriptionId), keys=[\(keys)])")
                return
            }

            // Broadcast other events to all legacy eventHandlers (subscription.push is NOT broadcast)
            for handler in eventHandlers.values {
                handler(method, params)
            }
        }
    }

    private func handleDisconnection() {
        let disconnectTime = CFAbsoluteTimeGetCurrent()
        print("[ConnectionManager] handleDisconnection called, current state=\(connectionState)")
        guard connectionState != .disconnected else {
            print("[ConnectionManager] Already disconnected, ignoring")
            return
        }
        stopPingTimer()
        socket?.disconnect()
        socket = nil
        connectionState = .reconnecting(attempt: 1)
        failAllPending(error: "Connection lost")
        startReconnection(disconnectTime: disconnectTime)
    }

    private func startReconnection(disconnectTime: CFAbsoluteTime? = nil) {
        reconnectTask?.cancel()
        let myGeneration = connectionGeneration
        let reconnectStart = disconnectTime ?? CFAbsoluteTimeGetCurrent()
        reconnectTask = Task { [weak self] in
            var attempt = 1
            while !Task.isCancelled {
                if attempt > 1 {
                    let delay = min(Double(1 << min(attempt - 2, 5)), 30.0)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    if Task.isCancelled { break }
                }

                let attemptStart = CFAbsoluteTimeGetCurrent()
                print("[ConnectionManager] Reconnect attempt \(attempt) starting at +\(Int((attemptStart - reconnectStart) * 1000))ms")

                // Batch read: check generation + set state + read all connection params in one MainActor call
                let (currentGen, hostsToTry, currentPort, currentToken, currentCertFingerprint) = await MainActor.run {
                    self?.connectionState = .reconnecting(attempt: attempt)
                    return (self?.connectionGeneration ?? -1,
                            self?.hosts ?? [],
                            self?.port ?? 0,
                            self?.token ?? "",
                            self?.certFingerprint)
                }
                guard currentGen == myGeneration else { return }

                do {
                    let raceStart = CFAbsoluteTimeGetCurrent()
                    print("[ConnectionManager] raceHosts starting at +\(Int((raceStart - reconnectStart) * 1000))ms")

                    let winningSocket = try await self?.raceHosts(hostsToTry, port: currentPort, token: currentToken, certFingerprint: currentCertFingerprint)

                    let raceEnd = CFAbsoluteTimeGetCurrent()
                    print("[ConnectionManager] raceHosts completed in \(Int((raceEnd - raceStart) * 1000))ms")

                    guard let winningSocket = winningSocket else { continue }

                    // Batch write: check generation + set up socket + transition to connected in one MainActor call
                    let genOk = await MainActor.run { () -> Bool in
                        guard self?.connectionGeneration == myGeneration else { return false }
                        self?.socket = winningSocket
                        self?.host = winningSocket.request.url?.host
                        self?.configureSocketEventHandler()
                        self?.connectionState = .connected
                        self?.subscribeToAllEvents()
                        self?.startPingTimer()
                        self?.scheduleHostRoutesRefresh()
                        return true
                    }
                    guard genOk else {
                        winningSocket.disconnect(closeCode: CloseCode.normal.rawValue)
                        return
                    }

                    let elapsed = (CFAbsoluteTimeGetCurrent() - reconnectStart) * 1000
                    print("[ConnectionManager] Reconnect complete in \(Int(elapsed))ms")
                    return
                } catch {
                    // Check if cert mismatch — all hosts failed with cert errors
                    let nsError = error as NSError
                    if nsError.code == -1,
                       nsError.domain == "WebSocket",
                       currentCertFingerprint != nil,
                       nsError.localizedDescription.contains("failed") {
                        // Check if this looks like a cert pinning failure
                        print("[ConnectionManager] Possible certificate mismatch detected, stopping reconnection")
                        await MainActor.run {
                            self?.certMismatchDetected = true
                            self?.connectionState = .disconnected
                        }
                        return
                    }
                    print("[ConnectionManager] Reconnect attempt \(attempt) failed: \(error.localizedDescription)")
                }
                attempt += 1
            }
        }
    }

    private func subscribeToAllEvents() {
        Task {
            do {
                let _ = try await self.request("events.subscribe", params: [
                    "eventTypes": ["workspace:*", "note:*", "agent:*"],
                    "replaceGroup": "global"
                ])
                print("[ConnectionManager] Subscribed to all events")
            } catch {
                print("[ConnectionManager] Failed to subscribe to events: \(error)")
            }
        }
    }

    // MARK: - Heartbeat

    private func startPingTimer() {
        stopPingTimer()
        lastPongReceived = Date()
        pingTimer = Timer.scheduledTimer(withTimeInterval: Self.pingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendPingAndCheckHealth()
            }
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func sendPingAndCheckHealth() {
        guard connectionState == .connected else { return }

        // Check if we've timed out
        let timeSinceLastPong = Date().timeIntervalSince(lastPongReceived)
        if timeSinceLastPong > Self.pongTimeout {
            print("[ConnectionManager] Ping timeout — no pong received in \(Int(timeSinceLastPong))s, triggering reconnection")
            stopPingTimer()
            handleDisconnection()
            return
        }

        // Send ping
        socket?.write(ping: Data())
    }

    func failAllPending(error message: String) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: NSError(
                domain: "WebSocket", code: -3,
                userInfo: [NSLocalizedDescriptionKey: message]))
        }
    }
}

// MARK: - Certificate Pinning (Starscream)

class CertFingerprintPinner: CertificatePinning {
    let pinnedFingerprint: String
    var lastMismatchFingerprint: String?

    init(pinnedFingerprint: String) {
        self.pinnedFingerprint = pinnedFingerprint
    }

    func evaluateTrust(trust: SecTrust, domain: String?, completion: ((PinningState) -> ())) {
        guard SecTrustGetCertificateCount(trust) > 0,
              let cert = SecTrustGetCertificateAtIndex(trust, 0) else {
            completion(.failed(nil))
            return
        }
        let certData = SecCertificateCopyData(cert) as Data
        let fingerprint = SHA256.hash(data: certData)
            .map { String(format: "%02x", $0) }
            .joined(separator: ":")

        if fingerprint.lowercased() == pinnedFingerprint.lowercased() {
            completion(.success)
        } else {
            print("[CertPinning] Fingerprint mismatch!")
            print("[CertPinning] Expected: \(pinnedFingerprint)")
            print("[CertPinning] Got:      \(fingerprint)")
            lastMismatchFingerprint = fingerprint
            completion(.failed(nil))
        }
    }
}

// MARK: - ConnectionManagerRouting Conformance

extension ConnectionManager: ConnectionManagerRouting {
    // ConnectionManager already implements all required methods and properties.
    // This extension provides explicit conformance to the protocol.
}

// MARK: - JSON-RPC error discriminator

extension NSError {
    /// userInfo key carrying the JSON-RPC `error.data.code` discriminator (PROTOCOL §3.3).
    static let intentErrorDataCodeKey = "intentErrorDataCode"

    /// The JSON-RPC `error.data.code` discriminator attached by the daemon, if any.
    var intentErrorDataCode: String? {
        userInfo[NSError.intentErrorDataCodeKey] as? String
    }

    /// True only for a definitive entity-not-found JSON-RPC error: `-32602` with
    /// `error.data.code == "not-found"` (PROTOCOL §3.3/§9). Any other `-32602`
    /// (`invalid-params`, a more specific code, or absent `data`) must NOT be
    /// treated as "entity deleted".
    var isEntityNotFound: Bool {
        domain == "WebSocket" && code == -32602 && intentErrorDataCode == "not-found"
    }
}