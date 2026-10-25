import Foundation

extension ConversationLiveTranscript {
    func loadOlderMessages(using commands: ConversationCommands, beforePrepend: (() -> Void)? = nil) async {
        guard !Task.isCancelled, !isLoadingOlderMessages,
              let agentId, let cursor = olderMessagesCursor else { return }
        let generation = olderHistoryGeneration
        isLoadingOlderMessages = true
        olderMessagesError = nil
        let interval = ConversationTrace.begin("OlderMessagesFetch", "\(traceContext) historyGeneration=\(generation)")
        var outcome = "failed"
        defer {
            ConversationTrace.end("OlderMessagesFetch", interval, "\(traceContext) historyGeneration=\(generation) outcome=\(outcome)")
            // A superseded request cannot dismiss a newer request's loader.
            if generation == olderHistoryGeneration { isLoadingOlderMessages = false }
        }
        do {
            let page = try await commands.fetchOlderMessages(
                agentId: agentId, workspaceId: workspaceId, nextToken: cursor
            )
            traceEvent("OlderMessagesResponse", "historyGeneration=\(generation) messages=\(page.messages.count) hasNext=\(page.nextToken != nil)")
            guard !Task.isCancelled, generation == olderHistoryGeneration else {
                outcome = "rejected"
                traceEvent("OlderMessagesRejected", "reason=cancelled_or_superseded historyGeneration=\(generation)")
                return
            }
            var residentIds = Set(messages.map(\.id))
            // The daemon serves each page oldest-first. Existing live rows win
            // over page duplicates, including any newer content or hydration.
            let older = page.messages.filter { residentIds.insert($0.id).inserted }
            // Capture the current reading intent before publishing changes that
            // can replace the measured row frames. No suspension separates them.
            if !older.isEmpty { beforePrepend?() }
            messages.insert(contentsOf: older, at: 0)
            remergeHydratedBlocks()
            olderMessagesCursor = page.nextToken
            isTruncated = hasOlderMessages
            outcome = "accepted"
            traceEvent("OlderMessagesAccepted", "received=\(page.messages.count) inserted=\(older.count) resident=\(messages.count)")
            onTranscriptReplaced?()
        } catch {
            traceEvent("OlderMessagesFailed", "historyGeneration=\(generation) cancelled=\(Task.isCancelled)")
            guard !Task.isCancelled, generation == olderHistoryGeneration else { return }
            olderMessagesError = "Could not load older messages. Please try again."
        }
    }

    func resetOlderHistory() {
        invalidateOlderMessagesLoad()
        olderMessagesCursor = nil
        olderHistorySeeded = false
    }

    private func invalidateOlderMessagesLoad() {
        olderHistoryGeneration &+= 1
        isLoadingOlderMessages = false
        olderMessagesError = nil
    }

    /// Full snapshots own their suffix; preserve only the connected older
    /// prefix. A resume snapshot is instead an append since an existing row,
    /// so even an empty resume with nextToken:null retains the older cursor.
    func replaceHistory(with incoming: [ConversationMessage], metadata: [String: Any]) {
        invalidateOlderMessagesLoad()
        if olderHistorySeeded, metadata["resumed"] as? Bool == true {
            let replacements = Dictionary(incoming.map { ($0.id, $0) }) { _, last in last }
            var seen = Set(messages.map(\.id))
            messages = messages.map { replacements[$0.id] ?? $0 }
                + incoming.filter { seen.insert($0.id).inserted }
        } else if olderHistorySeeded, let firstId = incoming.first?.id,
                  let overlap = messages.firstIndex(where: { $0.id == firstId }), overlap > 0 {
            let incomingIds = Set(incoming.map(\.id))
            messages = messages[..<overlap].filter { !incomingIds.contains($0.id) } + incoming
        } else {
            messages = incoming
            olderMessagesCursor = metadata["nextToken"] as? String
            isTruncated = metadata["truncated"] as? Bool ?? false
        }
        olderHistorySeeded = true
    }
}
