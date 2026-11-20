import AVFAudio
import UserNotifications

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

    func scheduledNotificationPlaysSound() -> Bool {
        outputIsAudible()
    }

    func foregroundBannerPlaysSound(requested: Bool) async -> Bool {
        guard requested else { return false }
        return await notificationSoundEnabled()
    }

    func windowSoundPlays() -> Bool {
        outputIsAudible()
    }

    func attentionCuePlays() -> Bool {
        outputIsAudible()
    }

    private func outputIsAudible() -> Bool {
        outputVolume() > 0
    }
}
