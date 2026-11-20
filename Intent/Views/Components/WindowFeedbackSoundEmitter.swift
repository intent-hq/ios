import Foundation

@MainActor
final class WindowSoundClaimRegistry {
    static let shared = WindowSoundClaimRegistry()

    private var claimed: [UUID] = []
    private let capacity: Int

    init(capacity: Int = 32) {
        self.capacity = capacity
    }

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

struct WindowFeedbackSoundEmitter: View {
    let eventID: UUID?

    @State private var emitter = Entity()
    @State private var resource: AudioFileResource?
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
        guard let resource, NotificationSoundPolicy.system.windowSoundPlays() else { return }
        anchorAudioToThisScene()
        emitter.playAudio(resource)
    }

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
            DispatchQueue.main.async { onResolve(identifier) }
        }
    }
}
#endif
