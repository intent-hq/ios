# ADR-0180: Manual pairing entry and pairing screen layout

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ManualConnectionInput`, `ManualTokenEntryView` (`Intent/Views/Onboarding/ManualTokenEntryView.swift`), `ManualTokenTextField` (`Intent/Views/Onboarding/ManualTokenTextField.swift`), `ManualConnectionField` (`Intent/Views/Onboarding/ManualConnectionField.swift`), `ManualConnectionSubmitButton` (`Intent/Views/Onboarding/ManualConnectionSubmitButton.swift`), `IPadPairingDetail` (`Intent/Views/Onboarding/IPadPairingDetail.swift`), `PairingOption`, `PairingHeaderLayout`, `PairingTextMetrics` (`Intent/Views/Onboarding/PairingView.swift`)
- Related issues: ios#233

## Decisions

### 1. Host input is a direct host or a Tailcat blob

Applies to: `ManualConnectionInput`

The manual-entry "Host / Tailcat Address" input is classified as a direct
host or IP, dialed as before, or a Tailcat connection blob dialed via
TailcatKit. Pinned tailcat v0.4.0 encodes blobs as lowercase `tc` followed by
unpadded base64url-encoded CBOR. Classification only recognizes the expected
prefix, base64, and CBOR-header shape. The tunnel dial is the authoritative
validation of the decoded contents: TailcatKit validates the decoded fields,
and the dial reports invalid or unreachable addresses.

v0.4.0's `wireConnInfo` emits a map of 1–4 entries whose first, required field
is `p`, a 32-byte server public key. Requiring that structure stops short legal
DNS labels such as `tcoA` (an empty CBOR map) from being mistaken for
connection blobs.

### 2. Hosts and tunnel address to race and persist

Applies to: `ManualConnectionInput.hosts`, `ManualConnectionInput.tcAddress`

`hosts` is empty for a tunnel-only target; the post-connect route refresh
fills in the daemon-reported IPs. `tcAddress` is persisted on the paired server
so reconnects race the tunnel route too.

### 3. The confirmed target is captured with its fingerprint

Applies to: `ManualTokenEntryView.probedInput`

The classified target whose fingerprint was probed is captured with
`probedFingerprint`, so the confirmation alert connects to exactly the target
the user confirmed, never a re-classification of a field that may have been
edited.

### 4. Never connect unpinned; cancelled probes are dropped

Applies to: `ManualTokenEntryView` (connect action)

Without a probed certificate there is no way to verify the server's identity,
so the view never connects unpinned. The error message names the stage the
probe failed at (ios#233). If the user taps Cancel while the probe is in
flight, a cancelled direct probe arrives as `.cancelled` (the tunnel branch
handles its thrown cancellation separately). Processing it would show a
spurious certificate error or overwrite a newer attempt's state, so the result
is dropped.

### 5. Errors are announced

Applies to: `ManualTokenEntryView.showError(_:)`, `ManualTokenEntryView.hostAccessibilityLabel`

A validation or connection failure is also spoken, because VoiceOver focus stays
on the Connect button and would not otherwise reach the new text. The host
field's VoiceOver name matches the visible field label, not the example
placeholder.

### 6. Connect and save own their own errors

Applies to: `ManualTokenEntryView.connectAndSave`

Each phase owns only its own errors; the view handles presentation for either
failure.

### 7. Presenting context

Applies to: `ManualTokenEntryView.onPaired`, `QRScannerView.onPaired`, `IPadPairingDetail`

When `onPaired` is set, pairing success is reported to the presenting context
instead of the first-run coordinator flow. On iPad, a temporary pairing
connection leaves the window's current backend untouched until pairing
succeeds. Cancel only removes the detail overlay.

### 8. Token field keeps one editor

Applies to: `ManualTokenTextField`

The same editor and first responder stay in place when the token is shown or
hidden. UIKit owns tap focus: a SwiftUI `FocusState` with no registered token
target can reset to nil and immediately undo `becomeFirstResponder`. When
visibility toggles, the secure-entry storage is refreshed so the next keystroke
appends instead of replacing the existing draft; the keyboard and selection
stay.

### 9. Shared form pieces

Applies to: `ManualConnectionField`, `ManualConnectionSubmitButton`

`ManualConnectionField` is a label and a growing native editor surface, never a
fixed-height text clip. The shared submit action shows whether validation is
running and stays cancellable.

### 10. Paste and visibility buttons

Applies to: `ManualTokenEntryView.pasteTokenButton`, the token visibility button

In dark mode the paste glyph uses `.original` rendering, because the exact
export already has 30% white strokes. The view keeps a visible light paste
affordance rather than Figma's white-on-white export. The visibility button's
trailing hit region expands inward and keeps the reference's 24pt glyph inset.

### 11. No live QR scanning on visionOS

Applies to: `PairingOption`, `PairingOption.platformSupportsCameraScanning`

visionOS exposes no camera to third-party apps, so live QR scanning is not a
viable path there and is excluded from the pairing options.

### 12. Pairing screen layout follows Figma's text edges

Applies to: `PairingView`, `PairingHeaderLayout`, `PairingTextMetrics`

Equal outer safe margins center on the full container, not the asymmetric safe
area, and the same protected region gates scrolling. Figma spaces the header
from cap top to last baseline, not native line-box edges, so
`PairingHeaderLayout` measures real multiline baselines without clipping or
fixing the text height. `bodyLineHeightRatio` (1.32) comes from the Figma
Connect description. Inter Regular and Medium share vertical metrics, and
native line boxes already contribute `bodyNativeLeading` whitespace to the
title/subtitle gap between visible caps.
