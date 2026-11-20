# ADR-1316: Push relay linking, device identity and request proofs

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `PushRelayController` (`Intent/LiveActivity/Relay/PushRelayController.swift`),
  `RelayDeviceInfo`, `RelayClient` (`Intent/LiveActivity/Relay/RelayClient.swift`),
  `RelayDeviceKey` (`Intent/LiveActivity/Relay/RelayDeviceKey.swift`),
  `RelayLink`, `RelayLinkState` (`Intent/LiveActivity/Relay/RelayLinkState.swift`),
  `RelaySigner`, `RelayProof` (`Intent/LiveActivity/Relay/RelayProof.swift`)

## Context

A connected machine can link this phone to the push relay. The relay then sends
agent alerts as remote notifications and drives the Live Activity. The phone
signs every relay request with a device key, and must never send its push tokens
to an untrusted relay.

## Decisions

### 1. The controller keeps the relay's copy of the device current

Applies to: `PushRelayController`, `PushRelayController.start()`,
`PushRelayController.deliversAlerts(for:)`

`PushRelayController` links each connected machine to the push relay and keeps
the relay's copy of this device current: APNs tokens, Live Activity tokens and
the Live Activities switch. With any machine linked, the relay drives the Live
Activity and `AgentLiveActivityController` stands down (D7). `start()` starts
the token streams and launch work; call it once at app launch.

A linked machine's agent alerts come from the relay as remote notifications, so
the app does not post its own for that machine.

### 2. Link bookkeeping

Applies to: `PushRelayController.declined`, `removedConnections`, `relayOperations`, `liveActivity`

- `declined`: machines that could not link; cleared each time the app becomes
  active.
- `removedConnections`: machines forgotten this run; a registration that
  finishes later is undone.
- `relayOperations`: the tail of the relay registration and unlink chain.
- `liveActivity`: the Live Activity whose push token the relay holds. When an
  activity ends, the token is cleared only if it is still that activity, because
  a newer activity may already hold the relay's token.

### 3. Registration races with forgetting a machine

Applies to: `PushRelayController.link(_:over:)`

If a machine is forgotten while the link token is in flight, the link is never
registered. If it is forgotten after registration, the new link is queued for
unlink, unless a current link for the same daemon exists: that is a newer
generation and is left alone.

### 4. Registrations and unlinks are serialized

Applies to: `PushRelayController.serialized(_:)`, `retryPendingUnlinks()`, `sendUnlink(_:)`

Registrations and unlinks reach the relay one at a time, so an unlink already on
the wire cannot revoke the registration that replaced it. Each forgotten link
stays queued until the relay confirms it is gone. Re-pairing removes the queued
entry, so an unlink never revokes the replacement. A 404 from the relay means the
link is already gone and counts as confirmed.

### 5. The relay snapshot updates a stale card

Applies to: `PushRelayController.applySnapshot()`

The relay's content can be ahead of a stale card while the app was closed, so the
app shows it at once when it becomes active. When nothing runs, the app clears a
card that the relay's end push did not remove.

### 6. ActivityKit streams stay off the main actor

Applies to: `PushRelayController` static ActivityKit helpers

Activities are not `Sendable`. Each helper iterates off the main actor and hands
back only ids and token bytes.

### 7. Token and device encoding

Applies to: `Data.hexString`, `RelayDeviceInfo`, `RelayClient.setLiveActivityToken(_:)`, `ActivityTokenBody`

APNs tokens go to the relay as lowercase hex. `RelayDeviceInfo` is `device` in
the relay contract. Nil fields are left out, so the same type serves the full
registration body and a partial PATCH. `RelayClient` makes the device-side calls
to the push relay, and every request carries a fresh proof. A nil Live Activity
token tells the relay the activity ended; `ActivityTokenBody` encodes
`pushToken` as an explicit null in that case.

### 8. One device key, kept on the device

Applies to: `RelayDeviceKey`, `RelayDeviceKey.LoadError.keychainUnavailable`

The phone's push relay identity is one P-256 key kept on this device only. It
lives in the Secure Enclave when there is one. The Keychain holds the enclave's
wrapped blob, or the software key on the Simulator. When the Keychain is locked
(before first unlock), the key is never replaced, or the relay would see a new
device.

### 9. Request proofs

Applies to: `RelaySigner`, `RelayProof`

Requests are signed with an ES256 key whose public half identifies the device.
`publicKeyX963` is the uncompressed X9.63 P-256 public key (65 bytes). `sign`
returns an ECDSA P-256 / SHA-256 signature as raw r‖s (64 bytes). `RelayProof`
builds the `Authorization: IntentProof <JWS>` value from the relay contract
(`services/push-relay/README.md`): a compact JWS that binds method, path, body
hash, time and a single-use id.

### 10. Link state and the trusted relay

Applies to: `RelayLink.connectionId`, `RelayLinkState`, `RelayLinkState.trustedRelayHost`,
`RelayLinkState.load(from:)`, `RelayLinkState.init(from:)`

`RelayLinkState` is what the phone knows about its relay registration and the
decisions that follow from it. It is persisted as JSON in `UserDefaults`.
`RelayLink.connectionId` is the phone-local `StoredConnection.id` for the
machine.

`push.intentapp.dev` is the only relay the phone sends its push tokens to. A
machine names the relay in `push.createLink`, so any other origin is refused: a
hostile machine could otherwise collect the tokens and push through the real
relay. Links saved before the relay check, or to any other relay, are dropped on
load, so no further tokens go there and honest machines can link again. State
saved before `pendingUnlinks` existed still decodes.

### 11. Link state rules

Applies to: `sentDevice`, `pendingUnlinks`, `isRelayDriven`, `relayURL`, `shouldLink(...)`,
`devicePatch(for:)`, `record(_:)`, `queueUnlink(connectionId:)`

- `sentDevice` is the device description the relay last accepted; nil before
  the first link. `devicePatch` returns nil when the relay already has the
  description, or when no machine is linked yet, because the next registration
  carries it.
- `pendingUnlinks` holds forgotten machines whose relay link is not confirmed
  gone yet. A forgotten machine's link stops being used and stays queued until
  the relay confirms the unlink.
- With any machine linked, the relay owns the Live Activity and the app stops
  writing it (`isRelayDriven`).
- One phone talks to one relay: the first link picks it (`relayURL`).
- A connected machine is linked once, while Live Activities are on. Machines
  that could not link (an older intentd) are not asked again this run.
- The relay keys a link by daemon, so a re-paired machine replaces its old link.
