# 0080. Diagnostic history privacy, bounds and storage

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The app keeps a local diagnostic history that the user can review and share as a ZIP. The history must help find failures, but it must never carry transcript text, paths, identifiers or server text. Events come from callbacks on any thread, and the history must survive a crash or a relaunch without half-written data.

## Decision

1. **Closed schema.**
   1. `DiagnosticEvent` is a separate channel from `AppLog`. A producer cannot put a message, identifier, path, dictionary or foreign error into a persisted event.
   2. `DiagnosticFailure` accepts only closed values. Boundary helpers drop unknown numeric codes. They never accept `Error` or `NSError` and never read foreign text.
   3. `DiagnosticFailure.remoteRPC(code:)` runs only at the remote response boundary, never on the flattened WebSocket `NSError` domain that local and remote errors share.
   4. `DiagnosticFailure.securityStatus(_:classification:)` does not keep unknown status integers. The operation owner decides if item-not-found is a failure.
   5. `DiagnosticOperation` is a reviewed table of family/action pairs. A new producer adds a row and a `DiagnosticCoverage` entry. It never uses an RPC method name or a source path.
   6. `DiagnosticCoverage` is a register, not a control-flow proof. A partial family stays in `pendingFamilies` until all owners land. Report metadata has no identifiers, paths or test names.
2. **Error ownership.**
   1. `DiagnosticErrorReceipt` is in-memory provenance and is never serialized. Only app-owned boundaries attach a receipt. A server's domain, code or message cannot make one. Copies of an `NSError` keep the same receipt, so an error recorded once is not recorded again as it moves through stores.
   2. `DiagnosticErrorOwnership.attaching` keeps the error domain, code and UI text. The receipt never reads that text back.
   3. Feature owners call `DiagnosticErrorOwnership.record(_:event:store:)` for request failures and local errors. Transport ingress already records requests; they are not recorded again. Cancellation and suppressed teardown receipts are benign.
   4. `DiagnosticRequestContext` lets an enclosing operation set a closed operation, site and outcome. No protocol signature changes and no free-form method names.
   5. A request that failed only because the Mac connection dropped is not an alert. Read-only mode covers it (`isConnectionLoss(_:)`, `alertMessage(for:)`).
3. **Logs.** `AppLog` compiles out debug through warning in Release. Error and fault stay, with private messages. `ConversationTrace` runs only when enabled, in Debug and Release, and its details hold only identifiers, counts, timings and fixed reasons, never transcript content.
4. **Ingress.**
   1. `DiagnosticStore` takes events synchronously and is bounded. One independent worker drains the buffer. No `Task` per event and no file I/O while the intake lock is held. The lock in `DiagnosticIntake` covers only bounded value operations.
   2. The drain task is detached on purpose: UI cancellation, priority and task locals do not affect it.
   3. `makeScope()` allocates scopes. A caller never passes a backend, scene or request id. A scope means something only in this launch, and rotation does not reuse ordinals. Callers cannot fabricate a `Scope`.
5. **Writer.**
   1. All file work and retained history live on the `DiagnosticWriter` actor, off the main actor. Each batch commits atomically, so a relaunch sees complete old or complete new data.
   2. `drain()` yields between records so snapshot and clear stay fair without one task per record.
   3. `snapshot()` flushes all events admitted before the call. It returns a value, never the history file's bytes or URL. `DiagnosticSnapshot.historyRevision` is in-memory review state and is never serialized.
   4. `clearHistory()` linearizes at the writer. Queued events are discarded; later events are new history. `false` means deletion was not confirmed, for example protected files before first unlock. After a failed delete the writer never reloads pre-clear history.
   5. History ages by first occurrence: a summary cannot drop expired occurrences without every timestamp. A clock rollback purges future records instead of extending their retention. The writer tracks the latest time observation, not a high-water mark, so a fresh review after rollback works at once.
   6. Unreadable history is not replaced with an empty file before a safe read. The writer sets `DiagnosticLoss.storageUnavailable` and retries on a later batch.
   7. Eviction invalidates older reviews, but not an active consumer's report. Arrivals that fit leave the reviewed bytes shareable.
   8. `DiagnosticEvent.canSummarize` merges only consecutive repeats. Recovery, terminal exhaustion, cancellation and state changes always get their own record.
   9. `DiagnosticLoss` is best effort. Abrupt termination can lose the indicators too.
6. **Report and share.**
   1. `beginReport()` makes one pinned ZIP workspace with fixed entries. Only the ZIP is written, no loose report files. Orphans are deleted on next launch.
   2. `DiagnosticZIP` is not a general archive library: two fixed UTF-8 names, stored entries, no caller paths, extras or timestamps, classic APPNOTE headers, sizes below ZIP64, little-endian integers.
   3. `prepareExport(reviewing:)` uses one time observation for both time bounds and the revision check, because preparation can cross the retention boundary or a clock rollback.
   4. `DiagnosticShareLease` is shared ownership between the preview and UIKit, not the view's visibility. Call `finish()` only when the system reports the activity completed or cancelled. Dropping the last reference also cleans up. Cleanup runs in a detached task so it survives UI cancellation.
   5. `clearHistory()` does not delete a report that another window's share sheet still reads; `endReport(_:)` removes it. `endReport(_:)` clears the active report even if deletion fails; the next prepare or clear retries.
   6. `DiagnosticPreview.make(_:)` decodes off the UI actor and shows the full JSON, not only a summary. It shows the original bytes and fails on malformed UTF-8 instead of showing replacement characters.
   7. `DiagnosticSnapshot` reads only numeric version strings from the bundle. No device name, locale, path or stable device id.
7. **Storage.** `DiagnosticStorage` is called only by the writer. Its injection point exists for storage-failure tests, not for producers. `DiagnosticFileStorage` applies `completeUntilFirstUserAuthentication` protection to new and existing directories and excludes diagnostics from sync.

## Consequences

- A new diagnostic field needs a closed type and a review of `DiagnosticEvent`; `DiagnosticCoverageTests` checks the schema has no free-form fields.
- Retention can drop an event family early when its first occurrence expires.
- Purging a future record after a clock rollback rotates `historyRevision` by itself, even when no worker ran at the future time (from test comments).
- `DiagnosticZIPTestReader` is an independent, strict stored-ZIP reader. It walks the central directory, follows each local-header offset, and checks CRC with its own bitwise code, not the writer's table, so a shared bug cannot hide. Real Files and system-share interoperability stays a separate runtime check (from test comments).

## Code

- `DiagnosticEvent`, `DiagnosticFailure`: `remoteRPC(code:)`, `securityStatus(_:classification:)`
- `DiagnosticOperation`, `DiagnosticCoverage`: `pendingFamilies`
- `DiagnosticErrorReceipt`, `DiagnosticErrorOwnership`: `attaching`, `record(_:event:store:)`, `isConnectionLoss(_:)`, `alertMessage(for:)`; `DiagnosticRequestContext`
- `AppLog`, `ConversationTrace`
- `DiagnosticStore`: `makeScope()`, `snapshot()`, `clearHistory()`, `beginReport()`; `DiagnosticIntake`
- `DiagnosticWriter`: `drain()`, `prepareExport(reviewing:)`, `endReport(_:)`, `expire(at:)`; `DiagnosticLoss`, `DiagnosticSnapshot`
- `DiagnosticZIP`, `DiagnosticShareLease`: `finish()`; `DiagnosticPreview`: `make(_:)`
- `DiagnosticStorage`, `DiagnosticFileStorage`
