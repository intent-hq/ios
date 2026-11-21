# ADR-1203: Deferred row lists use Sendable snapshots

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ForEach.init(snapshots:id:content:)` (`Intent/Views/Components/ForEach+Snapshots.swift`)
- Related issues: ios#796 (pull request)

## Context

SwiftUI may call row builders on its async renderer. Plain `ForEach` content
is not `@Sendable`, so a closure can inherit this target's default MainActor
isolation, compile, and then crash when it is invoked off the main actor. See
https://github.com/intent-hq/ios/pull/796.

## Decisions

### 1. Use `ForEach(snapshots:id:content:)` for deferred row lists

Applies to: `ForEach.init(snapshots:id:content:)`

Use it for deferred row lists that are prepared in a main-actor context.
Sendable snapshots and a `@Sendable` builder make accidental direct access to
main-actor state a compile error.

### 2. Prepare everything before the call

Applies to: `ForEach.init(snapshots:id:content:)`

Read store state and prepare main-actor actions before this call. The deferred
builder uses only the prepared values. Store lightweight `View` values in the
snapshots; their bodies remain lazy.

### 3. Return `ForEach` directly

Applies to: `ForEach.init(snapshots:id:content:)`

The initializer returns a `ForEach` directly, which preserves the row identity
and row counts of lazy containers.

## Consequences

A new row list on a lazy container follows this pattern, and a row snapshot
never carries an opaque, non-Sendable modified view (ADR-1009).
`scripts/test-row-provider-isolation.sh` checks the row-provider boundary on
macOS.
