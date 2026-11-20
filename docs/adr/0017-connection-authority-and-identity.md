# 0017. Connection authority and identity

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

A daemon admits a socket for a person (principal) with capabilities. Saved connection records, reconnects, credential imports and membership changes all touch identity. A wrong rule here can grant rights offline or revoke a good token.

## Decision

1. **Authority comes from the admitted socket.**
   1. `ConnectionPrincipal` authority comes only from the admitted socket. Saved copies are classification and provenance for persistence, never permission to act offline.
   2. `validateIdentity(_:token:fingerprint:)`: a saved record can constrain identity, never supply current authority.
   3. `ConnectionAdmission` is the identity admitted on one socket. Reconnect-cache updates do not change it, and an old socket's revocation is never attributed to a new token.
   4. `ConnectionCapabilities` is a snapshot from the admitted socket's hello. It is never persisted with a saved host or person.
   5. `ConnectionHandshake` carries identity and capabilities from the same candidate, before socket adoption.
2. **Pairing context.** A pairing owns its connection across automatic transport recovery, until an explicit connect or disconnect replaces it (`PairingConnectionContext`). Every replacement socket still rechecks authority.
3. **Membership and revocation.**
   1. Membership events invalidate the principal first. A newer notification cancels the refresh. Generation and socket fences stop a late reply from reviving rights.
   2. `AuthorityRefresh` keeps the principal it must restore. It fences a later event while `currentPrincipal` is cleared.
   3. `recordAuthoritativeRevocation(_:observed:)`: only the exact credential generation that an authoritative RPC rejected can create a removal. Network, Keychain and TLS failures are not revocation.
4. **Capability gates.** `supportsScriptMonitors` depends only on advertised capabilities, never on a maximum protocol version. The protocol major moves for unrelated changes (protocol 15 hid monitors, intent-hq/intent#7206). A breaking change to these methods changes the capability values.
5. **Installation identity.** `PairingClientIdentity` is one local installation id shared by all windows and hosts, independent of any person's bearer. The server's principal-prefixed echo is never persisted.
6. **Strict JSON booleans.** `ConnectionPrincipal` decodes booleans and numbers through `NSNumber` and checks `CFBoolean` identity, so a JSON boolean is never read as a number and a number is never read as a boolean.
7. **Startup status.** `DaemonStartupStatus` is owner-only. A snapshot describes work, never admission or authority.
8. **Diagnostics context.** `DiagnosticConnectContext` is a closed enum given by the caller. It is never inferred from credentials or backend ids. Unannotated entry points stay unknown.

## Consequences

- An offline app shows saved people but cannot act for them.

## Code

- `ConnectionPrincipal`, `PairingClientIdentity`, `ConnectionAdmission`, `PairingConnectionContext`, `ConnectionCapabilities`: `supportsScriptMonitors`, `ConnectionHandshake`, `DiagnosticConnectContext`
- `ConnectionManager` (identity): `validateIdentity(_:token:fingerprint:)`, `invalidatePrincipalIfNeeded(method:params:)`, `refreshPrincipal(after:previous:)`, `recordAuthoritativeRevocation(_:observed:)`, `AuthorityRefresh`
