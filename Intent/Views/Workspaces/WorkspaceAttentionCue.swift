import SwiftUI
import Observation
import AudioToolbox

/// True when the workspace is asking for user input: a blocker/attention
/// display status (blocker, discussion, question, plan approval) or the
/// server-owned unread attention flag. Drives the visionOS attention cue
/// (z-lift + brighter status chip + one-shot sound); the unread part clears
/// via workspace.markSeen on open, the status part when the request resolves.
func workspaceNeedsInput(_ workspace: Workspace) -> Bool {
    let status = resolveDisplayStatus(for: workspace)
    return status == .blocked || status == .needsAttention || hasUnreadAttention(workspace)
}

/// Pure new-attention detector behind the once-per-new-item sound cue.
/// The first observation of a non-empty universe primes silently so items
/// that were already pending at launch never chime; afterwards only
/// absent → present transitions report as new, and a cleared item can
/// re-trigger if its workspace raises attention again.
struct WorkspaceAttentionCueTracker {
    private(set) var primed = false
    private var attentionIds: Set<String> = []

    /// Feeds one observation of the full workspace universe and its
    /// attention subset. Returns the workspaces that newly entered the
    /// attention set after the priming observation (empty otherwise).
    mutating func observe(universe: Set<String>, attention: Set<String>) -> Set<String> {
        guard primed else {
            if !universe.isEmpty {
                primed = true
                attentionIds = attention
            }
            return []
        }
        let newItems = attention.subtracting(attentionIds)
        attentionIds = attention
        return newItems
    }
}

/// Shared cue center: multiple list surfaces feed it the current workspace
/// snapshot; identical observations are idempotent, so dual-mounted lists
/// never double-chime. Emits one cue per batch that contains at least one
/// newly-attention workspace: a short global system sound, or — where the
/// window emits the cue (visionOS) — a `WindowCueEvent` the session's
/// window plays from within its own scene so spatial audio localizes the
/// cue to the window whose workspace list observed the new attention.
@MainActor
@Observable
final class WorkspaceAttentionCueCenter {
    static let shared = WorkspaceAttentionCueCenter()

    /// One attention-cue request for the session's window to emit. The
    /// fresh `id` distinguishes back-to-back cues.
    struct WindowCueEvent: Equatable {
        let id = UUID()
    }

    /// The latest cue for the session's window to emit; observed by window
    /// roots (`WindowFeedbackSoundEmitter` via RootView). Never set on
    /// platforms that play the global system sound.
    private(set) var windowCueEvent: WindowCueEvent?

    /// One agent event often drives BOTH audible paths: the agent:idle
    /// alert chime (NotificationManager) and this attention cue — the same
    /// completion flips its workspace to unread, and a raised blocker also
    /// emits agent:idle, so blocked/needsAttention transitions coincide
    /// with alert chimes too. Whichever kind fires first for a workspace
    /// suppresses the *other* kind for that workspace within this window;
    /// same-kind repeats are never suppressed here, and the visual cues
    /// (z-lift, chip brightness) are unaffected.
    static let dedupInterval: TimeInterval = 2.5

    @ObservationIgnored private var tracker = WorkspaceAttentionCueTracker()
    @ObservationIgnored private let playSound: () -> Void
    @ObservationIgnored private let now: () -> Date
    /// Per-workspace timestamps of the last *audible* trigger of each kind
    /// (recorded only when a sound actually played/published).
    @ObservationIgnored private var lastAlertChime: [String: Date] = [:]
    @ObservationIgnored private var lastCueSound: [String: Date] = [:]
    /// Whether the session's window emits the cue instead of `playSound`
    /// playing a global one. True on visionOS, where the global system
    /// sound is non-spatial — the same routing NotificationManager applies
    /// to the agent-completion chime (`windowEmitsFeedbackSound`).
    /// Injectable because tests run on the iOS simulator.
    @ObservationIgnored private let windowEmitsCueSound: Bool

    nonisolated static var platformWindowEmitsCueSound: Bool {
        #if os(visionOS)
        true
        #else
        false
        #endif
    }

    init(
        playSound: @escaping () -> Void = { AudioServicesPlaySystemSound(1152) },
        windowEmitsCueSound: Bool = WorkspaceAttentionCueCenter.platformWindowEmitsCueSound,
        now: @escaping () -> Date = Date.init
    ) {
        self.playSound = playSound
        self.windowEmitsCueSound = windowEmitsCueSound
        self.now = now
    }

    /// Called by NotificationManager just before it plays/publishes the
    /// agent-completion alert chime for `workspaceId`. Returns whether the
    /// chime should audibly play: false when this center sounded the
    /// attention cue for the same workspace within `dedupInterval` (the
    /// same agent event already produced an audible cue). When it returns
    /// true the chime is recorded so an immediately following attention
    /// flip for the workspace stays silent.
    func noteAlertChimeWillPlay(workspaceId: String) -> Bool {
        let timestamp = now()
        if let cueAt = lastCueSound[workspaceId],
           timestamp.timeIntervalSince(cueAt) < Self.dedupInterval {
            return false
        }
        lastAlertChime[workspaceId] = timestamp
        return true
    }

    func observe(workspaces: [Workspace]) {
        let universe = Set(workspaces.map(\.id))
        let attention = Set(workspaces.filter(workspaceNeedsInput).map(\.id))
        let newIds = tracker.observe(universe: universe, attention: attention)
        guard !newIds.isEmpty else { return }
        // Drop workspaces whose alert chime just sounded (the same agent
        // event); the batch stays silent only when every new item was
        // covered by a chime.
        let timestamp = now()
        let audibleIds = newIds.filter { id in
            guard let chimeAt = lastAlertChime[id] else { return true }
            return timestamp.timeIntervalSince(chimeAt) >= Self.dedupInterval
        }
        guard !audibleIds.isEmpty else { return }
        for id in audibleIds { lastCueSound[id] = timestamp }
        if windowEmitsCueSound {
            windowCueEvent = WindowCueEvent()
        } else {
            playSound()
        }
    }
}

extension View {
    /// Subtle single-step visionOS depth cue for rows needing user input:
    /// slight z-lift plus scale, animated once on state change — no
    /// continuous animation (HIG: gentle, non-looping attention cues).
    /// No-op on other platforms.
    @ViewBuilder
    func visionAttentionCue(_ active: Bool) -> some View {
        #if os(visionOS)
        self
            .scaleEffect(active ? Constants.WorkspaceRow.attentionCueScale : 1)
            .offset(z: active ? Constants.WorkspaceRow.attentionCueZOffset : 0)
            .animation(
                .easeOut(duration: Constants.WorkspaceRow.attentionCueAnimationDuration),
                value: active)
        #else
        self
        #endif
    }

    /// Brightens the status chip on visionOS while its workspace needs
    /// input, pairing with the row's depth cue. No-op on other platforms.
    @ViewBuilder
    func visionAttentionChipBrightness(_ active: Bool) -> some View {
        #if os(visionOS)
        self.brightness(active ? Constants.WorkspaceRow.attentionChipBrightness : 0)
        #else
        self
        #endif
    }

    /// Feeds workspace snapshots to the window session's cue center so a
    /// short system sound plays once per workspace that newly needs input
    /// (visionOS only). Attach to each workspace list surface. No-op on
    /// other platforms.
    @ViewBuilder
    func visionWorkspaceAttentionSound(_ workspaces: [Workspace]) -> some View {
        #if os(visionOS)
        self.modifier(VisionWorkspaceAttentionSoundModifier(workspaces: workspaces))
        #else
        self
        #endif
    }
}

#if os(visionOS)
/// Routes workspace snapshots to the session's cue center so pinned windows
/// chime for their own backend; falls back to the shared center when no
/// session is in the environment (previews/tests).
private struct VisionWorkspaceAttentionSoundModifier: ViewModifier {
    let workspaces: [Workspace]
    @Environment(BackendSession.self) private var session: BackendSession?

    private var center: WorkspaceAttentionCueCenter {
        session?.attentionCueCenter ?? .shared
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                center.observe(workspaces: workspaces)
            }
            .onChange(of: workspaces) { _, newWorkspaces in
                center.observe(workspaces: newWorkspaces)
            }
    }
}
#endif
