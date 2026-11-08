import AVFoundation

/// The synchronous system calls live behind this boundary so the session owner
/// can serialize them off MainActor, independently of players and audio engines.
nonisolated protocol MediaAudioSessionClient: Sendable {
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: MediaAudioSessionClient {}

/// AVAudioSession is process-wide, including across visionOS windows. Leases
/// prevent a dismissed player's delayed cleanup from disabling a new recording
/// (or another player). No suspension occurs while changing the system session.
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
            // Activation may have partially succeeded. Restore other consumers,
            // or return audio to other apps if this was the only one.
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
            // A recording in another window must not silence video or lose
            // microphone access. Return to dictation's own category afterwards.
            try client.setCategory(
                playing ? .playAndRecord : .record,
                mode: .measurement,
                options: playing ? [.duckOthers, .defaultToSpeaker] : .duckOthers
            )
        } else if playing {
            try client.setCategory(.playback, mode: .moviePlayback, options: [])
        } else if notifying {
            // A short chime mixes with other apps' audio and respects the
            // silent switch.
            try client.setCategory(.ambient, mode: .default, options: .mixWithOthers)
        }
        // Callers configure only while at least one lease is held, so one of
        // the purposes above always applies.
    }
}
