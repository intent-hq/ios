# ADR-0181: QR, deep-link, and invite pairing

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `QRScannerSessionState`, `QRScannerDeduplicator`, `QRScannerView` (`Intent/Views/Onboarding/QRScannerView.swift`), `QRScannerGeometry` (`Intent/Views/Onboarding/QRScannerOverlay.swift`), `DeepLinkPairingView` (`Intent/Views/Onboarding/DeepLinkPairingView.swift`), `InviteJoinView` (`Intent/Views/Onboarding/InviteJoinView.swift`)

## Decisions

### 1. Every QR and deep-link pairing is pinned

Applies to: `QRScannerView`, `DeepLinkPairingView.startPairing()`

Both paths use `PairingFlow`. A payload fingerprint is pinned directly. Without
one, `PairingFlow` probes the server certificate, as manual entry does, and the
user must trust it before the app connects pinned over wss. Every QR pairing
path reaches `connect(payload:certFingerprint:)` with a non-nil fingerprint
(from the payload or the trust-confirmed probe), so pairing never falls back to
plain ws://.

### 2. Deep links need explicit confirmation

Applies to: `DeepLinkPairingView`

`DeepLinkPairingView` is the confirmation surface for `intent://pair` deep links.
With the in-app QR scan, the user deliberately pointed the camera at their own
desktop app. A deep link can be triggered by any web page, so the target hosts
and port are shown and the user must confirm before any connection is
attempted. The security semantics match QR pairing exactly.

### 3. A dismissed pairing cannot complete

Applies to: `DeepLinkPairingView.pairingTask`

The in-flight probe or connect task is cancelled when the sheet goes away, so a
dismissed pairing cannot complete (and persist and navigate) afterwards.

### 4. Scanner state is a pure state machine

Applies to: `QRScannerSessionState`

The state machine (idle → validating → fingerprint confirmation or error)
removes invalid combinations of Booleans and optionals, and keeps the scan,
probe, and trust transitions unit-testable without VisionKit camera hardware.

### 5. Repeated scans are suppressed for a cooldown

Applies to: `QRScannerDeduplicator`, the scanner coordinator's `process(_:)`

Consecutive scans of the same barcode are suppressed until the cooldown
expires. Scanning re-arms after `Constants.QRScanner.duplicateScanResetDelay`
(3 seconds) so the same code can be scanned again.

### 6. Scanner guidance is drawn in SwiftUI

Applies to: `QRScannerView` (`DataScannerViewController` set-up), `QRScannerGeometry`

VisionKit cannot relocate its native guidance, so `isGuidanceEnabled` is false
and the scan instructions live in the SwiftUI overlay, below the description and
outside the scan window. All guide elements derive their coordinates during
layout, including the first frame.

### 7. visionOS keeps the same scanner API

Applies to: `QRScannerView` (visionOS)

`DataScannerViewController` (VisionKit live camera scanning) is unavailable on
visionOS. The visionOS `QRScannerView` keeps the same API so call sites compile,
and directs the user to manual token entry. Its `onPaired` is unused; it exists
so call sites pass the same arguments as on iOS.

### 8. Invite links accept and prove nothing until Join

Applies to: `InviteJoinView`

`InviteJoinView` is the sheet for an `intent://invite` link: someone shared a
workspace with this person. Until the person taps Join, the flow only reads from
the host: the invite's preview and, when the person must prove an identity, a
challenge (`invite.inspect`, then `invite.challenge` on the proof path), plus
the forge account on the person's own Mac. It accepts no credential and
publishes no proof before Join. The flow is in `InviteJoinModel`
(`Intent/Services/InviteJoinFlow.swift`).
