# ADR-0202: Owner backend publication saves the intent locally first and never revives a newer removal

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `PersistenceManager` (`Intent/PersistenceManager+BackendSync.swift`),
  `StoredConnection`, `PendingBackendRoutePublication` (`Intent/Models.swift`)

## Context

An owner's saved backends are published to a shared iCloud registry so other
devices of the same person can import them. Local pairings, route changes, and
remote removals race each other across devices. Each record carries
last-writer-wins clocks in milliseconds since the epoch.

## Decisions

### 1. Clocks on `StoredConnection`

Applies to: `StoredConnection.syncUpdatedAt`,
`StoredConnection.pendingSyncUpdatedAt`, `StoredConnection.localPairingSyncClock`

`syncUpdatedAt` is the `updatedAt` of the last iCloud-synced registry record
that was applied or successfully published. It is the last-writer-wins clock
for `SyncedBackendConnectionMerge`. It is `nil` on connections that predate
sync, or that were paired locally and never matched a registry record.

`pendingSyncUpdatedAt` is a durable local edit that waits for shared
publication. It is kept in the same device-local Keychain blob as the
credentials. Retries never restamp it.

`localPairingSyncClock` is the provenance for automatic route publication.
Ordinary imports have none. Only an explicit pairing newer than a remembered
removal can resume route publication.

### 2. Remote removals are remembered in a separate non-secret journal

Applies to: `PersistenceManager.suppressedPublicationClock(id:)`,
`PersistenceManager.suppressPublication(id:record:)`

The suppression and removal clocks live in `UserDefaults`, separate from the
credential blob. Remembering a winning remote removal must survive a local
Keychain save failure, relaunch, and the eventual iCloud tombstone purge.

### 3. A route observation patches a live row and never recreates one

Applies to: `PersistenceManager.queueRoutePublication(_:previousRoute:newRoute:)`,
`PendingBackendRoutePublication`

The route intent is saved atomically with the observed route. Unlike a
deliberate re-pair, a route observation must not authorize recreation after a
removal. It may patch an existing live shared row, but never recreate one or
replace its credentials. The baseline in the pending publication detects
competing rotations.

`PendingBackendRoutePublication.tcUpdatedAt` is the time of the actual tunnel
observation. Host-only edits do not change it. Legacy pending intents fall back
to their original `updatedAt`.

### 4. One publish attempt per opportunity, with backfill at the original pairing time

Applies to: `PersistenceManager.publishPendingBackends()`

There is one attempt per pending backend per pairing or foreground opportunity.
Backfill uses the original pairing time, never today's clock, so an old
installation cannot revive a newer shared removal or edit.

No shared mutation happens until the intent and the credentials have been saved
together in the device-local registry.

A failed acknowledgement save is safe. The exact same pending clock survives,
and an equal shared clock needs no second write.

### 5. Route patches wait for a pending credential rotation

Applies to: `PersistenceManager.publishRoutes(_:)`

A route patch must not race a still-pending credential rotation and give that
older shared token a clock newer than the deliberate edit, so routes publish
only when `pendingSyncUpdatedAt` is `nil`.

After a route patch, the import clock is left alone. The patched row may
contain newer shared credentials or labels that still need to reach the live
cache.
