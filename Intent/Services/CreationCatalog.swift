import Foundation
import Observation
import Synchronization

/// One backend-local catalog. Successful empty values are warm. A read is
/// owned by the cache, so cancelling one caller cannot cancel another's RPC.
@MainActor
@Observable
final class CreationCatalog<Element> {
    // Nil means no successful catalog read; an empty array is a successfully loaded catalog.
    // swiftlint:disable:next discouraged_optional_collection
    private(set) var value: [Element]?
    private(set) var loadFailed = false
    @ObservationIgnored private(set) var isFresh = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var consumers: Set<UUID> = []
    @ObservationIgnored private var callers: [UUID: Interest] = [:]
    @ObservationIgnored private var flight: Flight?
    /// The most recently started read, kept after its flight retires so
    /// tests can await a superseded read's real completion. Never read here.
    @ObservationIgnored private(set) var latestReadTask: Task<Void, Never>?
    private let fetch: @MainActor () async throws -> [Element]

    nonisolated private final class Interest: Sendable {
        let consumer: UUID?
        private let cancelled = Mutex(false)

        init(consumer: UUID?) { self.consumer = consumer }

        var isCancelled: Bool { cancelled.withLock { $0 } }

        func cancel() { cancelled.withLock { $0 = true } }
    }

    private final class Flight {
        let result = WorkspaceStatusWaiters<Bool>()
        var task: Task<Void, Never>?
        var sent = false
    }

    init(fetch: @escaping @MainActor () async throws -> [Element]) {
        self.fetch = fetch
    }

    func retain(_ consumer: UUID) { consumers.insert(consumer) }

    func release(_ consumer: UUID) {
        consumers.remove(consumer)
        callers = callers.filter { $0.value.consumer != consumer }
        retireIfUninterested()
    }

    /// Explicit picker refreshes bypass freshness but join an existing read.
    /// Label ensures never launch a silent read behind a valid cache hit.
    @discardableResult
    func ensure(force: Bool = false, consumer: UUID? = nil) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let consumer, !consumers.contains(consumer) { return false }
        if isFresh, !force { return true }
        let id = UUID()
        let interest = Interest(consumer: consumer)
        callers[id] = interest
        defer {
            callers[id] = nil
            retireIfUninterested()
        }
        if force { isFresh = false }
        let flight = start()
        return await withTaskCancellationHandler {
            await flight.result.wait(cancelledValue: false)
        } onCancel: {
            interest.cancel()
            Task { @MainActor [weak self] in self?.retireIfUninterested() }
        }
    }

    /// Bursts during one flight share at most one trailing read. If that read
    /// is invalidated too, leave the cache stale for the next ensure/event.
    func invalidate(refresh: Bool) {
        revision &+= 1
        isFresh = false
        if refresh, !consumers.isEmpty, flight == nil { _ = start() }
    }

    func refreshIfInterested() {
        if !consumers.isEmpty, !isFresh, flight == nil { _ = start() }
    }

    /// Hard resets/backend teardown clear labels. A connection transition can
    /// retain the last good value while rejecting every pre-transition reply.
    func reset(clear: Bool = true, releaseConsumers: Bool = false) {
        revision &+= 1
        isFresh = false
        loadFailed = false
        if clear { value = nil }
        retireFlight()
        callers = [:]
        if releaseConsumers { consumers = [] }
    }

    private var hasInterest: Bool {
        !consumers.isEmpty || callers.values.contains { !$0.isCancelled }
    }

    private func start() -> Flight {
        if let flight { return flight }
        let next = Flight()
        flight = next
        next.task = Task { [weak self] in await self?.read(next) }
        latestReadTask = next.task
        return next
    }

    private func read(_ current: Flight) async {
        defer {
            if flight === current { flight = nil }
            current.result.finish(isFresh)
        }
        for round in 0..<2 {
            guard flight === current, hasInterest, !Task.isCancelled else { return }
            let startedAt = revision
            current.sent = true
            do {
                let received = try await fetch()
                guard flight === current, hasInterest else { return }
                if revision != startedAt {
                    if round == 0 { continue }
                    loadFailed = true
                    return
                }
                value = received
                isFresh = true
                loadFailed = false
                return
            } catch {
                guard flight === current, hasInterest else { return }
                if revision != startedAt, round == 0 { continue }
                loadFailed = true
                return
            }
        }
    }

    private func retireIfUninterested() {
        if !hasInterest { retireFlight() }
    }

    private func retireFlight() {
        guard let current = flight else { return }
        flight = nil
        // A sent transport callback lives until its reply/timeout/disconnect.
        // It cannot publish or launch a follow-up after this flight retires.
        if !current.sent { current.task?.cancel() }
        current.result.finish(false)
    }
}
