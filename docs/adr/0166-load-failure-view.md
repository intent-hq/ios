# ADR-0166: Load failure view

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `LoadFailureView` (`Intent/Views/Components/LoadFailureView.swift`)
- Related issues: ios#462

## Decisions

### 1. A failed first read says so and offers Retry

Applies to: `LoadFailureView`

When a list's first read fails (ios#462), the view says so and offers Retry,
instead of an endless loading placeholder or an empty state. Disconnected
read-only sessions show the usual "available when reconnected" message instead.

### 2. Parameters

Applies to: `LoadFailureView.subject`, `LoadFailureView.identifier`

`subject` is a plural noun for the headline, for example "Notes" in "Couldn't
Load Notes". `identifier` is the prefix for the `<prefix>.loadFailure` and
`<prefix>.loadFailure.retry` accessibility identifiers.
