# 0066. Creation picker selection

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The workspace creation flow and the agent picker select a specialist, provider, model and reasoning effort from catalogs that reload on reconnect and can change on the host.

## Decision

1. **Keep, rebind, fall back.**
   1. A selection is kept while its id is still pickable, and is rebound to the fresh entry so refreshed metadata shows.
   2. Specialist fallback: the orchestrator (PROTOCOL §5.11), else the first pickable specialist in daemon order, else nil. A hidden id is never submitted.
   3. Provider fallback: `auggie` when selectable, else the first selectable provider, else nil; the picker then shows setup guidance.
   4. An empty catalog (cold load or reconnect clear) keeps the current selection, so it survives the reload.
2. **Workspace providers.** Workspace enablement is authoritative even when empty or unavailable; a provider the host no longer offers is dropped. Pending validation keeps the draft but does not permit submit. Only a completed policy result replaces or clears the selection.
3. **Workspace specialists.** The picker lists the modal-pickable set (no hidden or internal specialists), orchestrator first, then by name.
4. **Models.** An explicit model is kept only while the shown catalog lists it for the same provider. Otherwise it falls back to the daemon default (nil). A provider switch whose catalog reuses the bare id does not keep it.
5. **Reasoning effort.** Only an explicit model in the current catalog proves which efforts can be offered. A default-model preview is advisory. Nil means Auto: omit `reasoningEffort`. Never send a blank string, which would clear the daemon's defaults.
6. **Loads.** A settled-load marker is published only when the load returns in the generation it started in. A load superseded by a reconnect clear must not settle, or Create would enable on a stale cache. A newer model request owns all model and loading state (`SpecialistModelFetchOutcome.superseded`).
7. **Create.** Create is disabled while a required selection is absent, loading is active, or no provider can be selected (monorepo#1003). `agent.create` omits the provider when it is `auggie` (the daemon default) and sends a model only when one is selected.
8. **Agent name.** In the agent picker, a changed specialist renames the agent unless the user already edited the name. The programmatic-write flag is armed only when the name really changes, because `onChange(of:)` fires only on a real change and would otherwise swallow the user's next edit.

## Code

- `CreationSelectionPolicy`: `preselectedWorkspaceProvider`, `reconcileWorkspaceProvider`, `workspacePickerSpecialists(_:)`, `preselectedWorkspaceSpecialist`, `preselectedProvider`, `reconciledModel(current:models:)`, `workspaceReasoningLevels`, `reconciledReasoningEffort(current:effortLevels:)`
- `SpecialistPickerView`: `isCreateDisabled`, `reconciledSpecialist`, `SettledLoads`, `buildCreateAgentSelection`
- `SpecialistModelFetchOutcome`
