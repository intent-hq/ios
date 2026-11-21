# ADR-0139: The add-agent specialist picker shares the session options cache

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `SpecialistPickerView` (`Intent/Views/Workspaces/SpecialistPickerView.swift`), `SpecialistStepView` (`Intent/Views/Workspaces/SpecialistStepView.swift`), `ProviderModelStepView` (`Intent/Views/Workspaces/ProviderModelStepView.swift`)

## Context

`SpecialistPickerView` adds an agent to a workspace in two steps: specialist
and name, then provider and model. It reads the same specialist, provider and
model cache as Create Workspace (ADR-0138).

## Decisions

### 1. The options cache is session-owned, with the same wiring as Create Workspace

Applies to: `SpecialistPickerView.optionsStore`, `SpecialistPickerView.isLoadingOptions`

`CreationOptionsStore` outlives the sheet, so a reopen renders the cached
lists instantly while the store revalidates in the background. This is the
same wiring as `CreateWorkspaceView`.

`isLoadingOptions` derives from the store, never from a local snapshot. A
cache that warms between construction and the step's load drops the loading
state on its own. A reconnect clear drives it back on while the store reloads
cold.

### 2. `settledLoads` records the sheet's own returned loads

Applies to: `SpecialistPickerView.settledLoads`

`settledLoads` records the options load and the model load per provider. A
settled load that failed shows the empty state or the daemon-default row
instead of spinning forever. A marker is published only for a load that
returned in the store generation it started in.

### 3. Specialists stay in daemon order

Applies to: `SpecialistPickerView.specialists`

The picker shows the pickable specialists (`modalPickable`) in daemon order.

### 4. An old provider's response cannot become the current list

Applies to: `SpecialistPickerView.models`

`models` is the selected provider's cached catalog, empty until loaded. An
older provider's response can only land in its own cache slot, so it never
presents as the current selection's list.

### 5. Reconcile on swapped lists, provider picks and reconnects

Applies to: `SpecialistPickerView.body`

A background revalidation or a reconnect reload swaps the cached lists under
the open sheet, and the selections must stay valid. The specialist list is
observed by value, not by id, so a same-id metadata change (a provider signing
out, a specialist turning hidden) reconciles.

A user pick in the Provider menu clears the explicit model: an explicit model
never survives a provider switch. The new provider's catalog is instant when
cached and loaded cold otherwise.

A reconnect hard-clears the store. The sheet reloads (joining the store's own
cold reload) and re-warms the selected provider's catalog, so the open step
never sits loading forever on a cleared cache.

### 6. Cold and cached loads

Applies to: `SpecialistPickerView.loadOptions()`

Cold (nothing cached): the sheet awaits the specialist and provider load while
`isLoadingOptions` shows. Cached: the steps already render the cached lists,
the store revalidates in the background, and no spinner shows. A load
superseded by a reconnect clear publishes nothing. The `loadGeneration` change
starts a fresh load that settles and reconciles.

### 7. Specialist and provider defaults

Applies to: `SpecialistPickerView.reconcileSpecialistSelection()`, `SpecialistPickerView.reconcileProviderSelection()`

The specialist defaults to the orchestrator, else the first pickable
specialist. It is re-defaulted or cleared when the selected specialist left
the pickable set. A changed selection renames the agent unless the user
already edited the name.

The provider defaults to a selectable provider, with auggie first, and its
model catalog loads: instant when cached, awaited when cold. An explicit model
never survives a provider switch.

### 8. The programmatic-name flag is armed only on a real change

Applies to: `SpecialistPickerView.applyName(from:)`, `SpecialistPickerView.isSettingNameFromSpecialist`

`onChange(of: agentName)` only fires on a real change. The "programmatic
write" flag is therefore armed only when the name changes. Otherwise it would
swallow the user's next edit.

### 9. The Next button keeps its full width in the toolbar

Applies to: `SpecialistStepView.body`

Toolbars can compress the padded Next label to an ellipsis (for example
"N…"). `.fixedSize(horizontal: true, vertical: false)` keeps its full width on
every device.

### 10. Provider sign-in is a desktop flow

Applies to: `ProviderModelStepView.noProvidersSignedInPlaceholder`

The placeholder shows when providers exist but none are signed in. Provider
sign-in flows run on the desktop seat and are not available on iOS.
