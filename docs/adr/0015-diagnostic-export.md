# ADR-0015: Diagnostic log export lifecycle

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `DiagnosticExportModel` (`Intent/ViewModels/DiagnosticExportModel.swift`)

## Context

Settings lets the user preview local diagnostic logs, share them as a ZIP, and
clear them. Previews expire, and the user can dismiss the screen during work.

## Decisions

### 1. Clearing history is narrow

Applies to: `DiagnosticExportModel.clearHistory()`

Only the confirmed destructive action calls `clearHistory()`. It never touches
saved connections, conversations, or copies already shared elsewhere.

### 2. SwiftUI owns the expiry wait

Applies to: `DiagnosticExportModel.refreshWhenExpired()`

SwiftUI owns and cancels the wait for preview expiry. The writer also
rechecks expiry at Share time, including expiry during ZIP preparation. A
cancelled wait means the view disappeared or a newer preview replaced this one,
so the error is ignored.

### 3. Dismissal is silent

Applies to: `DiagnosticExportModel.start(_:)`

A `CancellationError` is swallowed. Dismissal never opens a late share sheet or shows a failure.
