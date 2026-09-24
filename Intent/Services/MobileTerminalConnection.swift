import Foundation
import Observation

@MainActor
@Observable
final class MobileTerminalConnection {
    static let initialColumns = 80
    static let initialRows = 24
    static let maximumBufferBytes = 1_048_576
    static let maximumPendingInputBytes = 65_536

    private(set) var isReady = false
    private(set) var errorMessage: String?
    @ObservationIgnored var outputHandler: ((Data, Bool) -> Void)?
    @ObservationIgnored private let store: MobileTerminalStore
    @ObservationIgnored private let terminal: MobileTerminal
    @ObservationIgnored private var handlerId: UUID?
    @ObservationIgnored private var subscriptionId: String?
    @ObservationIgnored private var attachmentId = UUID()
    @ObservationIgnored private var attachedGeneration: Int?
    @ObservationIgnored private var pendingOutput = Data()
    @ObservationIgnored private var pendingInput = Data()
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var columns = initialColumns
    @ObservationIgnored private var rows = initialRows

    init(store: MobileTerminalStore, terminal: MobileTerminal) {
        self.store = store
        self.terminal = terminal
    }

    isolated deinit {
        writer?.cancel()
        resizeTask?.cancel()
        if let handlerId { store.connection.removeEventHandler(id: handlerId) }
    }

    func attach() async {
        detach()
        errorMessage = nil
        guard store.isConnected else { return }
        let attachment = attachmentId
        let generation = store.connectionGeneration
        do {
            try await store.validate(terminal)
            try checkAttachment(attachment, generation: generation)
            handlerId = store.connection.onEvent { [weak self] method, params in
                self?.receive(method, params: params)
            }
            let response = try await store.connection.request("events.subscribe", params: [
                "workspaceId": terminal.workspaceId,
                "eventTypes": ["terminal:data"],
                "replaceGroup": "ios-terminal-\(attachment.uuidString)"
            ])
            guard let result = response as? [String: Any],
                  let id = result["subscriptionId"] as? String else {
                throw MobileTerminalError.invalidResponse
            }
            guard attachment == attachmentId, generation == store.connectionGeneration else {
                unsubscribe(id, generation: generation)
                return
            }
            subscriptionId = id
            let buffer = try await store.connection.request("terminal.getBuffer", params: [
                "terminalId": terminal.id, "maxBytes": Self.maximumBufferBytes
            ])
            try checkAttachment(attachment, generation: generation)
            guard let result = buffer as? [String: Any],
                  let encoded = result["data"] as? String,
                  let snapshot = Data(base64Encoded: encoded) else {
                throw MobileTerminalError.invalidResponse
            }
            let replay = Self.replay(snapshot: snapshot, pending: pendingOutput)
            pendingOutput.removeAll()
            outputHandler?(replay, true)
            attachedGeneration = generation
            isReady = true
            resize(columns: columns, rows: rows)
        } catch {
            guard attachment == attachmentId else { return }
            detach()
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func detach() {
        attachmentId = UUID()
        attachedGeneration = nil
        isReady = false
        pendingOutput.removeAll()
        pendingInput.removeAll()
        writer?.cancel()
        writer = nil
        resizeTask?.cancel()
        resizeTask = nil
        if let handlerId { store.connection.removeEventHandler(id: handlerId) }
        handlerId = nil
        if let subscriptionId { unsubscribe(subscriptionId, generation: store.connectionGeneration) }
        subscriptionId = nil
    }

    func send(_ data: Data) {
        guard isReady, store.isConnected, store.isActive(terminal),
              attachedGeneration == store.connectionGeneration else { return }
        guard pendingInput.count + data.count <= Self.maximumPendingInputBytes else {
            errorMessage = "Too much input is waiting to send. Paste a smaller selection."
            return
        }
        pendingInput.append(data)
        guard writer == nil else { return }
        let attachment = attachmentId
        let generation = store.connectionGeneration
        writer = Task { [weak self] in
            guard let self else { return }
            defer { if attachment == attachmentId { writer = nil } }
            do {
                while !pendingInput.isEmpty {
                    try checkAttachment(attachment, generation: generation)
                    let data = pendingInput
                    pendingInput.removeAll()
                    _ = try await store.connection.request("terminal.write", params: [
                        "terminalId": terminal.id, "data": data.base64EncodedString()
                    ])
                }
            } catch {
                guard attachment == attachmentId else { return }
                pendingInput.removeAll()
                isReady = false
                errorMessage = "Input could not be confirmed. Reconnect before typing again."
            }
        }
    }

    func resize(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        guard isReady, attachedGeneration == store.connectionGeneration, resizeTask == nil else { return }
        let attachment = attachmentId
        let generation = store.connectionGeneration
        resizeTask = Task { [weak self] in
            guard let self else { return }
            defer { if attachment == attachmentId { resizeTask = nil } }
            do {
                var sentColumns: Int
                var sentRows: Int
                repeat {
                    try checkAttachment(attachment, generation: generation)
                    sentColumns = self.columns
                    sentRows = self.rows
                    _ = try await store.connection.request("terminal.resize", params: [
                        "terminalId": terminal.id, "cols": sentColumns, "rows": sentRows
                    ])
                } while self.columns != sentColumns || self.rows != sentRows
            } catch {
                if attachment == attachmentId, !(error is CancellationError) {
                    errorMessage = "The terminal size could not be updated."
                }
            }
        }
    }

    private func checkAttachment(_ attachment: UUID, generation: Int) throws {
        try Task.checkCancellation()
        try store.checkConnection(generation)
        guard attachment == attachmentId else { throw CancellationError() }
        guard store.isActive(terminal) else { throw MobileTerminalError.sessionEnded }
    }

    private func receive(_ method: String, params: Any) {
        guard method == "events.event", let envelope = params as? [String: Any],
              subscriptionId == nil || envelope["subscriptionId"] as? String == subscriptionId,
              let event = envelope["event"] as? [String: Any],
              event["type"] as? String == "terminal:data",
              event["workspaceId"] as? String == terminal.workspaceId,
              let payload = event["data"] as? [String: Any],
              payload["terminalId"] as? String == terminal.id,
              let chunk = payload["chunk"] as? String,
              let data = Data(base64Encoded: chunk) else { return }
        if isReady {
            outputHandler?(data, false)
        } else {
            pendingOutput.append(data)
            if pendingOutput.count > Self.maximumBufferBytes {
                pendingOutput = Data(pendingOutput.suffix(Self.maximumBufferBytes))
            }
        }
    }

    private func unsubscribe(_ id: String, generation: Int) {
        Task { [store] in
            guard generation == store.connectionGeneration, store.isConnected else { return }
            _ = try? await store.connection.request("events.unsubscribe", params: ["subscriptionId": id])
        }
    }

    // The buffer and stream overlap while a snapshot request is in flight.
    nonisolated static func replay(snapshot: Data, pending: Data) -> Data {
        guard !pending.isEmpty else { return snapshot }
        let bytes = pending.map(Int.init) + [-1] + snapshot.suffix(pending.count).map(Int.init)
        var prefix = Array(repeating: 0, count: bytes.count)
        for index in 1..<bytes.count {
            var match = prefix[index - 1]
            while match > 0, bytes[index] != bytes[match] { match = prefix[match - 1] }
            if bytes[index] == bytes[match] { match += 1 }
            prefix[index] = match
        }
        return snapshot + pending.dropFirst(prefix.last ?? 0)
    }
}
