# 0042. Deferred row lists use Sendable snapshots

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

SwiftUI can call row builders on its async renderer. Plain `ForEach` content is not `@Sendable`. A row closure can inherit the target's default `MainActor` isolation, compile without error, and crash when SwiftUI calls it off the main actor (intent-hq/ios#796).

## Decision

1. A deferred row list uses `ForEach(snapshots:id:content:)`. Its elements are `Sendable` snapshots and its builder is `@Sendable`, so direct access to main-actor state is a compile error.
2. The list reads store state, resolves environment values and prepares main-actor actions before this call. The builder uses only the prepared values.
3. A snapshot can hold lightweight `View` values. Their bodies stay lazy, and constructing a row does not build its label or read live store state.
4. The initializer returns `ForEach` directly, so lazy containers keep row identity and counts.

## Consequences

- A new row list on a lazy container follows this pattern. `scripts/test-row-provider-isolation.sh` checks the row-provider boundary on macOS.

## Code

- `ForEach`: `init(snapshots:id:content:)`
- `AgentHistoryRowSnapshot`, `AgentHistoryRow`, `AgentHistoryList`
- Conversation rows with `@Sendable` builders over prepared values: `AssistantHistoryMenu`, `WorkspaceQuestionAnswerCards`, `AgentWaitingView`
