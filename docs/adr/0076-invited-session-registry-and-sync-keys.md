# ADR-0076: Invited session registry, legacy migration receipts, and sync keys

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `InvitedSessionRegistry` (`Intent/Services/InvitedSessionRegistry.swift`), `InvitedLegacyMigrationReceipt` (`Intent/Services/InvitedLegacyMigration.swift`), `InvitedImportOutcome` (`Intent/Services/InvitedImportOutcome.swift`), `InvitedSyncKey` (`Intent/Services/InvitedSyncKey.swift`)

## Context

Invited (guest) sessions sync between the person's devices through the
keychain. The app shares the desktop's invited-session service and must migrate
legacy rows without losing or rewriting data it does not understand.

## Decisions

### 1. One keychain service shared with the desktop

Applies to: `InvitedSessionRegistry`

The registry is the existing desktop invited-session service
(`com.cloudlands.intent.guest-sessions`). It uses the same Security seam and
access group as owner sync. Its v2 dispatch never changes owner v1 data.

### 2. Both groups must be readable first

Applies to: `InvitedSessionRegistry.read()`

Both the shared access group and the legacy (nil) group must be readable before
any migration or live publication.

### 3. Removals are create-only

Applies to: `InvitedSessionRegistry.insertRemoval(_:)`

Removal insertion is create-only. Even the duplicate path never updates a row;
equal known fields acknowledge it while unknown bytes are preserved. The
account key hashes every immutable field, so re-deriving it establishes
equality without rewriting unknown extension fields.

### 4. Legacy copies are cleaned up only after the destination save

Applies to: `InvitedSessionRegistry.writeMutable(_:snapshot:)`

A classified legacy-group copy is deleted only after the save in the
destination access group succeeded.

### 5. Migration receipts are local, token-free, and exact

Applies to: `InvitedLegacyMigrationReceipt`

A receipt is local, token-free provenance for a row seen before its alias
retired. Its digest permits only these exact bytes in this exact access group.
A bound person must still be authenticated on every retry.

### 6. Known removals stay authoritative

Applies to: `InvitedImportOutcome.init(before:after:suppressed:)`

Known removals remain authoritative even when the final local read fails. An
unavailable registry supplies no evidence of other deletes, so only the added
and updated ids depend on a successful read.

### 7. Sync keys work on UTF-8 bytes

Applies to: `InvitedSyncKey`, `InvitedSyncKey.hexBytes(_:)`

`InvitedSyncKey` implements the §5.49 byte encoding. Swift `String` equality
normalizes Unicode, so identity and set operations here deliberately work on
UTF-8 bytes instead. In `hexBytes`, base 16 is intrinsic to the hexadecimal
byte decoder, not a configurable limit, so `no_magic_numbers` is suppressed on
that line.
