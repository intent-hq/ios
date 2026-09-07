#if os(visionOS)
import SwiftUI
import RealityKit

/// Invisible RealityKit anchor that plays the notification chime from
/// within THIS window's scene, so visionOS spatial audio localizes the
/// sound to the window — with headphones the user hears WHICH workspace
/// window finished. Only the source backend's window receives a non-nil
/// event (RootView applies the same per-window decision as toast
/// rendering), so exactly one window emits each chime.
struct WindowFeedbackSoundEmitter: View {
    /// Latest feedback request this window must emit; each request's fresh
    /// id re-triggers playback even for back-to-back alerts.
    let event: NotificationManager.FeedbackEvent?

    @State private var emitter = Entity()
    @State private var resource: AudioFileResource?

    var body: some View {
        RealityView { content in
            emitter.components.set(SpatialAudioComponent())
            content.add(emitter)
        }
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: event) { _, newEvent in
            guard newEvent != nil else { return }
            Task { await play() }
        }
    }

    private func play() async {
        if resource == nil, let url = NotificationChime.fileURL() {
            resource = try? await AudioFileResource(contentsOf: url)
        }
        guard let resource else { return }
        emitter.playAudio(resource)
    }
}
#endif
