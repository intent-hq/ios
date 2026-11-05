@testable import Intent
import Testing

@Suite("Notification sound policy")
@MainActor
struct NotificationSoundPolicyTests {
    private func policy(volume: Float, soundEnabled: Bool = true, settingsReads: (() -> Void)? = nil) -> NotificationSoundPolicy {
        NotificationSoundPolicy(
            outputVolume: { volume },
            notificationSoundEnabled: {
                settingsReads?()
                return soundEnabled
            }
        )
    }

    @Test(arguments: [(Float(0), false), (0.01, true), (1, true)])
    func volumeGatedSoundsRequireAudibleOutput(volume: Float, plays: Bool) {
        // Notification settings never affect these paths.
        let policy = policy(volume: volume, soundEnabled: false)

        #expect(policy.scheduledNotificationPlaysSound() == plays)
        #expect(policy.windowSoundPlays() == plays)
        #expect(policy.attentionCuePlays() == plays)
    }

    @Test(arguments: [false, true], [Float(0), 1])
    func foregroundBannerFollowsNotificationSoundSetting(soundEnabled: Bool, volume: Float) async {
        // Output volume never affects foreground banners: its read can be stale.
        let policy = policy(volume: volume, soundEnabled: soundEnabled)

        #expect(await policy.foregroundBannerPlaysSound(requested: true) == soundEnabled)
    }

    @Test func unrequestedForegroundBannerIsSilentWithoutReadingSettings() async {
        var settingsReads = 0
        let policy = policy(volume: 1) { settingsReads += 1 }

        #expect(await !policy.foregroundBannerPlaysSound(requested: false))
        #expect(settingsReads == 0)
    }
}
