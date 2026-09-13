import Foundation

/// Placement decisions for the presentation-only "New messages" divider
/// (FE parity: new-messages-divider.ts).
///
/// The daemon persists a per-session `lastSeenMessageId` marker (PROTOCOL
/// §5.5, `agent.markSeen`), served in AgentLite / `agent.get` metadata and
/// converged via `agent:updated`. On conversation entry (initial `load()`
/// transcript fetch) the ConversationViewModel derives the anchor ONCE via
/// `resolveAnchor` and latches it for the lifetime of the view model;
/// rendering then uses only the latched anchor (`resolveLatchedAnchor`), so
/// later marker convergence never moves the divider.
enum NewMessagesDivider {
    /// Entry-time anchor derivation.
    ///
    /// Returns the id of the message the divider renders after, or `nil` when
    /// today's behavior applies (no divider, entry scroll-to-bottom):
    /// - no marker,
    /// - marker at the newest message (nothing unseen),
    /// - dangling marker — id not in the transcript (e.g. the row was dropped
    ///   by an `agent.editAndRegenerate` truncation).
    static func resolveAnchor(
        messageIds: [String],
        lastSeenMessageId: String?
    ) -> String? {
        guard let marker = lastSeenMessageId, !marker.isEmpty, !messageIds.isEmpty else {
            return nil
        }
        guard let markerIndex = messageIds.firstIndex(of: marker) else { return nil }
        if markerIndex == messageIds.count - 1 { return nil }
        return marker
    }

    /// Render-time placement from a LATCHED per-session anchor (never
    /// recomputed).
    ///
    /// Returns the anchor id when it is still present in the transcript, or
    /// `nil` (divider hidden) when:
    /// - the session latched `nil` — "session started, no divider" — so none
    ///   may appear for the rest of the viewing session,
    /// - the latched anchor is no longer in the transcript (e.g. dropped by an
    ///   `agent.editAndRegenerate` truncation) — hidden, NOT re-derived.
    static func resolveLatchedAnchor(
        messageIds: [String],
        latchedAnchorId: String?
    ) -> String? {
        guard let anchor = latchedAnchorId, !anchor.isEmpty else { return nil }
        return messageIds.contains(anchor) ? anchor : nil
    }

    /// Entry-scroll follow decision, evaluated AFTER the initial scroll to the
    /// divider has settled (iOS translation of the FE's
    /// `dividerVisibleWhenScrolledToBottom`, inverted).
    ///
    /// `distanceToBottom` is the gap between the viewport's bottom edge and
    /// the end of the content (`ConversationTranscriptScrollPolicy.distanceToBottom`),
    /// ≈ 0 at the visual bottom. The entry scroll targets the divider row
    /// pinned to the top of the screen; when the whole unseen tail fits on
    /// screen the scroll clamps at the bottom (distance stays within the
    /// at-bottom threshold) and follow-to-bottom must stay enabled — today's
    /// behavior. A larger distance means the viewport actually landed on the
    /// divider away from the bottom, so follow is disabled. The threshold
    /// matches the list's existing at-bottom detection (distance <= 50).
    static func followDisabledAfterEntryScroll(
        distanceToBottom: Double,
        atBottomThreshold: Double = Double(Constants.Conversation.Transcript.atBottomThreshold)
    ) -> Bool {
        distanceToBottom > atBottomThreshold
    }
}
