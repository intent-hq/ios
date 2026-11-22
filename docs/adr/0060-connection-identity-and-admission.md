# ADR-0060: Connection authority comes only from the admitted socket

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConnectionAdmission`, `PairingConnectionContext` (`Intent/Services/ConnectionAdmission.swift`),
  `ConnectionPrincipal`, `PairingClientIdentity` (`Intent/Services/ConnectionPrincipal.swift`),
  `ConnectionCapabilities`, `ConnectionHandshake` (`Intent/Services/ConnectionCapabilities.swift`),
  `AuthorityRefresh`, `ConnectionManager` identity extension, `PersistenceManager.recordAuthoritativeRevocation`
  (`Intent/Services/ConnectionManagerIdentity.swift`)

## Context

A connection is admitted for one person (principal) with one host role. The
app saves connections for reconnects, and membership can change while a socket
is open. The code must never act on stale or borrowed authority.

## Decisions

### 1. Current authority comes only from the admitted socket

Applies to: `ConnectionPrincipal`, `ConnectionManager.validateIdentity(_:token:fingerprint:)`

Saved copies of a principal are classification and provenance for persistence.
They are never permission to act offline. A saved record can constrain
identity, but it never supplies current authority.

### 2. An admission is a receipt for one socket

Applies to: `ConnectionAdmission`

`ConnectionAdmission` is the identity actually admitted on one socket.
Reconnect-cache updates do not change this receipt, and they do not attribute
an old socket's revocation to a new token.

### 3. A pairing owns its connection across automatic recovery

Applies to: `PairingConnectionContext`

A pairing owns its connection across automatic transport recovery, until an
explicit replacement connect or disconnect takes over. Socket admission stays
separate, because every replacement socket must recheck authority.

### 4. Capabilities are a per-socket snapshot

Applies to: `ConnectionCapabilities`, `ConnectionHandshake`

Capabilities come from the admitted socket's hello. They are never persisted
with a saved host or person. `ConnectionHandshake` carries identity and
capabilities from the same candidate, before the socket is adopted.

1. `collaborationIdentity: 1` (§5.49) is the separate `identity.*` sign-in.
2. Protocol 10.8 added GitLab identity proofs (`sourceControl.identityProof.*`).
   `supportsIdentitySeam` checks for it.
3. `supportsScriptMonitors` is gated only on the advertised capabilities, never
   on a protocol-version maximum. The protocol major moves for unrelated
   changes (protocol 15 hid monitors, intent-hq/intent#7206). A breaking change
   to these methods changes the capability values instead.

### 5. JSON booleans and numbers are told apart by CFBoolean identity

Applies to: `ConnectionPrincipal.number(_:)`, `ConnectionPrincipal.boolean(_:)`

`NSNumber` keeps the `CFBoolean` identity, so a JSON boolean is never read as
a number and a numeric value is never read as a boolean.

### 6. One installation ID per install

Applies to: `PairingClientIdentity`

One local installation ID is shared by all windows and hosts, independent of
every person's bearer token. The server's principal-prefixed echo of the ID is
never persisted.

### 7. Membership events invalidate first, then refresh with fences

Applies to: `AuthorityRefresh`, `ConnectionManager.invalidatePrincipalIfNeeded(method:params:)`

A membership event invalidates the principal first. A newer notification
cancels a running refresh. Generation and socket fences stop a late reply from
reviving rights. `AuthorityRefresh` holds the request task and the principal it
must keep. That principal fences a later event while `currentPrincipal` is
cleared.

### 8. Only an authoritative rejection removes a saved credential

Applies to: `PersistenceManager.recordAuthoritativeRevocation(_:observed:)`

Only the exact credential generation that an authoritative RPC rejected can
create a removal. Network, Keychain and TLS failures are not revocation.
