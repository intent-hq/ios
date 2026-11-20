# 0103. Daemon event classification and wake labels

**Status:** Accepted (recorded 2026-11-20 from test comments)

## Context

intentd emits typed events on channels such as `workspace:*` and `task:*`. Each store decides per type whether to refetch, patch in place, or ignore. A type that no store names is a silent drop of a change the user may see. Agent wakes also carry the events that woke the agent, and the transcript shows them as a banner.

## Decision

1. **Every type is a decision.** Every event type that intentd can emit on a channel a store consumes must be named in that store's classification tables.
2. **Golden catalog.** The catalog is the vendored intentd golden `IntentTests/Fixtures/event_types.json` (`crates/intent-core/tests/goldens/event_types.json` in intent-hq/intentd). Re-vendor it when the daemon adds a type, then classify the new type.
3. **Discriminated types.** For a type with a discriminator, every golden value (or `changes` key) must be named and must classify as the test spells out. The test does not read the expectation from the store's table, so a flipped table entry fails. The `absent` shape must also classify as expected. For `keys` discriminators a refetch key dominates a patch-in-place key.
4. **Examples.**
   1. `task:ready-tasks-changed`: only `note-deleted` means a row left the list. `relations-changed` and the reason-less status-change shape are covered by other events.
   2. `workspace:updated`: only a `lastActivity`-only delta is patched in place. Every other key, and a missing `changes`, refetches.
5. **Global subscription.** A store's tables do nothing unless `ConnectionManager` subscribes to the channel globally (`globalEventTypes`).
6. **No stale entries.** A table entry that the catalog does not contain is a typo or a type the daemon no longer emits. The test fails on it.
7. **Wake labels.** The wake banner dedupes category labels (two `file:*` events show one "File changes"). Machine identifiers never show verbatim in the banner.

## Consequences

- A daemon release that adds an event type fails `EventCatalogCoverageTests` until a store classifies it.

## Code

- `EventCatalogCoverageTests`
- `ConnectionManager`: `globalEventTypes`
- `EventWakeAttribution`: `from(_:)`, `summaryLabel`, `looksLikeAgentId(_:)`
