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

    // Live-state capability from client.hello
    private(set) var liveStateCapability: Bool = false

    private init() {}

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

        let totalElapsed = CFAbsoluteTimeGetCurrent() - connectStart
        print("[ConnectionManager] Connect: total elapsed \(Int(totalElapsed * 1000))ms, connected to \(self.host ?? "?")")

        // Call client.hello to detect liveState capability
        Task { @MainActor in
            await detectLiveStateCapability()
        }
    }

    func disconnect() {
        stopPingTimer()
        reconnectTask?.cancel()
        reconnectTask = nil
        socket?.disconnect(closeCode: CloseCode.normal.rawValue)
        socket = nil
        connectionState = .disconnected
        liveStateCapability = false
        failAllPending(error: "Connection closed")
    }

    // MARK: - Public API

    func request(_ method: String, params: [String: Any] = [:]) async throws -> Any {
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

        return try await withThrowingTaskGroup(of: Any.self) { [weak self] group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                    self?.pendingRequests[id] = continuation
                    print("[ConnectionManager] Writing request id=\(id) method=\(method), socket=\(self?.socket != nil ? "exists" : "nil")")
                    self?.socket?.write(string: str, completion: {
                        print("[ConnectionManager] Write completed for request id=\(id) method=\(method)")
                    })
                    print("[ConnectionManager] Queued write for request id=\(id) method=\(method)")
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                throw NSError(domain: "WebSocket", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "Request timed out"])
            }
            let result = try await group.next()!
            group.cancelAll()
            // Clean up pending request on timeout
            await MainActor.run {
                self?.pendingRequests.removeValue(forKey: id)
            }
            return result
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

    /// Internal entry point for testing message dispatch.
    func dispatchMessage(_ text: String) async {
        handleTextMessage(text)
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

                    // Extract error.data.message if present (daemon stashes real cause there)
                    var effectiveMessage = topMessage
                    if let errorData = error["data"] as? [String: Any],
                       let dataMessage = errorData["message"] as? String,
                       !dataMessage.isEmpty {
                        effectiveMessage = dataMessage
                    }

                    let description = hasCode ? "\(effectiveMessage) (\(code))" : effectiveMessage
                    continuation.resume(throwing: NSError(
                        domain: "WebSocket",
                        code: code,
                        userInfo: [NSLocalizedDescriptionKey: description]))
                } else {
                    continuation.resume(returning: json["result"] as Any)
                }
            }
        } else if let method = json["method"] as? String {
            let params = json["params"] as Any
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
                        Task { @MainActor [weak self] in
                            await self?.detectLiveStateCapability()
                        }
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

    private func detectLiveStateCapability() async {
        do {
            let result = try await self.request("client.hello")
            if let dict = result as? [String: Any],
               let caps = dict["capabilities"] as? [String: Any],
               let liveState = caps["liveState"] as? Bool {
                liveStateCapability = liveState
                print("[ConnectionManager] Detected liveState capability: \(liveState)")
            } else {
                liveStateCapability = false
                print("[ConnectionManager] No liveState capability detected, using legacy path")
            }
        } catch {
            liveStateCapability = false
            print("[ConnectionManager] client.hello failed: \(error), using legacy path")
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