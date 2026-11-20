import AVFoundation

nonisolated protocol MediaAudioSessionClient: Sendable {
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: MediaAudioSessionClient {}

actor MediaAudioSession {
    static let shared = MediaAudioSession()

    enum Purpose: Sendable {
        case playback
        case dictation
        case notification
    }

    private let client: any MediaAudioSessionClient
    private var leases: [UUID: Purpose] = [:]

    init(client: any MediaAudioSessionClient = AVAudioSession.sharedInstance()) {
        self.client = client
    }

    func acquire(_ purpose: Purpose) throws -> UUID {
        try Task.checkCancellation()
        let lease = UUID()
        leases[lease] = purpose
        do {
            try configure()
            try client.setActive(true, options: [])
            return lease
        } catch {
            leases[lease] = nil
            try? updateAfterRelease()
            throw error
        }
    }

    func release(_ lease: UUID) throws {
        guard leases.removeValue(forKey: lease) != nil else { return }
        try updateAfterRelease()
    }

    private func updateAfterRelease() throws {
        if leases.isEmpty {
            try client.setActive(false, options: .notifyOthersOnDeactivation)
        } else {
            try configure()
        }
    }

    private func configure() throws {
        let recording = leases.values.contains(.dictation)
        let playing = leases.values.contains(.playback)
        let notifying = leases.values.contains(.notification)
        if recording {
            try client.setCategory(
                playing ? .playAndRecord : .record,
                mode: .measurement,
                options: playing ? [.duckOthers, .defaultToSpeaker] : .duckOthers
            )
        } else if playing {
            try client.setCategory(.playback, mode: .moviePlayback, options: [])
        } else if notifying {
            try client.setCategory(.ambient, mode: .default, options: .mixWithOthers)
        }
    }
}
