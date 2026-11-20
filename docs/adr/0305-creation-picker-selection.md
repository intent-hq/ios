# ADR-0305: Creation pickers keep valid selections across catalog reloads

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `CreationSelectionPolicy` (`Intent/Presentation/CreationSelectionPolicy.swift`), `SpecialistPickerView` selection helpers (`Intent/Presentation/SpecialistPickerSelection.swift`), `SpecialistModelFetchOutcome` (`Intent/Presentation/SpecialistModelFetchOutcome.swift`)
- Related issues: monorepo#1003

## Context

The workspace and agent creation flows let the user pick a specialist, a
provider, a model and a reasoning effort. The catalogs reload on reconnect and
can change under an open sheet. `CreationSelectionPolicy` holds the stateless
selection rules shared by both flows.

## Decisions

### 1. A selection is kept only while the catalog still offers it

Applies to: `SpecialistPickerView.reconciledSpecialist(current:catalog:)`, `CreationSelectionPolicy.preselectedWorkspaceSpecialist(current:catalog:)`, `CreationSelectionPolicy.preselectedProvider(current:providers:)`

A specialist selection is kept while the id of `current` is still pickable in
the unfiltered `catalog`. It is rebound to the fresh entry, so the picker shows
refreshed metadata (for the workspace picker, the default-model preview).
Otherwise the selection falls back to the resolved orchestrator
(PROTOCOL §5.11), then to the first pickable specialist in daemon order, then
to nil when nothing is pickable. A hidden id must never be submitted.

A provider selection is kept while it is still selectable, rebound to the
fresh entry. Otherwise it falls back to auggie when selectable, then to the
first selectable provider, then to nil. With nil, the picker shows setup
guidance.

An empty catalog or provider list (a cold load or a reconnect clear) keeps
`current`, so the selection survives the reload.

### 2. Workspace provider enablement is authoritative

Applies to: `CreationSelectionPolicy.preselectedWorkspaceProvider(current:providers:)`, `CreationSelectionPolicy.reconcileWorkspaceProvider(provider:model:state:)`

Workspace enablement is authoritative even when it is empty or unavailable.
A provider that this host no longer offers is never retained. While validation
is pending (`idle`, `loading`), the draft is preserved, but that is not
permission to submit it. Only a completed policy result can replace or clear
the selection.

### 3. The workspace specialist list pins the orchestrator

Applies to: `CreationSelectionPolicy.workspacePickerSpecialists(_:)`

The list is the modal-pickable set (no hidden or internal specialists), with
the orchestrator first and the rest sorted by name.

### 4. An explicit model is kept only for the same provider

Applies to: `CreationSelectionPolicy.reconciledModel(current:models:)`, `CreationSelectionPolicy.workspaceReasoningLevels(provider:model:models:)`

An explicit model is kept only while the displayed catalog still lists it for
the same provider, rebound to the fresh entry. In every other case (the model
was retired, the catalog was cleared, or a provider switch whose catalog
reuses the bare id) the selection falls back to the daemon default (nil).

Only an explicit model in the current provider's catalog proves which efforts
can be offered. A default-model preview is advisory, not a pin.

### 5. Nil reasoning effort means Auto

Applies to: `CreationSelectionPolicy.reconciledReasoningEffort(current:effortLevels:)`

Nil means Auto: `reasoningEffort` is omitted and the daemon's defaults apply.
A blank string is never sent, because it would explicitly clear those defaults.

### 6. Create is disabled until the selection can be submitted

Applies to: `SpecialistPickerView.isCreateDisabled(...)`

The Create action is unavailable while required selections are absent, while
loading is active, or when no provider can be selected (monorepo#1003).

### 7. Settled-load markers are gated by the load generation

Applies to: `SpecialistPickerView.SettledLoads`

The sheet's settled-load markers are gated by the store's `loadGeneration`. A
marker is published only when the load returned in the generation it started
in. A load superseded by a reconnect clear (`invalidate()`) returns for a cache
that the store already dropped. Settling on it would show the daemon-default
row and enable Create while the fresh load for the same provider is still
pending. `reset()` is the reconnect clear: every marker belonged to the dropped
cache.

### 8. `agent.create` omits the daemon defaults

Applies to: `SpecialistPickerView.buildCreateAgentSelection(provider:model:)`

The provider is omitted when it is auggie, because auggie is the daemon
default. The model is sent only when one is selected for that provider.

### 9. Model fetch outcomes

Applies to: `SpecialistModelFetchOutcome`

- `noModelUpdate`: the request is current, but its provider is no longer
  selected.
- `replaceModels`: the request is current, and its model catalog replaces the
  visible one.
- `superseded`: a newer request owns all model and loading state.
