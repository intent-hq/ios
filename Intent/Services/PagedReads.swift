import Foundation

enum PagedReads {
    static let maxPages = 1000
    static let notePageLimit = 500
    static let commentPageLimit = 500
    static let workspacePageLimit = 200
    static let agentPageLimit = 200
    static let queuePageLimit = 200
    static let taskPageLimit = 1000
    static let pageAttempts = 3
    private static let pageRetryBaseMilliseconds = 250
    static let pageRetryBase: Duration = .milliseconds(pageRetryBaseMilliseconds)
    static let wholeNoteAttempts = 3
    private static let resubscribeBackoffCapSeconds = 30
    private static let resubscribeBackoffMaxExponent = 5

    typealias Request = @MainActor ([String: Any]) async throws -> Any
    typealias Sleep = @MainActor (Duration) async -> Void

    static let defaultSleep: Sleep = { duration in try? await Task.sleep(for: duration) }

    struct Cursor: Sendable {
        let param: String
        let field: String

        static let token = Self(param: "nextToken", field: "nextToken")
        static let script = Self(param: "cursor", field: "nextCursor")
    }

    static func nextToken(_ reply: Any?, cursor: Cursor = .token) -> String? {
        guard let token = (reply as? [String: Any])?[cursor.field] as? String, !token.isEmpty else {
            return nil
        }
        return token
    }

    static func retryDelay(attempt: Int) -> Duration {
        pageRetryBase * (1 << (attempt - 1))
    }

    static func resubscribeDelay(failures: Int) -> Duration {
        .seconds(min(resubscribeBackoffCapSeconds, 1 << min(failures, resubscribeBackoffMaxExponent)))
    }

    struct IncompleteWalk: Error {}

    static func requestAllPages(
        params: [String: Any],
        field: String,
        request: Request
    ) async throws -> [[String: Any]] {
        try await requestAllPages(params: params, field: field, cursor: .token, request: request)
    }

    static func requestAllPages(
        params: [String: Any],
        field: String,
        cursor: Cursor,
        request: Request
    ) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var seen = Set<String>()
        var token: String?
        for _ in 0..<maxPages {
            var pageParams = params
            if let token { pageParams[cursor.param] = token }
            let reply = try await request(pageParams)
            if let pageRows = (reply as? [String: Any])?[field] as? [[String: Any]] {
                rows.append(contentsOf: pageRows)
            }
            guard let next = nextToken(reply, cursor: cursor) else { return rows }
            guard seen.insert(next).inserted else { throw IncompleteWalk() }
            token = next
        }
        throw IncompleteWalk()
    }

    struct MalformedPage: Error {}

    static func requestWholeReply(
        params: [String: Any],
        field: String,
        request: Request
    ) async throws -> Any {
        try await requestWholeReply(params: params, field: field, cursor: .token, request: request)
    }

    static func requestWholeReply(
        params: [String: Any],
        field: String,
        cursor: Cursor,
        request: Request
    ) async throws -> Any {
        let first = try await request(params)
        guard var whole = first as? [String: Any], var elements = whole[field] as? [Any],
              var token = nextToken(first, cursor: cursor) else { return first }
        var seen: Set<String> = [token]
        for _ in 1..<maxPages {
            var pageParams = params
            pageParams[cursor.param] = token
            let reply = try await request(pageParams)
            guard let page = (reply as? [String: Any])?[field] as? [Any] else { throw MalformedPage() }
            elements.append(contentsOf: page)
            guard let next = nextToken(reply, cursor: cursor) else {
                whole[field] = elements
                whole.removeValue(forKey: cursor.field)
                return whole
            }
            guard seen.insert(next).inserted else { throw IncompleteWalk() }
            token = next
        }
        throw IncompleteWalk()
    }

    @MainActor
    static func requestAgentList(
        _ params: [String: Any],
        connection: ConnectionManagerRouting,
        isCurrent: @MainActor () -> Bool = { true }
    ) async throws -> Any {
        var params = params
        params["limit"] = agentPageLimit
        return try await requestWholeReply(params: params, field: "agents") { page in
            if page["nextToken"] != nil, !isCurrent() { throw CancellationError() }
            return try await connection.request("agent.list", params: page)
        }
    }

    static func requestAllScripts(workspaceId: String, request: Request) async throws -> Any {
        try await requestWholeReply(params: ["workspaceId": workspaceId], field: "scripts", cursor: .script, request: request)
    }

    enum FillOutcome: Equatable {
        case completed
        case failed
        case superseded
    }

    struct PageSource {
        let field: String
        let requestPage: @MainActor (String) async throws -> Any
    }

    static func fillSnapshot(
        from firstToken: String,
        source: PageSource,
        isCurrent: () -> Bool,
        sleep: Sleep,
        applyPage: ([[String: Any]]) -> Void
    ) async -> FillOutcome {
        var token: String? = firstToken
        var seen = Set<String>()
        var pages = 0
        while let current = token {
            guard pages < maxPages, seen.insert(current).inserted else { return .failed }
            var reply: Any?
            for attempt in 0..<pageAttempts {
                if attempt > 0 {
                    await sleep(retryDelay(attempt: attempt))
                    guard isCurrent() else { return .superseded }
                }
                reply = try? await source.requestPage(current)
                guard isCurrent() else { return .superseded }
                if reply != nil { break }
            }
            guard let reply else { return .failed }
            applyPage(((reply as? [String: Any])?[source.field] as? [[String: Any]]) ?? [])
            token = nextToken(reply)
            pages += 1
        }
        return .completed
    }
}

enum NoteContentPages {
    private static let cursorKeys = ["contentTruncated", "contentBytes", "contentOffset", "nextContentOffset"]

    static func readWholeNote(
        params: [String: Any],
        sleep: PagedReads.Sleep,
        request: PagedReads.Request
    ) async throws -> Any {
        var first: Any = [String: Any]()
        for _ in 0..<PagedReads.wholeNoteAttempts {
            first = try await request(params)
            guard let note = unwrap(first), let offset = nextOffset(note) else { return first }
            let walk = try await readRest(of: note, from: offset, params: params, sleep: sleep, request: request)
            switch walk {
            case .changed:
                continue
            case .prefix:
                return first
            case .whole(let content):
                return wholeReply(first, note: note, content: content)
            }
        }
        return first
    }

    private enum PageWalk {
        case changed
        case prefix
        case whole(String)
    }

    private static func unwrap(_ reply: Any) -> [String: Any]? { // swiftlint:disable:this discouraged_optional_collection
        guard let dict = reply as? [String: Any] else { return nil }
        if dict["note"] == nil { return dict }
        return dict["note"] as? [String: Any]
    }

    private static func nextOffset(_ note: [String: Any]) -> Int? {
        guard note["contentTruncated"] as? Bool == true,
              let next = note["nextContentOffset"] as? Int, next > 0 else { return nil }
        return next
    }

    private static func sameRev(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left as Int, right as Int):
            return left == right
        case let (left as String, right as String):
            return left == right
        default:
            return false
        }
    }

    private static func readRest(
        of note: [String: Any],
        from offset: Int,
        params: [String: Any],
        sleep: PagedReads.Sleep,
        request: PagedReads.Request
    ) async throws -> PageWalk {
        var content = note["content"] as? String ?? ""
        var cursor: Int? = offset
        var pages = 1
        while let current = cursor, pages < PagedReads.maxPages {
            var pageParams = params
            pageParams["contentOffset"] = current
            guard let chunk = try await readPage(pageParams, sleep: sleep, request: request) else { return .prefix }
            guard sameRev(chunk["rev"], note["rev"]) else { return .changed }
            guard let text = chunk["content"] as? String, chunk["contentOffset"] as? Int == current else {
                return .prefix
            }
            content += text
            pages += 1
            cursor = nextOffset(chunk)
            if let next = cursor, next <= current { return .prefix }
        }
        guard cursor == nil, content.utf8.count == note["contentBytes"] as? Int else { return .prefix }
        return .whole(content)
    }

    private static func readPage(
        _ params: [String: Any],
        sleep: PagedReads.Sleep,
        request: PagedReads.Request
    ) async throws -> [String: Any]? { // swiftlint:disable:this discouraged_optional_collection
        for attempt in 0..<PagedReads.pageAttempts {
            if attempt > 0 {
                await sleep(PagedReads.retryDelay(attempt: attempt))
                try Task.checkCancellation()
            }
            do {
                return unwrap(try await request(params))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return nil
    }

    private static func wholeReply(_ first: Any, note: [String: Any], content: String) -> Any {
        var whole = note
        for key in cursorKeys { whole.removeValue(forKey: key) }
        whole["content"] = content
        guard var wrapped = first as? [String: Any], wrapped["note"] != nil else { return whole }
        wrapped["note"] = whole
        return wrapped
    }
}

final class PagedSnapshotFiller {
    struct Owner {
        let isCurrent: () -> Bool
        let publish: (_ complete: Bool) -> Void
        let resubscribe: @MainActor () async -> Void
    }

    private(set) var isFilling = false
    private(set) var failures = 0
    private var generation = 0
    private var task: Task<Void, Never>?
    var sleep: PagedReads.Sleep = PagedReads.defaultSleep

    deinit {
        task?.cancel()
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        isFilling = false
    }

    func start<T>(
        _ reconciler: DeltaReconciler<T>,
        from firstToken: String,
        source: PagedReads.PageSource,
        owner: Owner
    ) {
        cancel()
        isFilling = true
        let walk = generation
        let epoch = reconciler.epoch
        let sleep = sleep
        task = Task { [weak self, weak reconciler] in
            let live = { [weak self, weak reconciler] in
                self?.generation == walk && reconciler?.epoch == epoch && owner.isCurrent()
            }
            let outcome = await PagedReads.fillSnapshot(
                from: firstToken,
                source: source,
                isCurrent: live,
                sleep: sleep
            ) { rows in reconciler?.fillFromPage(rows) }
            guard let self, generation == walk else { return }
            switch outcome {
            case .completed:
                isFilling = false
                failures = 0
                owner.publish(true)
            case .failed:
                owner.publish(false)
                let delay = PagedReads.resubscribeDelay(failures: failures)
                failures += 1
                await sleep(delay)
                guard generation == walk else { return }
                guard live() else {
                    isFilling = false
                    return
                }
                resubscribeOutsideWalk(owner)
            case .superseded:
                isFilling = false
            }
        }
    }

    private func resubscribeOutsideWalk(_ owner: Owner) {
        task = nil
        let resubscribe = owner.resubscribe
        Task { await resubscribe() }
    }
}
