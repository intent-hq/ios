# ADR-0018: Invited sessions fold removals first and install only the credential just authenticated

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `PersistenceManager` (`Intent/PersistenceManager+InvitedSessions.swift`,
  `Intent/PersistenceManager+InvitedImport.swift`,
  `Intent/PersistenceManager+InvitedBackfill.swift`), `StoredConnection`
  (`Intent/Models.swift`)

## Context

An invited (non-owner) person's access to a shared host is synced as invited-v2
records in `InvitedSessionRegistry`. A local journal in `UserDefaults`
(`invitedSessionSyncJournal`) holds removal floors, removals, and legacy alias
state. Removals, re-pairs, and legacy v1 rows from other devices can arrive at
any time, and authentication is an async step in the middle of an import.

## Decisions

### 1. The invited payload rides in the local Keychain blob

Applies to: `StoredConnection.invitedSyncPayload`

The field holds the exact invited-v2 payload. It is protected by the existing
local Keychain blob.

### 2. Journal writes are confirmed by readback

Applies to: `PersistenceManager.persistInvitedMigrationJournal(_:)`

Migration and alias changes are refused when the local provenance write was
rejected. The readback confirms acceptance by the injected or defaults store.
It is not an fsync.

### 3. A new pairing needs a full successful read

Applies to: `PersistenceManager.prepareInvitedPairing(_:hostname:)`

The method is called only after explicit pairing and authoritative identity
discovery. A successful full read is required before a new intent can beat
removals.

### 4. Publication folds removals first and never restamps on failure

Applies to: `PersistenceManager.publishPendingInvitedSessions()`,
`PersistenceManager.publishInvitedRemovals(_:journal:)`

Every attempt begins by folding removals, including observed future pairing and
route clocks. A failure never acknowledges or restamps the intent. A route
patch merges with remote credentials before publication.

Inserting an immutable removal changes the registry signature. After each
insert, both groups are re-read before repair, including any concurrent
re-pair or removal, while `writeMutable` keeps its final snapshot guard. A
later authenticated re-pair is kept, and the independent removal stays.

### 5. Local suppression comes before credential deletion

Applies to: `PersistenceManager.rememberInvitedRemoval(_:)`

Local suppression precedes credential deletion and cloud insertion. Retries
reuse the exact same removal UUID, floor, and alias snapshot after a relaunch.

### 6. Import reads and folds removals before it authenticates or writes

Applies to: `PersistenceManager.refreshInvitedSessions(authenticate:)`

All reads and removal folding happen before authentication and writes. The
caller supplies isolated connections. No owner-side socket is borrowed.
A guest never requests the owner-only `host.status` method during an invited
route refresh.

### 7. After authentication, only the credential just checked is installed

Applies to: `PersistenceManager.refreshedInvitedRecord(_:migrated:original:)`

Authentication is an async boundary. Only the credential that was just checked
may be installed, with freshly merged route, metadata, and removal state.

Prepared migrations are not durable yet. Fresh removals are observed
immediately, but publication retires aliases only after the local save
succeeds.

### 8. Observed removals stop service even when the save fails

Applies to: `PersistenceManager.applyInvitedRemovalFloors()`

Suppressed ids are returned even when the credential save fails. Windows must
stop serving a person once their removal has been observed.

Durable local removal evidence beats both v1 and v2 records, also when a later
cloud snapshot loses the removal and brings back a still-valid old credential.
A removed connection stays removed on every device until the person
deliberately pairs it again.

### 9. Legacy v1 migration reserves sources and authenticates before choosing winners

Applies to: `PersistenceManager.migrateInvited(snapshot:authenticate:)`,
`PersistenceManager.selectLegacyWinners(_:candidates:ambiguous:)`

Every eligible legacy source is reserved before any await or peer save can
retire its shared alias. The reservation grants retry of the row, never socket
authority.

All attributable live candidates are authenticated before the v1
last-writer-wins winners are selected. The original comment said: "Row
ordering cannot turn a missing-person deletion into C." It did not define "C".

Retirement of a legacy alias is installed only after the winning candidate is
persisted and published by the ordinary invited pass.

After the migration completes, a frozen v1 writer can still overwrite the
shared alias. Neither its newer clock nor another claimed person reopens the
migration.

### 10. Pre-v2 credentials are classified late and keep their pairing clock

Applies to: `PersistenceManager.backfillInvited(_:)`,
`PersistenceManager.legacyInvitedRecord(_:)`

A saved pre-v2 credential is classified only after pinned admission. Its
original pairing clock survives, because a reconnect is never a new intent.

Authenticated local provenance stays usable for removal and routing even when
cloud reads or the first v2 publication have not succeeded.
