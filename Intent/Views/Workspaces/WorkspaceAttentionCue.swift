import SwiftUI
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
/// never double-chime. Plays one short system sound per batch that contains
/// at least one newly-attention workspace.
@MainActor
final class WorkspaceAttentionCueCenter {
    static let shared = WorkspaceAttentionCueCenter()

    private var tracker = WorkspaceAttentionCueTracker()
    private let playSound: () -> Void

    init(playSound: @escaping () -> Void = { AudioServicesPlaySystemSound(1152) }) {
        self.playSound = playSound
    }

    func observe(workspaces: [Workspace]) {
        let universe = Set(workspaces.map(\.id))
        let attention = Set(workspaces.filter(workspaceNeedsInput).map(\.id))
        if tracker.observe(universe: universe, attention: attention) {
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
