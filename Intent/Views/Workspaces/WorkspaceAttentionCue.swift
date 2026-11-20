import AudioToolbox
import Observation
import SwiftUI

func workspaceNeedsInput(_ workspace: Workspace) -> Bool {
    let status = resolveDisplayStatus(for: workspace)
    return status == .blocked || status == .needsAttention || hasUnreadAttention(workspace)
}

struct WorkspaceAttentionCueTracker {
    private(set) var primed = false
    private var attentionIds: Set<String> = []

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

@MainActor
@Observable
final class WorkspaceAttentionCueCenter {
    static let shared = WorkspaceAttentionCueCenter()
    private static let attentionSystemSoundID: SystemSoundID = 1152

    struct WindowCueEvent: Equatable {
        let id = UUID()
    }

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
    @ObservationIgnored private var lastAlertChime: [String: Date] = [:]
    @ObservationIgnored private var lastCueSound: [String: Date] = [:]
    @ObservationIgnored private let windowEmitsCueSound: Bool

    nonisolated static var platformWindowEmitsCueSound: Bool {
        #if os(visionOS)
        true
        #else
        false
        #endif
    }

    init(
        playSound: @escaping () -> Void = {
            guard NotificationSoundPolicy.system.attentionCuePlays() else { return }
            AudioServicesPlaySystemSound(WorkspaceAttentionCueCenter.attentionSystemSoundID)
        },
        windowEmitsCueSound: Bool = WorkspaceAttentionCueCenter.platformWindowEmitsCueSound,
        now: @escaping () -> Date = Date.init
    ) {
        self.playSound = playSound
        self.windowEmitsCueSound = windowEmitsCueSound
        self.now = now
    }

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
    @ViewBuilder
    func visionAttentionCue(_ presentation: WorkspaceAttentionCuePresentation, reduceMotion: Bool) -> some View {
        #if os(visionOS)
        self
            .scaleEffect(presentation.liftsTowardViewer ? Constants.WorkspaceRow.attentionCueScale : 1)
            .offset(z: presentation.liftsTowardViewer ? Constants.WorkspaceRow.attentionCueZOffset : 0)
            .animation(
                reduceMotion ? nil : .easeOut(duration: Constants.WorkspaceRow.attentionCueAnimationDuration),
                value: presentation.liftsTowardViewer
            )
            .opacity(presentation.isHidden ? 0 : 1)
            .allowsHitTesting(!presentation.isHidden)
            .accessibilityHidden(presentation.isHidden)
            .animation(nil, value: presentation.isHidden)
        #else
        self
        #endif
    }

    @ViewBuilder
    func visionAttentionChipBrightness(_ active: Bool) -> some View {
        #if os(visionOS)
        self.brightness(active ? Constants.WorkspaceRow.attentionChipBrightness : 0)
        #else
        self
        #endif
    }

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
