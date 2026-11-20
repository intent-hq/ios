# ADR-0601: Invited sync records keep raw fields, and the journal is token-free

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `InvitedSyncJournal`, `InvitedSyncMerge` (`Intent/Services/InvitedSyncMerge.swift`), `InvitedSyncRecord` (`Intent/Services/InvitedSyncRecord.swift`)

## Context

Invited sessions sync between devices as v2 records. `InvitedSyncRecord` parses
one record. `InvitedSyncMerge` merges the records of one person.
`InvitedSyncJournal` is the local memory of removals and legacy migrations.

## Decisions

### 1. Records keep their raw fields, and a rejected record keeps its bytes

Applies to: `InvitedSyncRecord`, `InvitedSyncRecord.parse(account:data:)`

A record holds the raw JSON object, so fields that this app does not know
survive a rewrite. When the parser rejects a record, the original bytes are
frozen and not rewritten.

### 2. `stringSet` returns nil for an invalid field

Applies to: `InvitedSyncRecord.stringSet(_:)`

The optional result tells an invalid field apart from a valid empty alias set.
This is why the function returns an optional collection.

### 3. The journal is a token-free removal memory and outbox

Applies to: `InvitedSyncJournal`

The journal sits alongside the existing backend journal. It holds no tokens.
It is saved before credential writes, so a locked Keychain cannot undo a
forget.

### 4. `pendingLegacy` is optional on decode and holds no bearer payloads

Applies to: `InvitedSyncJournal.pendingLegacy`, `InvitedSyncJournal.init(from:)`

A journal written before this field existed decodes with an empty list, which
means no retry exception. The field is local-only. It holds hashes and
provenance, never bearer payloads.

### 5. Binding a legacy source re-runs `observe`

Applies to: `InvitedSyncJournal.bindLegacySource(_:personKey:)`

After a receipt gets its person key, `observe([])` runs again, because a
removal that was already observed also covers the newly bound row.
