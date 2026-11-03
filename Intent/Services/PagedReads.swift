import Foundation

/// Paged daemon reads (protocol "bounded reads", `server.capabilities.boundedReads: 1`).
///
/// A bounded daemon answers list reads one page at a time with `nextToken`
/// (an opaque string, `null` on the last page), sends the first page of a
/// collection subscription's snapshot with `params.nextToken`, and cuts a very
/// large note in `note.get` with `contentTruncated` / `nextContentOffset`.
/// Older daemons ignore `limit` / `nextToken` / `contentOffset` and answer in
/// one reply without a token, so every walk here ends after one request.
enum PagedReads {
    /// Hard stop for any walk, so a misbehaving daemon cannot loop forever.
    static let maxPages = 1000
    /// `note.list` / `note.subscribe` page size: the daemon maximum.
    static let notePageLimit = 500
    /// `comment.list` / `comment.subscribe` page size (threads): the daemon maximum.
    static let commentPageLimit = 500
    /// `workspace.list` page size for one-shot reads: the daemon maximum.
    static let workspacePageLimit = 200
    /// Attempts per continuation page before the walk gives up.
    static let pageAttempts = 3
    private static let pageRetryBaseMilliseconds = 250
    /// First retry delay for a failed page; doubles per attempt.
    static let pageRetryBase: Duration = .milliseconds(pageRetryBaseMilliseconds)
    /// Whole-note reads restart at most this many times when the note changes mid-walk.
    static let wholeNoteAttempts = 3
    private static let resubscribeBackoffCapSeconds = 30
    private static let resubscribeBackoffMaxExponent = 5

    typealias Request = ([String: Any]) async throws -> Any
    typealias Sleep = (Duration) async -> Void

    static let defaultSleep: Sleep = { duration in try? await Task.sleep(for: duration) }

    /// The continuation token of a paged reply or snapshot push, or nil at the end.
    static func nextToken(_ reply: Any?) -> String? {
        guard let token = (reply as? [String: Any])?["nextToken"] as? String, !token.isEmpty else {
            return nil
        }
        return token
    }

    /// Delay before retry `attempt` (1-based) of a failed page.
    static func retryDelay(attempt: Int) -> Duration {
        pageRetryBase * (1 << (attempt - 1))
    }

    /// Backoff before resubscribing after a continuation walk gave up `failures` times in a row.
    static func resubscribeDelay(failures: Int) -> Duration {
        .seconds(min(resubscribeBackoffCapSeconds, 1 << min(failures, resubscribeBackoffMaxExponent)))
    }

    /// Reads every page of a list method and returns the concatenated `field`
    /// rows. `params` are repeated on every page with the previous page's
    /// `nextToken`. Stops at the end, on a repeated token, or after `maxPages`.
    /// Any page error is thrown, so callers never publish a partial list as whole.
    static func requestAllPages(
        params: [String: Any],
        field: String,
        request: Request
    ) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var seen = Set<String>()
        var token: String?
        for _ in 0..<maxPages {
            var pageParams = params
            if let token { pageParams["nextToken"] = token }
            let reply = try await request(pageParams)
            if let pageRows = (reply as? [String: Any])?[field] as? [[String: Any]] {
                rows.append(contentsOf: pageRows)
            }
            guard let next = nextToken(reply), seen.insert(next).inserted else { break }
            token = next
        }
        return rows
    }

    /// How a snapshot continuation walk ended.
    enum FillOutcome: Equatable {
        /// Every page was read.
        case completed
        /// A page failed `pageAttempts` times; the caller should resubscribe.
        case failed
        /// A newer snapshot, reset or teardown replaced the target; the walk stopped silently.
        case superseded
    }

    /// The list read that continues a paged snapshot: the rows' key in the
    /// reply and the request for one page by token.
    struct PageSource {
        let field: String
        let requestPage: (String) async throws -> Any
    }

    /// Reads the rest of a paged subscription snapshot (protocol §6.9 "Paged
    /// snapshots") from `firstToken`, handing each page's rows to `applyPage`.
    /// Each page gets `pageAttempts` tries with doubling backoff. `isCurrent`
    /// is checked after every suspension so a superseded walk never applies a page.
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
        while let current = token, pages < maxPages, seen.insert(current).inserted {
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

/// Whole-note reads through the `note.get` content cursor (protocol §5.2
/// "Bounded note and comment reads"). A bounded daemon cuts a note whose row
/// would overflow the read budget and marks it `contentTruncated` with
/// `contentBytes`, `contentOffset` and `nextContentOffset`; passing
/// `nextContentOffset` back as `contentOffset` reads on, on UTF-8 boundaries.
enum NoteContentPages {
    private static let cursorKeys = ["contentTruncated", "contentBytes", "contentOffset", "nextContentOffset"]

    /// Reads `note.get` with `params` and follows the content cursor. Returns
    /// the reply in its original shape (`{ note }` or a bare note) with the
    /// whole `content` and no cut markers. If the note changes between pages
    /// (`rev`) the read restarts; if the pages cannot be joined into exactly
    /// `contentBytes`, or a later page keeps failing, the first (still cut)
    /// reply is returned so callers show it as a prefix. The first request's
    /// errors propagate unchanged (not-found classification), as do cancellations.
    static func readWholeNote(
        params: [String: Any],
        sleep: PagedReads.Sleep = PagedReads.defaultSleep,
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

    /// The note of a `{ note }` reply or a bare note row.
    // swiftlint:disable:next discouraged_optional_collection
    private static func unwrap(_ reply: Any) -> [String: Any]? {
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

    /// Follows `nextContentOffset` from `offset` and joins the pages onto the
    /// first read's content; whole only when the join is exactly `contentBytes`.
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

    /// One continuation page with the shared retry policy; nil when it keeps failing.
    // swiftlint:disable:next discouraged_optional_collection
    private static func readPage(
        _ params: [String: Any],
        sleep: PagedReads.Sleep,
        request: PagedReads.Request
    ) async throws -> [String: Any]? {
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

/// Drives the continuation of one store's paged subscription snapshot: reads
/// the remaining pages into the reconciler, then tells the store to publish.
/// A page that keeps failing ends the walk; the store may publish what it has,
/// and resubscribes for a fresh snapshot after a backoff that grows with
/// consecutive failed walks.
///
/// While `isFilling` the reconciler holds only part of the collection, so
/// stores keep showing their previous list instead of publishing a partial
/// one (a partial workspace list would read as deleted workspaces).
final class PagedSnapshotFiller {
    /// The owning store's side of a walk.
    struct Owner {
        /// False once the store moved on (another subscription, workspace or note).
        let isCurrent: () -> Bool
        /// Publish the reconciled collection; `complete` is false after a failed walk.
        let publish: (_ complete: Bool) -> Void
        /// Resubscribe for a fresh snapshot (called after the failure backoff).
        let resubscribe: () async -> Void
    }

    private(set) var isFilling = false
    /// Consecutive walks that gave up; feeds the resubscribe backoff.
    private(set) var failures = 0
    private var generation = 0
    private var task: Task<Void, Never>?
    /// Test seam: page retry and resubscribe backoff sleeps.
    var sleep: PagedReads.Sleep = PagedReads.defaultSleep

    deinit {
        task?.cancel()
    }

    /// Stops any running walk without resubscribing.
    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        isFilling = false
    }

    /// Starts a walk that fills `reconciler` from `firstToken`, replacing any
    /// running one. A newer snapshot or reset of `reconciler` (its `epoch`),
    /// `cancel()`, or `owner.isCurrent()` turning false stops the walk silently.
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
            isFilling = false
            switch outcome {
            case .completed:
                failures = 0
                owner.publish(true)
            case .failed:
                owner.publish(false)
                let delay = PagedReads.resubscribeDelay(failures: failures)
                failures += 1
                await sleep(delay)
                guard live() else { return }
                await owner.resubscribe()
            case .superseded:
                break
            }
        }
    }
}
