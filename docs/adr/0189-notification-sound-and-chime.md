# ADR-0189: Notification sound policy and the synthesized chime

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `NotificationSoundPolicy` (`Intent/Utils/NotificationSoundPolicy.swift`),
  `NotificationChime` (`Intent/Utils/NotificationChime.swift`),
  `LocalNotificationService` (`Intent/Utils/LocalNotificationService.swift`),
  `HapticManager` (`Intent/Utils/HapticManager.swift`)

## Decisions

### 1. One owner decides whether a sound plays

Applies to: `NotificationSoundPolicy`

`NotificationSoundPolicy` is the one owner of every "should this notification or
attention sound play" decision. Call sites ask it instead of reading the output
volume or notification settings themselves, so a change to sound behavior is
made, and tested, here. It has two inputs, both injectable for tests:

- `outputVolume`: the device output volume. Scheduled notifications, the
  visionOS window sound and the attention cue stay silent at zero.
- `notificationSoundEnabled`: whether sound is enabled for this app in
  notification settings. Foreground banners use it instead of the volume,
  because system alert volume is independent of output volume and the volume
  read can be stale while our audio session is inactive.

### 2. Foreground banners play the app's own chime without waiting

Applies to: `LocalNotificationService.deliverForegroundNotification(_:completionHandler:)`

For a foreground banner the app removes `.sound` from the presentation options
and plays its own chime instead of the system sound. The banner is presented
without waiting for the chime.

### 3. Authorization triggers remote registration

Applies to: `LocalNotificationService.onAuthorized`

`onAuthorized` runs once alerts are allowed, so the app can register for remote
alerts.

### 4. The chime is synthesized and cached

Applies to: `NotificationChime`, `NotificationChime.chimeSamples()`

The agent-notification chime is synthesized as a WAV file on disk. visionOS
emits the notification sound from the source window's scene through RealityKit
(`WindowFeedbackSoundEmitter`), which needs a loadable audio file, and the bundle
ships no audio assets. The chime (two decaying sine tones) is generated once and
cached in the temporary directory. The tones are a quiet C5/E5 pair with rounded
attacks and a fade to silence.

### 5. visionOS keeps the haptics API as no-ops

Applies to: `HapticManager` (visionOS branch)

visionOS has no haptics hardware and marks the `UIFeedbackGenerator` family
unavailable, so `HapticManager` keeps the same call-site API as no-ops. The
nested enums mirror the UIKit case names used by call sites, so dot shorthand
still compiles.
