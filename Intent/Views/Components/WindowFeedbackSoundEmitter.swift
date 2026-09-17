import Foundation

/// First-observer claim registry deduplicating window sound playback.
/// Duplicate windows bound to the SAME backend (the rebound-window quirk)
/// observe the same `FeedbackEvent`/`WindowCueEvent`, so each such window's
/// emitter would fire for one event. The first emitter to observe an event
/// id claims it and plays; later observers of the same id skip — exactly
/// one audible playback per event regardless of how many windows share the
/// backend. Windows on different backends observe distinct events (fresh
/// ids), so they are unaffected. Platform-neutral so the iOS test target
/// can exercise it; only visionOS emitters consult it.
@MainActor
final class WindowSoundClaimRegistry {
    static let shared = WindowSoundClaimRegistry()

    private var claimed: [UUID] = []
    private let capacity: Int

    /// `capacity` bounds the remembered ids (FIFO eviction); events are
    /// claimed within one MainActor turn of publication, so a small window
    /// suffices.
    init(capacity: Int = 32) {
        self.capacity = capacity
    }

    /// Claims `id` for the calling emitter. Returns true when it was
    /// unclaimed (the caller plays); false when another window's emitter
    /// already claimed it (the caller skips).
    func claim(_ id: UUID) -> Bool {
        guard !claimed.contains(id) else { return false }
        claimed.append(id)
        if claimed.count > capacity {
            claimed.removeFirst(claimed.count - capacity)
        }
        return true
    }
}

#if os(visionOS)
import AVFAudio
import RealityKit
import SwiftUI

/// Invisible RealityKit anchor that plays a notification sound from within
/// THIS window's scene, so visionOS spatial audio localizes the sound to
/// the window — with headphones the user hears WHICH workspace window asked
/// for attention. A window mounts one emitter per sound source (the
/// agent-completion chime and the workspace attention cue); only the window
/// that must emit receives a non-nil trigger id, and each fresh id
/// re-triggers playback even for back-to-back alerts. When duplicate
/// windows share a backend and all observe the same event, the claim
/// registry lets exactly one of them play it.
struct WindowFeedbackSoundEmitter: View {
    /// Id of the latest sound request this window must emit; nil when this
    /// window has nothing to play.
    let eventID: UUID?

    @State private var emitter = Entity()
    @State private var resource: AudioFileResource?
    /// This window's scene identifier, captured from the hosting UIWindow.
    /// Before each playback the audio session's intended spatial experience
    /// is anchored to this scene, so pre-visionOS-26 spatial audio localizes
    /// the sound to this window rather than the app's first window.
    @State private var sceneID: String?

    var body: some View {
        RealityView { content in
            emitter.components.set(SpatialAudioComponent())
            content.add(emitter)
        }
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .background(WindowSceneIdentifierReader { sceneID = $0 })
        .onChange(of: eventID) { _, newID in
            guard let newID, WindowSoundClaimRegistry.shared.claim(newID) else { return }
            Task { await play() }
        }
    }

    private func play() async {
        if resource == nil, let url = NotificationChime.fileURL() {
            resource = try? await AudioFileResource(contentsOf: url)
        }
        guard let resource else { return }
        // Anchor immediately before playback: the first play suspends on
        // the resource load above, and an interleaved first play from
        // another window could re-anchor the shared audio session in
        // between — anchoring after the load keeps this window's anchor
        // in effect when its sound actually starts.
        anchorAudioToThisScene()
        emitter.playAudio(resource)
    }

    /// Best-effort: anchors the app's intended spatial experience to this
    /// window's scene so the sound localizes to it. Failures (or a not-yet
    /// resolved scene id) are non-fatal — playback proceeds with whatever
    /// anchoring is in effect.
    private func anchorAudioToThisScene() {
        guard let sceneID else { return }
        try? AVAudioSession.sharedInstance().setIntendedSpatialExperience(
            .headTracked(
                soundStageSize: .automatic,
                anchoringStrategy: .scene(identifier: sceneID)
            )
        )
    }
}

/// Reports the hosting window's scene identifier
/// (`UIScene.session.persistentIdentifier`) once the view lands in a window.
private struct WindowSceneIdentifierReader: UIViewRepresentable {
    let onResolve: (String?) -> Void

    func makeUIView(context _: Context) -> ProbeView {
        let view = ProbeView()
        view.onResolve = onResolve
        return view
    }

    func updateUIView(_: ProbeView, context _: Context) {}

    final class ProbeView: UIView {
        var onResolve: ((String?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            let identifier = window?.windowScene?.session.persistentIdentifier
            guard let onResolve else { return }
            // Deferred: didMoveToWindow can fire inside a SwiftUI update
            // pass, where mutating @State is not allowed.
            DispatchQueue.main.async { onResolve(identifier) }
        }
    }
}
#endif
