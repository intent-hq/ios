# 0050. Saved connection registry, pairing identity and legacy migration

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The app saves each paired daemon as a `StoredConnection`: its pairing info, its API token and some metadata. The whole list lives in one device-local Keychain blob. A daemon can be re-paired many times, by QR code or by manual entry, with a different host list each time. Reads of the Keychain can fail. Old installations still hold the single-pairing format that came before the list.

## Decision

1. **Read results.**
   1. A registry read is `missing`, `loaded` or `failed` (`ConnectionRegistryReadResult`).
   2. `missing` is a known empty list and is a valid base for a write. A `failed` read is never a base for a write.
   3. Storage entry and retry paths use `loadConnectionsWithOutcome()`. They do not treat a failed `loadConnections()` read as an empty list.
   4. `ConnectionRegistryReadError` holds safe categories only. It never carries credential bytes or decoder diagnostics.
2. **Pairing identity.** `upsertConnection(_:)` updates an existing record in place, and keeps its id, when one of these matches:
   1. The certificate fingerprint.
   2. The same port and at least one shared host. Overlap, not set equality, is the key, because the post-connect route refresh grows the stored host set over time. A re-pair through one manual host must update the grown record.
   3. The same port and the same Tailcat tunnel address (`tcAddress`). A manual tunnel-only re-pair has no hosts, so without this key each re-pair would add a duplicate.
3. **Host and tunnel merge.**
   1. On a match, existing hosts keep their order and are never dropped. New hosts are appended (`mergeHostLists(existing:incoming:)`).
   2. Hosts are deduplicated case-insensitively, because DNS names and IPv6 hex are case-insensitive (ios#341). The first spelling seen wins.
   3. A re-pair without a tunnel address (manual entry, or a QR code from a daemon whose tunnel is down) keeps the known `tcAddress`. The post-connect refresh keeps it current.
   4. `tcAddress` comes from the pairing payload (`tc=`) or `system.status` (`tcAddress`). It is optional: records saved before the field and daemons without a tunnel have none.
4. **Updates by id.** `updateConnectionHosts(id:hosts:)`, `updateConnectionTcAddress(id:tcAddress:)` and `updateConnectionDisplayName(id:displayName:)` change one record by id. They never insert or duplicate a record, because a grown host set would not match as the same pairing. An unknown id is a no-op.
5. **Saves and observers.**
   1. Callers that report pairing success use `upsertConnectionWithOutcome`, which reports whether the registry was durably saved.
   2. `connectionsDidChange` fires only after a saved mutation succeeds. Window labels observe their own record, not the last-used pointer.
6. **Last-used pointer.** The active connection id is not a navigation concept (window model v2). It only picks the backend that a fresh window binds to at launch. `lastUsedConnection()` returns the pointer's record when it still exists, else the most recently connected record.
7. **Legacy pairing migration.**
   1. `migrateLegacyPairingIfNeeded()` moves the old single pairing (Keychain `serverInfo` + `apiToken`, or the older UserDefaults `pairedServer`) into the list.
   2. It runs only after the registry is positively known to be missing. After a failed Keychain server read it never falls back to older defaults.
   3. Legacy entries are removed only after the new blob is written. `clearPairing()` does not erase legacy entries when their reads failed, even when a newer registry exists.
8. **Legacy drafts.** Drafts saved before per-backend keys belong to the backend that was active when they were written.
   1. `preserveLegacyDraftOwner()` records that backend before a window changes the last-used pointer. The owner survives connection switches and restarts.
   2. A missing or failed registry read leaves legacy drafts untouched until the owner resolves.
   3. A scoped draft is newer than the legacy one. The legacy value is consumed even when it loses.

## Consequences

- Two different daemons that share a host and port are treated as the same pairing.
- A host is never removed from a record by a re-pair. Only an explicit update by id can shrink the list.
- Legacy migration code stays until no supported installation can hold the old format.

## Code

- `ConnectionRegistryReadResult`, `ConnectionRegistryReadError`
- `PersistenceManager`: `loadConnectionsWithOutcome()`, `upsertConnection(_:)`, `upsertConnectionWithOutcome`, `matchesPairing`, `mergeHostLists(existing:incoming:)`, `updateConnectionHosts(id:hosts:)`, `updateConnectionTcAddress(id:tcAddress:)`, `updateConnectionDisplayName(id:displayName:)`, `connectionsDidChange`, `activeConnection()`, `lastUsedConnection()`, `migrateLegacyPairingIfNeeded()`, `clearPairing()`
- `PersistenceManager` drafts: `preserveLegacyDraftOwner()`, `migrateLegacyDraft`
- `PairedServer`: `tcAddress`
