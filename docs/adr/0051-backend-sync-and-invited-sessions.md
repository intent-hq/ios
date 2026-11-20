# 0051. Backend registry sync and invited sessions

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Saved connections sync between a person's devices through an iCloud registry. Owner connections sync as backend records. Invited connections (a person invited to someone else's daemon) sync as invited-v2 records. Devices edit, re-pair and remove connections at the same time, and a device can be offline for a long time. A removal on one device must not come back from another device, and a credential must never reach a window that should no longer have it.

## Decision

1. **Clocks.**
   1. `syncUpdatedAt` is the last-writer-wins clock for `SyncedBackendConnectionMerge`: the `updatedAt` (ms since epoch) of the last registry record that was applied or published. Connections that were never matched to a record have none.
   2. `pendingSyncUpdatedAt` is a durable local edit that waits for publication. It lives in the same device-local Keychain blob as the credentials. Retries never restamp it.
   3. On upsert, the last observed `syncUpdatedAt` is kept. A deliberate local pairing gets its own pending clock before the atomic save.
   4. Backfill uses the original pairing time, never the current time. An old installation cannot revive a newer shared removal or edit.
2. **Publication authority.**
   1. Only `PersistenceManager.shared` installs a production `backendPublisher`, and only outside the test host. Custom, test and ephemeral stores never publish.
   2. `localPairingSyncClock` records why automatic route publication is allowed. Ordinary imports have none. Only an explicit pairing newer than a remembered removal can resume publication.
   3. Nothing shared changes until the intent and the credentials are saved together in the local registry.
   4. Publication runs once per pending backend per pairing or foreground opportunity (`publishPendingBackends()`).
   5. A failed acknowledgement save is safe: the same pending clock survives, and an equal shared clock needs no second write.
3. **Route publication.**
   1. A route observation (`PendingBackendRoutePublication`) may patch an existing live shared row. It never recreates a row or replaces its credentials. Its baseline detects competing rotations.
   2. `queueRoutePublication` saves the route intent atomically with the observed route. Unlike a deliberate re-pair, it does not authorize recreation after a removal.
   3. `tcUpdatedAt` is the time of the actual tunnel observation. Host-only edits do not change it. Pending intents saved before the field use their `updatedAt`.
   4. A route patch never runs while a credential rotation is pending. Otherwise the older shared token would get a clock newer than the deliberate edit.
   5. After a route patch, the import clock stays unchanged. The patched row can hold newer shared credentials or labels that still need to reach the local cache.
4. **Removals.**
   1. Remembered removals live in a non-secret journal in `UserDefaults`, separate from the credential blob. The journal survives a Keychain save failure, a relaunch, and the iCloud tombstone purge.
   2. `mergeSyncedBackends(records:)` applies registry winners, including tombstones, in one atomic pass under the persistence lock. A tombstone that removes the active connection also clears the active pointer and reports it, so the caller can disconnect.
   3. When the Keychain write fails, the merge reports a no-op and leaves the pointer alone. The caller never disconnects while the saved list still holds the connection. The next registry read retries.
5. **Invited sessions.**
   1. The exact invited-v2 payload (`invitedSyncPayload`) is kept in the local Keychain blob.
   2. `prepareInvitedPairing` runs only after explicit pairing and authoritative identity discovery. A new intent can beat removals only after a successful full registry read.
   3. A saved pre-v2 credential is classified only after pinned admission (`backfillInvited`). Its original pairing clock is kept: a reconnect is never a new intent.
   4. Authenticated local provenance stays usable for removal and routing, even when cloud reads or the first v2 publication have failed (`legacyInvitedRecord`).
   5. `persistInvitedMigrationJournal` refuses migration and alias changes when the local provenance write was rejected. The readback confirms that the store accepted the value; it is not an fsync.
6. **Invited import.**
   1. In `refreshInvitedSessions(authenticate:)`, all reads and removal folding come before authentication and writes. The caller supplies isolated connections; no owner socket is borrowed.
   2. Authentication is an async boundary. After it, only the credential just checked can be installed, with freshly merged route, metadata and removal state.
   3. Prepared migrations are not durable yet. Fresh removals are observed at once, but aliases retire only after the local save succeeds.
   4. Removed IDs are returned even when the credential save fails. Windows must stop serving a person as soon as the removal is observed.
   5. Every eligible migration source is reserved before any await or peer save can retire its shared alias. The reservation allows a retry of the row, never socket authority.
   6. All attributable live candidates are authenticated before v1 last-writer-wins winners are selected. Row order cannot turn a missing-person deletion into a live connection.
   7. A retirement is installed only after its candidate is persisted and published by the ordinary invited pass.
7. **Invited publication.**
   1. Every attempt starts by folding removals, including observed future pairing and route clocks. A failure never acknowledges or restamps the intent.
   2. A route patch merges with the remote credentials before publication.
   3. Inserting an immutable removal changes the registry signature. Both groups are read again before repair, and `writeMutable` keeps its final snapshot guard.
   4. A later authenticated re-pair is kept; the independent removal stays.
   5. `rememberInvitedRemoval` writes the local suppression before it deletes the credential and before the cloud insert. Retries after a relaunch reuse the same UUID, floor and alias snapshot.

## Consequences

- A removed connection stays removed on every device until the person deliberately pairs it again.
- Local saves come first, so a Keychain failure delays sync but never loses a removal.
- Tests cannot publish to the real registry by accident.

## Code

- `StoredConnection`: `syncUpdatedAt`, `pendingSyncUpdatedAt`, `localPairingSyncClock`, `invitedSyncPayload`, `pendingRoutePublication`
- `PendingBackendRoutePublication`: `tcUpdatedAt`
- `PersistenceManager`: `backendPublisher`, `preparePublication`, `mergeSyncedBackends(records:)`, `suppressedPublicationClock(id:)`, `queueRoutePublication`, `publishPendingBackends()`, `publishRoutes`
- `PersistenceManager` invited: `prepareInvitedPairing`, `backfillInvited`, `legacyInvitedRecord`, `persistInvitedMigrationJournal`, `publishPendingInvitedSessions()`, `publishInvitedRemovals`, `rememberInvitedRemoval`, `refreshInvitedSessions(authenticate:)`, `refreshedInvitedRecord`, `migrateInvited`
- `SyncedBackendConnectionMerge`, `InvitedSyncMerge`, `InvitedSessionRegistry`, `InvitedSyncJournal`
