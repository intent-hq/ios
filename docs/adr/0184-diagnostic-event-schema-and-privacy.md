# ADR-0184: Diagnostic events carry only closed values

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `DiagnosticEvent` (`Intent/Utils/DiagnosticEvent.swift`),
  `DiagnosticFailure` (`Intent/Utils/DiagnosticFailure.swift`),
  `DiagnosticOperation` (`Intent/Utils/DiagnosticOperation.swift`),
  `DiagnosticCoverage` (`Intent/Utils/DiagnosticCoverage.swift`),
  `DiagnosticSnapshot`, `DiagnosticLoss` (`Intent/Utils/DiagnosticSnapshot.swift`),
  `DiagnosticErrorReceipt`, `DiagnosticErrorOwnership`, `DiagnosticRequestContext`
  (`Intent/Utils/DiagnosticErrorOwnership.swift`)

## Context

The app keeps a persisted diagnostic history that a user can review and share.
The history must never hold free text, identifiers, paths or foreign error
content. These types define what an event may contain and who records a failure.

## Decisions

### 1. The diagnostic channel is separate from AppLog

Applies to: `DiagnosticEvent`

The channel is intentionally separate from `AppLog`. No message, identifier,
path, dictionary or foreign error can be supplied to a persisted event. A new
diagnostic field needs a closed type and a review of `DiagnosticEvent`;
`DiagnosticCoverageTests` checks that the schema has no free-form fields.

### 2. Only consecutive repetition is summarized

Applies to: `DiagnosticEvent.canSummarize`

Summaries merge consecutive repetition only. Recovery, terminal exhaustion,
cancellation and state changes always get their own record, even if otherwise
equal.

### 3. Failure classification accepts only closed values

Applies to: `DiagnosticFailure`, `DiagnosticFailure.remoteRPC(code:)`,
`DiagnosticFailure.securityStatus(_:classification:)`

Classification accepts only closed values. Boundary helpers discard unknown
numeric codes. They never accept `Error`/`NSError` or inspect foreign text.

- Call `remoteRPC(code:)` only at the remote response boundary, not on the
  flattened WebSocket `NSError` domain that local and remote errors share.
- For `securityStatus`, the operation owner decides whether item-not-found is a
  failure at all. Unknown status integers are deliberately not retained.

### 4. Operations are a reviewed table

Applies to: `DiagnosticOperation`

The cases are reviewed family/action pairs. Extend this table and its coverage
entry when adding a producer. Never substitute an RPC method name or a source
path.

### 5. Coverage is a register, not a proof

Applies to: `DiagnosticCoverage`, `DiagnosticCoverage.pendingFamilies`

`DiagnosticCoverage` is a coverage register, not an exhaustive control-flow
proof. Partial families remain in the exported `pendingFamilies` until all
owners land. Report metadata includes no identifiers, paths or test names.

### 6. Snapshot metadata is restricted

Applies to: `DiagnosticSnapshot.historyRevision`, `DiagnosticSnapshot.Metadata.init`

`historyRevision` is in-memory review validity only and is never serialized into
the report. App metadata is read internally and restricted to numeric version
strings. There is no device name, locale, path or stable device identifier.

### 7. Loss counters are best effort

Applies to: `DiagnosticLoss`

The counters are best-effort current-process indicators, deliberately not a
promise of lossless capture. Abrupt termination can also lose the indicators
themselves.

### 8. Error receipts are in-memory provenance owned by the app

Applies to: `DiagnosticErrorReceipt`, `DiagnosticErrorOwnership.attaching(to:failure:suppressed:)`

The receipt is in-memory provenance and is never serialized. Only app-owned
boundaries attach a receipt; a server's domain, code or message cannot
manufacture one. Copies of an `NSError` keep the same receipt, so propagation
through stores records once. `attaching` keeps the existing error domain, code
and UI text. The receipt holds only closed diagnostics and never reads that
text back for classification.

### 9. Feature owners record failures once

Applies to: `DiagnosticErrorOwnership.record(_:event:store:)`

Feature owners use `record` for propagated request failures and for local
errors. Requests already recorded at transport ingress are not recorded again.
Cancellation and explicitly suppressed teardown receipts are benign.

### 10. Request ownership is opt-in through a task local

Applies to: `DiagnosticRequestContext`, `DiagnosticRequestContext.Recording.deferred`

Request ownership is opt-in for an enclosing operation. Feature producers can
set a closed operation, site and outcome before calling `request`. No protocol
signature changes and no free-form method names enter the diagnostic channel.
With `.deferred`, the feature decides whether a rejection is benign
compatibility, recovered, or terminal, and then claims the receipt in its own
catch.

### 11. Connection loss does not raise an alert

Applies to: `DiagnosticErrorOwnership.isConnectionLoss(_:)`, `DiagnosticErrorOwnership.alertMessage(for:)`

A request that failed only because the Mac connection dropped (or was not up)
is a connection loss. Read-only mode covers these, so they never raise an alert.
