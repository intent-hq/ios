# 0047. Pairing entry points: deep link, QR, manual entry and invites

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

A device can pair from an `intent://pair` deep link, a QR scan, manual entry (host or Tailcat address plus token), or join from an `intent://invite` link. ADR 0014 owns certificate pinning and the probe; ADR 0050 owns how pairings are saved. This record covers the entry-point screens.

## Decision

1. **Same pinning everywhere.** Every entry point uses `PairingFlow` rules. A payload fingerprint is pinned directly. Without one, the server certificate is probed and the user must trust it before a pinned WSS connect. There is never a plain `ws://` path. Without a probed certificate the app never connects; the error names the stage where the probe failed (ios#233).
2. **Deep links need consent.** Any web page can trigger `intent://pair`, unlike a QR scan the user aimed at their own desktop. `DeepLinkPairingView` shows the target hosts and port, and connects only after the user confirms.
3. **Invites.** Before the person taps Join, `InviteJoinModel` only reads: `invite.inspect`, `invite.challenge` on the proof path, and the account on the person's Mac. It accepts the invite or publishes and sends an identity proof only after confirmation.
4. **Cancellation.** An in-flight probe or connect task is cancelled when its sheet goes away or the user taps Cancel. A dismissed pairing never completes, saves or navigates. A cancelled probe result is dropped, so it never shows a false certificate error or overwrites a newer attempt.
5. **Manual entry input.**
   1. `ManualConnectionInput.classify(_:)` treats input as a Tailcat address only when it is lowercase `tc` followed by unpadded base64url CBOR (tailcat v0.4.0). The decoded value must start with a 1–4 entry CBOR map whose first field is `p`, a 32-byte server public key. This keeps short DNS labels such as `tcoA` (an empty CBOR map) as hosts.
   2. Classification checks only shape. TailcatKit validates the decoded fields, and the dial reports invalid or unreachable addresses. A Tailcat address pasted into the wrong field fails fast before the dialer.
   3. A tunnel-only target has no direct hosts. The post-connect route refresh fills in daemon-reported IPs. The `tcAddress` is saved, so reconnects race the tunnel route too.
   4. The trust confirmation connects to the exact input that was probed (`probedInput`), never a re-classification of a field the user may have edited.
   5. A validation or connection error is also announced, because VoiceOver focus stays on the Connect button.
   6. `connectAndSave`: each phase owns only its own errors; the view presents either failure.
6. **Token field.**
   1. The field keeps the same editor and first responder when the token is shown or hidden.
   2. UIKit owns tap focus. A SwiftUI `FocusState` without a registered target can reset to nil and undo `becomeFirstResponder`.
   3. After a secure-entry toggle, the first responder's text is cleared and reinserted, so the next keystroke appends instead of replacing the draft. The keyboard and selection stay.
7. **QR scanning.**
   1. visionOS gives third-party apps no camera, so `PairingOption` hides QR scanning there. The visionOS `QRScannerView` keeps the iOS API, including an unused `onPaired`, so call sites compile, and points the user to manual entry.
   2. `QRScannerSessionState` is a pure state machine (idle → validating → fingerprint confirmation or error), testable without VisionKit.
   3. `QRScannerDeduplicator` ignores repeat scans of the same barcode until its cooldown ends.
   4. VisionKit cannot move its native guidance, so it is off. The overlay draws the instructions below the description, outside the scan window.
8. **Naming a new pairing.** `ConnectionPairing.displayName(fromHostStatus:shared:)` names the connection from `host.status`: the trimmed `prettyHostname` (older daemons omit it), else `hostname`, else the caller uses host:port. Shared connections prefer `collaborationName`. The pairing is saved (upsert) and marked active. If the saved-connections data cannot be read, the new pairing is not written over it (`registryUndecodable`, intent-hq/ios#265).
9. **iPad pairing.** A temporary pairing connection leaves the window's backend untouched until pairing succeeds. Cancel only removes the pairing detail.
10. **Saved connections.** The connections sheet re-merges registry changes synced from other devices when it opens (`refreshSyncedBackends()`). The "connected" badge and delete warnings are scoped to this window's bound connection (ADR 0070). "Open in New Window" appears only where `supportsMultipleWindows` is true (iPad, visionOS). `SavedConnectionDetails` never renders the saved API token or certificate fingerprint.
11. **Screens.** When `onPaired` is set, success goes to the presenting context instead of the first-run coordinator flow. The manual paste control keeps a visible light affordance instead of Figma's white-on-white export.

## Code

- `DeepLinkPairingView`, `InviteJoinView`, `IPadPairingDetail`
- `ManualConnectionInput`: `classify(_:)`, `hosts`, `tcAddress`
- `ManualTokenEntryView`: `probedInput`, `showError(_:)`, `connectAndSave`
- `ManualTokenTextField`
- `PairingOption`: `platformSupportsCameraScanning`, `available`
- `QRScannerView`, `QRScannerSessionState`, `QRScannerDeduplicator`, `QRCameraPreview`
- `ConnectionsView`, `SavedConnectionDetails`
- `ConnectionPairing`: `displayName(fromHostStatus:shared:)`, `registryUndecodable`
