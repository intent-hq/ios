import AVFAudio
import UserNotifications

/// The one owner of every "should this notification or attention sound
/// play" decision. Call sites ask it instead of reading the output volume
/// or notification settings themselves, so a change to sound behaviour is
/// made (and tested) here.
///
/// Two inputs, both injectable for tests:
/// - `outputVolume`: the device output volume. Scheduled notifications,
///   the visionOS window sound and the attention cue stay silent at zero.
/// - `notificationSoundEnabled`: whether sound is enabled for this app in
///   notification settings. Foreground banners use it instead of the
///   volume, because system alert volume is independent of output volume
///   and the volume read can be stale while our audio session is inactive.
struct NotificationSoundPolicy {
    let outputVolume: () -> Float
    let notificationSoundEnabled: () async -> Bool

    init(
        outputVolume: @escaping () -> Float = { AVAudioSession.sharedInstance().outputVolume },
        notificationSoundEnabled: @escaping () async -> Bool = {
            await UNUserNotificationCenter.current().notificationSettings().soundSetting == .enabled
        }
    ) {
        self.outputVolume = outputVolume
        self.notificationSoundEnabled = notificationSoundEnabled
    }

    static let system = Self()

    /// Whether a scheduled (system-presented) agent notification carries
    /// the default sound.
    func scheduledNotificationPlaysSound() -> Bool {
        outputIsAudible()
    }

    /// Whether a foreground banner plays the in-app chime. `requested` is
    /// whether the presentation options asked for sound.
    func foregroundBannerPlaysSound(requested: Bool) async -> Bool {
        guard requested else { return false }
        return await notificationSoundEnabled()
    }

    /// Whether a visionOS window emits its spatial notification sound.
    func windowSoundPlays() -> Bool {
        outputIsAudible()
    }

    /// Whether the global workspace attention cue plays.
    func attentionCuePlays() -> Bool {
        outputIsAudible()
    }

    private func outputIsAudible() -> Bool {
        outputVolume() > 0
    }
}
