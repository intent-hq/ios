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
    /// attention subset. Returns true when at least one workspace newly
    /// entered the attention set after the priming observation.
    mutating func observe(universe: Set<String>, attention: Set<String>) -> Bool {
        guard primed else {
            if !universe.isEmpty {
                primed = true
                attentionIds = attention
            }
            return false
        }
        let newItems = attention.subtracting(attentionIds)
        attentionIds = attention
        return !newItems.isEmpty
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

    @ObservationIgnored private var tracker = WorkspaceAttentionCueTracker()
    @ObservationIgnored private let playSound: () -> Void
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
        windowEmitsCueSound: Bool = WorkspaceAttentionCueCenter.platformWindowEmitsCueSound
    ) {
        self.playSound = playSound
        self.windowEmitsCueSound = windowEmitsCueSound
    }

    func observe(workspaces: [Workspace]) {
        let universe = Set(workspaces.map(\.id))
        let attention = Set(workspaces.filter(workspaceNeedsInput).map(\.id))
        if tracker.observe(universe: universe, attention: attention) {
            if windowEmitsCueSound {
                windowCueEvent = WindowCueEvent()
            } else {
                playSound()
            }
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
