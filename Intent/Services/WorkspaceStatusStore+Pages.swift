import Foundation

/// Opt-in adapter for bounded active summaries. Events are reduced to summary
/// fields before entering the journal; full output/configuration is never retained.
@MainActor
struct WorkspaceStatusPageAdapter<Row> {
    struct Page {
        let rows: [Row]
        let nextCursor: String?
    }

    var canLoad: () -> Bool
    var request: (String, String?) async throws -> Page
    var merge: ([Row], [Row]) -> [Row]
    var normalizeEvent: (String, [String: Any], String) throws -> [String: Any]
    var identity: ([String: Any]) -> String?
    var didReceive: (String, [String: Any], String) -> Void
    var didFail: (Error, String) -> Void
}

extension WorkspaceStatusStore {
    static var journalLimit: Int { WorkspaceStatusPageLimits.journalEntries }

    func readPage(_ bucket: Bucket, workspaceId: String, generation: Int, nextPage: Bool) async {
        guard let adapter = pageAdapter else { return }
        var cursor = nextPage ? bucket.nextCursor : nil
        for attempt in 0..<2 {
            bucket.events = []
            bucket.recoveryIDs = []
            bucket.journalOverflow = false
            if attempt > 0 { bucket.tombstones = [:] }
            do {
                let page = try await adapter.request(workspaceId, cursor)
                guard owns(bucket, workspaceId: workspaceId, generation: generation), adapter.canLoad() else { return }
                if !bucket.journalOverflow {
                    var rows = adapter.merge(cursor == nil ? [] : bucket.rows, page.rows)
                    for (type, data) in bucket.events { rows = fold(rows, type, data).rows }
                    for (type, data) in bucket.tombstones.values { rows = fold(rows, type, data).rows }
                    bucket.rows = rows
                    bucket.nextCursor = page.nextCursor
                    bucket.failedNextPage = false
                }
                let recover = bucket.journalOverflow || !bucket.recoveryIDs.isEmpty
                bucket.recoveryExhausted = recover && attempt == 1
                bucket.isStale = recover
                bucket.error = recover ? "Script watches changed during refresh. Retry to update them." : nil
                bucket.events = []
                if !recover || attempt == 1 { return }
                // Recovery replaces page one once. Never drain/retry a cursor automatically.
                cursor = nil
            } catch {
                guard owns(bucket, workspaceId: workspaceId, generation: generation) else { return }
                bucket.failedNextPage = cursor != nil
                bucket.error = error.localizedDescription
                bucket.isStale = true
                bucket.events = []
                adapter.didFail(error, workspaceId)
                return
            }
        }
    }

    func applyPageEvent(_ type: String, data: [String: Any], bucket: Bucket, workspaceId: String, feedReady: Bool) {
        guard let adapter = pageAdapter, let identity = adapter.identity(data) else {
            recoverPage(bucket, workspaceId: workspaceId)
            return
        }
        if removalEvents.contains(type) {
            recordRemoval(type, data: data, identity: identity, bucket: bucket)
            bucket.recoveryIDs.remove(identity)
            bucket.events.removeAll { adapter.identity($0.1) == identity }
        } else if bucket.journalOverflow || bucket.tombstones[identity] != nil {
            return
        }
        let result = fold(bucket.rows, type, data)
        bucket.rows = result.rows
        adapter.didReceive(type, data, workspaceId)
        if result.needsRefetch { bucket.recoveryIDs.insert(identity) }
        if bucket.isLoading {
            if bucket.events.count < Self.journalLimit {
                bucket.events.append((type, data))
            } else {
                bucket.journalOverflow = true
            }
        } else if feedReady, result.needsRefetch || bucket.journalOverflow {
            recoverPage(bucket, workspaceId: workspaceId)
        }
    }

    private func recordRemoval(_ type: String, data: [String: Any], identity: String, bucket: Bucket) {
        // Keep only bounded identities. With no list in flight, old tombstones
        // can retire locally; selected detail reads have their own generations.
        if bucket.tombstones.count >= Self.journalLimit, bucket.tombstones[identity] == nil {
            if bucket.isLoading {
                bucket.journalOverflow = true
                return
            }
            bucket.tombstones.removeAll(keepingCapacity: true)
        }
        bucket.tombstones[identity] = (type, data)
    }

    func recoverPage(_ bucket: Bucket, workspaceId: String) {
        bucket.isStale = true
        bucket.recoveryIDs.insert("")
        guard !bucket.isLoading, !bucket.recoveryExhausted else { return }
        let generation = bucket.generation
        Task { [weak self] in
            guard let self, owns(bucket, workspaceId: workspaceId, generation: generation),
                  !bucket.recoveryIDs.isEmpty else { return }
            await load(workspaceId: workspaceId, refresh: true)
        }
    }
}

private enum WorkspaceStatusPageLimits {
    static let journalEntries = 256
}
