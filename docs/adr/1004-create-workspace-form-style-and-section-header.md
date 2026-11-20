# ADR-1004: Create Workspace form styling and the collapsible section header

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `CreateWorkspaceFormStyle`, `CreateWorkspaceRepoStyle` (`Intent/Views/Workspaces/CreateWorkspaceFormStyle.swift`), `CollapsibleSectionHeader` (`Intent/Views/Workspaces/CollapsibleSectionHeader.swift`)

## Decisions

### 1. Disabled colors are mixed over the form, not faded

Applies to: `CreateWorkspaceFormStyle.disabledBackground(for:)`

The disabled colors of Figma node 2989:23630 are resolved by mixing over the
form background, so the button itself is not faded with opacity.

### 2. One style for repository and branch selection

Applies to: `CreateWorkspaceRepoStyle`

`CreateWorkspaceRepoStyle` is the shared presentation for both the repository
step and the branch step.

### 3. The header leaves label styling to callers

Applies to: `CollapsibleSectionHeader`

`CollapsibleSectionHeader` is an eyebrow heading that collapses or expands
the content below it, with a trailing chevron. Callers style the label and
set the foreground.

### 4. Insets belong to the tap target

Applies to: `CollapsibleSectionHeader.insets`

`insets` is spacing around the heading that still belongs to the tap target.

### 5. The whole heading toggles; only the chevron shows the hover

Applies to: `CollapsibleSectionHeader.body`

The whole heading is the button, but on visionOS only the chevron lights up
(`visionGroupedHoverHint`).
