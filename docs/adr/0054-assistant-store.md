# ADR-0054: AssistantStore observes lazily and keeps a shown failure through a read

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AssistantStore` (`Intent/Services/AssistantStore.swift`)

## Context

`AssistantStore` lists the Assistant threads in the chief workspace and creates
and deletes them. Its history read uses `CoalescedRead`.

## Decisions

### 1. Observation starts on first use, not at init

Applies to: `AssistantStore.startObservingIfNeeded()`

Every `BackendSession`, including transient pairing sessions, owns a store.
Most never open the Assistant tab, so an eager event handler would sit on every
connection.

### 2. Read failures and action failures are separate

Applies to: `AssistantStore.loadPhase`, `AssistantStore.actionFailure`

`loadPhase` is the history read. A failed refresh keeps the threads and its
message. `actionFailure` is the last create or delete failure, independent of
the history read.

### 3. A shown failure stays until the read ends

Applies to: `AssistantStore.refresh()`

A failure that is on screen stays, with the banner and spinner together, until
the read ends.

### 4. The history read walks every page

Applies to: `AssistantStore.runRefreshPass(_:)`

Threads ascend by creation, so the newest are on the last page. Every page is
read.

### 5. A pass leaves the phase loading until the coalesced loop ends

Applies to: `AssistantStore.runRefreshPass(_:)`

A successful pass sets `.loading(lastLoadedAt:)`. `settled()` at the end of the
coalesced loop then marks the phase loaded.

### 6. The view refreshes on reconnect while unloaded or failed

Applies to: `AssistantView`, `AssistantStore.loadPhase`

`AssistantView` refreshes on reconnect while the store has not loaded or shows
an error. A read that runs after a failure keeps that gate open until it ends,
and a coalesced refresh stays loading from its first pass to its last.
