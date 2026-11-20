# 0003. Push relay trust, device identity and link lifecycle

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The phone sends its APNs and Live Activity push tokens to the push relay. A machine starts the link: it names the relay in `push.createLink`. A hostile machine could name its own relay, collect the tokens, and push through the real relay. Links also change over time: the user forgets a machine, re-pairs it, or forgets it while a registration is still on the wire.

## Decision

1. **One trusted relay.**
   1. The phone sends tokens only to `https://push.intentapp.dev`. The URL must match exactly: no port, user, path, query or fragment (`isTrustedRelay(_:)`).
   2. On load, links saved before this check, or to any other relay, are dropped. No more tokens go there, and honest machines can link again.
   3. One phone talks to one relay. The first link picks it (`relayURL`).
2. **Device identity.**
   1. The phone has one P-256 key that stays on the device. It lives in the Secure Enclave when one exists. The Keychain holds the enclave's wrapped blob, or the software key on the Simulator.
   2. When the Keychain is locked (before first unlock), the app never replaces the key. A new key would look like a new device to the relay.
3. **Request proof.** Each request carries `Authorization: IntentProof <JWS>`: a compact ES256 JWS that binds the method, path, body hash, time and a single-use id (contract: `services/push-relay/README.md` in the monorepo). The public key is uncompressed X9.63 (65 bytes). The signature is raw `r‖s` (64 bytes).
4. **Wire format.**
   1. APNs tokens go to the relay as lowercase hex.
   2. `RelayDeviceInfo` leaves nil fields out, so one type serves the full registration body and a partial PATCH.
   3. The app sends a device PATCH only when the description changed since the relay last accepted it. Before the first link it sends nothing; the next registration carries the description.
   4. A `pushToken` of explicit `null` tells the relay that the activity ended.
5. **Link lifecycle.**
   1. The relay keys a link by daemon. A re-paired machine replaces its old link.
   2. Registrations and unlinks reach the relay one at a time (`serialized`). An unlink already on the wire cannot revoke the registration that replaced it.
   3. A machine forgotten while its link token is in flight is never registered. When a registration finishes after the user forgot the machine, the app queues an unlink, unless a newer link for that daemon exists.
   4. A forgotten link stays in `pendingUnlinks` until the relay confirms it is gone (HTTP 404 counts as gone). Re-pairing removes the entry, so the app never revokes the replacement.
   5. Only the newest activity's push token goes to the relay.
6. **Stored state.** `RelayLinkState` is JSON in `UserDefaults`. State saved before `pendingUnlinks` existed must still decode.

## Consequences

- A self-hosted relay is not possible without an app change.
- Removing a stored field needs a decode fallback, because old state stays on devices.

## Code

- `RelayLinkState`: `trustedRelayHost`, `isTrustedRelay(_:)`, `load(from:)`, `record(_:)`, `queueUnlink(connectionId:)`, `devicePatch(for:)`, the `Decodable` extension
- `RelayDeviceKey`: `loadOrCreate()`, `keychainUnavailable`
- `RelayProof`, `RelaySigner`, `RelayClient`, `RelayDeviceInfo`
- `PushRelayController`: `serialized(_:)`, `removedConnections`, `retryPendingUnlinks()`, `sendUnlink(_:)`, `activityEnded(id:)`
