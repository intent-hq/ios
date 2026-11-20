# ADR-0611: Pairing always connects pinned over wss

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `PairingFlow` (`Intent/Services/PairingFlow.swift`), `PairingDiagnostics` (`Intent/Services/PairingDiagnostics.swift`)

## Context

`PairingFlow` is the shared pairing-connection flow for QR scans
(`QRScannerView`) and `intent://pair` deep links (`DeepLinkPairingView`).

## Decisions

### 1. There is never a plain-ws fallback

Applies to: `PairingFlow`, `PairingFlow.connect(payload:certFingerprint:connectionManager:persistence:diagnostics:)`

Pairing connections are always pinned over wss. A payload fingerprint is pinned
directly. A missing fingerprint is resolved by probing the server certificate
and asking the user to trust it. A failed probe aborts. Every pairing path
reaches `connect` with a non-nil fingerprint (from the payload or the
trust-confirmed probe), so pairing can never fall back to plain `ws://`.
`connect` persists the pairing through `ConnectionPairing.finalize`.

### 2. Fingerprint resolution outcomes

Applies to: `PairingFlow.FingerprintResolution`, `PairingFlow.resolveFingerprint(for:diagnostics:probe:)`

1. `failed`: no payload fingerprint and the probe failed, so pairing aborts.
   The message names the stage the probe failed at (unreachable, timeout, TLS
   handshake, no certificate).
2. `needsUserConfirmation`: the payload carried no fingerprint. The server
   certificate was probed, and the user must confirm trust before connecting
   pinned.
3. `pinned`: the payload carried a fingerprint, so the flow connects pinned at
   once.
4. `probe` is injectable for tests. The default runs the real TLS probe across
   the payload's hosts.

### 3. Pairing dials the window's own connection

Applies to: `PairingFlow.connect(...)`

`connectionManager` is the window session's own connection. In window model v2
there is no default session, so the pairing dials the connection that the
presenting window will keep using.

### 4. A cancelled pairing is not persisted

Applies to: `PairingFlow.connect(...)`

A cancelled pairing (for example, the deep-link sheet dismissed mid-flight)
must not be persisted when the connect happens to complete first. The
just-established authenticated socket must not be left dangling with no UI
reflecting it, so the attempt is disconnected.

### 5. Save failures belong to the persistence task

Applies to: `PairingFlow.connect(...)`

The persistence task owns the save failure. The diagnostic recorded on a save
error is phase context only.

### 6. Scanner diagnostics take closed values only

Applies to: `PairingDiagnostics.scanner(_:failure:store:)`

The scanner diagnostic receives closed capability and failure values, not
camera errors or QR text.
