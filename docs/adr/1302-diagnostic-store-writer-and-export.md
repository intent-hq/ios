# ADR-1302: Diagnostic store, writer and report export

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `DiagnosticStore`, `DiagnosticIntake` (`Intent/Utils/DiagnosticStore.swift`),
  `DiagnosticWriter` (`Intent/Utils/DiagnosticWriter.swift`),
  `DiagnosticStorage` (`Intent/Utils/DiagnosticFileStorage.swift`),
  `DiagnosticZIP` (`Intent/Utils/DiagnosticZIP.swift`),
  `DiagnosticPreview` (`Intent/Utils/DiagnosticPreview.swift`),
  `DiagnosticShareLease` (`Intent/Utils/DiagnosticShareLease.swift`)

## Context

Diagnostic events arrive from callbacks on any thread. They are buffered,
written to a bounded history file, reviewed by the user, and shared as a ZIP.
The history must stay bounded and consistent across relaunches, clock changes
and concurrent shares.

## Decisions

### 1. Ingress is synchronous and bounded, with one worker

Applies to: `DiagnosticStore`, `DiagnosticStore.scheduleDrain()`, `DiagnosticIntake`

Ingress is synchronous and bounded for callbacks. One independent worker drains
the buffer. There is no `Task` per event and no file I/O while the intake lock is
held. The lock covers only bounded value operations, never storage or
suspension. The drain task is deliberately independent of UI cancellation,
priority and task locals.

### 2. Scopes are allocated in-process and cannot be fabricated

Applies to: `DiagnosticStore.Scope.session`, `DiagnosticStore.Scope.ordinal`,
`DiagnosticStore.makeScope()`

`DiagnosticIntake` needs same-file access to `session` and allocates ordinals in
this file, so both use `fileprivate`. Broader access would let callers fabricate
source sessions and source IDs. Never pass a backend, scene or request ID as a
scope: scopes are allocated here and only have meaning within this launch.
Rotation does not reuse ordinals.

### 3. Production uses fixed limits

Applies to: `DiagnosticStore.init(storage:limits:clock:)`

The initializer is internal dependency injection. Production uses `shared`,
with fixed limits.

### 4. Snapshot, clear and report have fixed contracts

Applies to: `DiagnosticStore.snapshot()`, `DiagnosticStore.clearHistory()`,
`DiagnosticStore.beginReport()`

- `snapshot()` flushes all events admitted before the call reaches the writer.
  It returns a value snapshot, never the history file's unsanitized bytes or URL.
- `clearHistory()` linearizes at the writer: already queued events are
  discarded, and events admitted after that point are new history. False means
  deletion could not be confirmed (for example, protected files before unlock).
- `beginReport()` creates one pinned, fixed-entry ZIP workspace. The sharing
  layer must end the lease after its consumer finishes. Orphans are deleted on
  next launch.

### 5. The writer actor owns all file work and commits batches atomically

Applies to: `DiagnosticWriter`, `DiagnosticWriter.drain()`

All file work and retained history live on this non-main actor. Each batch
commits atomically, so relaunch sees either complete old data or complete new
data. `drain()` yields between batches for fairness toward snapshot and clear,
without one task per record.

### 6. Clear never reloads old history or removes a report in use

Applies to: `DiagnosticWriter.clearHistory()`

Clear marks history as loaded, so pre-clear history is never reloaded if removing
a protected file failed. A different window may still have a system share
consumer; its immutable report is removed by `endReport`, not underneath the
reader.

### 7. Export validity uses one time observation

Applies to: `DiagnosticWriter.prepareExport(reviewing:)`, `DiagnosticWriter.observeTime()`

File preparation may cross the retention boundary or a clock rollback, so one
observation is used for both time bounds and the revision check after the
report is prepared. `observeTime()` tracks the latest observation, not a
high-water mark: a fresh review after a rollback must be usable without waiting
for the clock to catch up.

### 8. Ending a report always releases it

Applies to: `DiagnosticWriter.endReport(_:)`

Even if deletion fails, the consumer has finished, so the active report is
cleared. The next prepare or Clear retries deletion, without accumulating report
directories.

### 9. Unreadable history is not replaced

Applies to: `DiagnosticWriter.loadIfNeeded()`

When storage cannot be read, the writer retries on a later batch if storage
becomes available. It does not turn unreadable history into an empty replacement
before a safe read.

### 10. Records age by first occurrence

Applies to: `DiagnosticWriter.expire(at:)`

Records age by their first occurrence: expired occurrences cannot be subtracted
from a summary without keeping every timestamp. A clock rollback purges future
records instead of extending their retention indefinitely.

### 11. Eviction invalidates older reviews only

Applies to: `DiagnosticWriter.boundedHistory()`

Eviction changes `historyRevision`, which invalidates older reviews but not an
active consumer's report. Arrivals that fit leave the reviewed bytes shareable
unchanged.

### 12. Only the writer uses the synchronous storage API

Applies to: `DiagnosticStorage`, `DiagnosticFileStorage`

Only the writer actor calls this synchronous file API. The injectable boundary
is for storage-failure tests, not for event producers. Only the bounded ZIP is
written: no duplicate loose report files. The file protection policy is applied
to pre-existing directories too, and diagnostics are never synced.

### 13. The ZIP encoder is deliberately minimal

Applies to: `DiagnosticZIP`

`DiagnosticZIP` is deliberately not a general archive library: two fixed UTF-8
names, stored (uncompressed) entries, and no caller-supplied paths, extras or
timestamps. It writes classic ZIP APPNOTE local headers, a central directory and
an end record. Sizes are bounded well below ZIP64 and all integers are written
little-endian.

The fixed fields are:

- `dosEpochDate` `0x0021` is 1980-01-01, so no filesystem metadata is recorded.
- Local header: compression method 0 (stored), DOS time 0, extra length 0.
- Central directory: "version made by" is `version20` (DOS, version 2.0); extra
  length, comment length, disk number and internal attributes are 0; external
  attributes are 0 (not a symlink).

### 14. Preview shows the original bytes off the UI actor

Applies to: `DiagnosticPreview.make(_:)`

The preview decodes and formats the bounded snapshot away from the UI actor. Raw
console logs and errors are never inputs; the bytes come from the store's closed
schema. The full JSON stays reviewable, not just a summary. `JSONDecoder` can
skip malformed UTF-8 in unknown fields, so the preview fails instead of showing
replacement characters: review must show the original bytes.

### 15. The share lease is owned by preview and UIKit

Applies to: `DiagnosticShareLease`, `DiagnosticShareLease.finish()`

The lease is shared ownership between the preview and UIKit, not the presenting
view's visibility: a controller or consumer can outlive navigation or scene
changes. Call `finish()` only when the system reports the activity completed or
cancelled. Dropping the last reference also cleans up a never-presented report.
The cleanup in `deinit` runs in a detached task so it survives cancellation or
disappearance of the UI task.
