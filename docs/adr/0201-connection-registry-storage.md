# ADR-0201: The connection registry keeps saved daemons in one Keychain blob and never treats a failed read as empty

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `PersistenceManager` (`Intent/PersistenceManager.swift`),
  `ConnectionRegistryReadError`, `ConnectionRegistryReadResult`
  (`Intent/ConnectionRegistryReadResult.swift`), `KeychainStorage`
  (`Intent/PersistenceKeychainStorage.swift`), `PairedServer`, `StoredConnection`
  (`Intent/Models.swift`)
- Related issues: ios#341

## Context

`PersistenceManager` stores every paired daemon as a `StoredConnection` in one
JSON blob in the Keychain. Non-secret state lives in `UserDefaults`. Pairing,
re-pairing, the post-connect route refresh, and iCloud sync all write to the
same list, so the list must not lose records or grow duplicates.

## Decisions

### 1. Storage backends are injected so tests stay hermetic

Applies to: `PersistenceManager.defaults`, `PersistenceManager.keychainStorage`,
`KeychainStorage`

`defaults` holds non-secret values. Tests inject a private suite so persisted
state (navigation, drafts, active connection id) cannot leak between tests or
into the real app container.

`keychainStorage` holds Keychain values. `KeychainStorage` exists so tests can
run hermetically: tests substitute an in-memory implementation because SecItem
calls fail in headless CI simulators.

### 2. Only the shared instance publishes to production sync

Applies to: `PersistenceManager.backendPublisher`, `PersistenceManager.shared`

Publication is an explicit opt-in. Custom, test, and ephemeral stores never
publish through a production writer. Only `shared` installs a publisher outside
the test host.

### 3. A failed registry read is never a write baseline

Applies to: `ConnectionRegistryReadResult.connections`,
`PersistenceManager.loadConnectionsWithOutcome()`,
`PersistenceManager.loadConnections()`

`missing` is a known empty baseline. `failed` returns `nil`, so no caller can
write a new list on top of a read that failed. Use
`loadConnectionsWithOutcome()` at storage entry and retry boundaries. Do not
treat a failed compatibility `loadConnections()` read as an ordinary empty
list.

### 4. Read errors carry safe categories only

Applies to: `ConnectionRegistryReadError`

The error cases never carry credential bytes or decoder diagnostics.

### 5. Change notifications follow successful saves only

Applies to: `PersistenceManager.connectionsDidChange`

The publisher fires only after a saved connection mutation succeeds. Window
labels observe their own record, independently of the last-used pointer.

### 6. Upsert matches a re-pair by fingerprint, host overlap, or tunnel address

Applies to: `PersistenceManager.upsertConnection(_:)`,
`PersistenceManager.upsertConnectionWithOutcome(_:)`,
`PersistenceManager.matchesPairing(_:incoming:)`

`upsertConnection` inserts the connection, or updates the existing entry in
place and keeps its id. An entry matches when its certificate fingerprint
matches, or when it has the same port and shares at least one host or the
tailcat tunnel address. It returns the stored value.

Host overlap, not set equality, is the match key. The post-connect route
refresh grows stored host sets over time. A re-pair of the same daemon through
one manually entered host, or a QR payload with a different host list, must
still update the grown record in place instead of inserting a duplicate.

A matching `tcAddress` is an equally valid identity. A manual tunnel-only
re-pair carries no hosts at all, so its host set is disjoint with every record.
Without this key each re-pair of the same tunnel address would insert a
duplicate record.

Callers that publish pairing success must use `upsertConnectionWithOutcome`,
which reports whether the resulting registry was durably saved.

### 7. A re-pair never drops known routes

Applies to: `PersistenceManager.upsertConnectionWithOutcome(_:)`,
`PersistenceManager.mergeHostLists(existing:incoming:)`

On a match, the existing hosts keep their order and are never dropped. Incoming
hosts that are not already present are appended. Hosts are deduplicated
case-insensitively, because DNS names and IPv6 hex are case-insensitive
(ios#341). The first spelling seen is kept.

A re-pair without a tunnel address (manual entry, or a QR code from a daemon
whose tunnel is down) must not drop the known `tcAddress`. The post-connect
refresh keeps it current.

On a match, the stored `syncUpdatedAt` keeps the last observed clock. A
deliberate local pairing gets its own pending edit clock before the atomic
save.

### 8. Field updates by id never insert records

Applies to: `PersistenceManager.updateConnectionHosts(id:hosts:)`,
`PersistenceManager.updateConnectionTcAddress(id:tcAddress:)`,
`PersistenceManager.updateConnectionDisplayName(id:displayName:)`

Each method replaces one field of the connection with the given id and keeps
the record identity. Each is a no-op when the id is unknown.
`updateConnectionHosts` exists because `upsertConnection` matches by host set
and port and could treat a grown host set as a new pairing; this method never
inserts or duplicates records.

The post-connect refresh calls `updateConnectionTcAddress` when `system.status`
reports a `tcAddress`. It calls `updateConnectionDisplayName` so records saved
before the daemon reported a pretty hostname heal on the next successful
connect.

### 9. The active connection id is only a last-used pointer

Applies to: `PersistenceManager.activeConnection()`,
`PersistenceManager.lastUsedConnection()`

Since window model v2 the pointer is no longer a navigation concept. It only
seeds which backend a fresh window binds to at launch. When system restoration
supplies no backend, a fresh window binds to the last-used pointer when its
record still exists, else to the most recently connected saved record.

### 10. Synced backend merge is one atomic pass and never disconnects on a failed save

Applies to: `PersistenceManager.mergeSyncedBackends(records:)`

The method merges the iCloud-synced backend registry's per-key winners,
including tombstones, into the saved connections in one atomic pass under the
persistence lock. `SyncedBackendConnectionMerge` holds the merge rules. A
tombstone that removes the active connection also clears the active pointer,
and the outcome flags it so the caller can disconnect or route away. A failed
Keychain write reports a no-op outcome and leaves the pointer untouched, so the
caller never disconnects while the saved list still holds the connection. The
merge retries on the next registry read.

### 11. The legacy single pairing is migrated once, and only after a positive "missing" read

Applies to: `PersistenceManager.migrateLegacyPairingIfNeeded()`,
`PersistenceManager.clearPairing()`

The legacy single pairing (Keychain `serverInfo` plus `apiToken`, or the even
older `UserDefaults` key `pairedServer`) moves into the connections list one
time. Migration runs only after the registry was positively identified as
missing. It never falls back to older defaults after a failed Keychain server
read. Legacy entries are removed only after the new blob is written
successfully.

`clearPairing` does not erase legacy entries when their prerequisite reads
failed, even when a newer registry exists and therefore needs no migration.

### 12. `PairedServer.tcAddress` is optional

Applies to: `PairedServer.tcAddress`, `StoredConnection.displayName`

`tcAddress` is the tailcat tunnel address (a "tc..." connection token) when the
daemon reported one, through the pairing payload (`tc=`) or `system.status`
(`tcAddress`). It is absent on records saved before the field existed and on
daemons without a running tunnel.

`StoredConnection.displayName` is the daemon hostname when known, else the
first host and port.
