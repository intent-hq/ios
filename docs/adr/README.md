# Architecture decision records

These records hold the non-obvious decisions behind the app code in `Intent/`.
They were moved out of code comments. The code does not point back to them, so
each record names the types and files it applies to.

## Numbering

The first two digits give the area. Numbers are not reused.

| Range | Area |
| --- | --- |
| 01xx | `Intent/App`, `Intent/ViewModels` |
| 02xx | `Intent/Models`, persistence files in `Intent/` |
| 03xx | `Intent/Presentation` |
| 04xx | `Intent/Services`: `Agent…` to `ConnectionTypes` |
| 05xx | `Intent/Services`: `Conversation…` to `InvitedSyncKey` |
| 06xx | `Intent/Services`: `InvitedSyncMerge` to `TransportDiagnosticFailure` |
| 07xx | `Intent/Services`: `WebSocket…` to `WorkspaceVideo` |
| 08xx | `Intent/Views/Conversation`: top level, `Composer`, `Content`, `Notices` |
| 09xx | `Intent/Views/Conversation`: `Questions`, `StatusStrip`, `Transcript` |
| 10xx | `Intent/Views/Workspaces`: `AgentModelFields` to `WorkspaceChangesView` |
| 11xx | `Intent/Views/Workspaces`: `WorkspaceCommitDetailsView` to `WorkspaceTransferSheet` |
| 12xx | `Intent/Views`: `Agents`, `Components`, `Connection`, `Notes`, `Onboarding`, `Settings` |
| 13xx | `Intent/Utils`, `Intent/DesignSystem`, `Intent/LiveActivity` |
| 14xx | `Intent/Demo` |

## Format

File name: `NNNN-short-kebab-title.md`. One record covers one topic: a type, a
family of types, or one feature flow.

```markdown
# ADR-NNNN: Title

- Status: Accepted
- Recorded: YYYY-MM-DD (moved from code comments; the decisions are older)
- Applies to: `Type` (`Intent/Path/File.swift`), …
- Related issues: ios#123, … (omit the line when there are none)

## Context

What the code does and what problem made a decision necessary.

## Decisions

### 1. Short statement of the decision

Applies to: `Type.member`

The decision, the reason, and what breaks if it is changed.

## Consequences

What callers and future changes must respect. Omit when the decisions say it all.
```

## Rules

1. Record only what the code cannot show: reasons, invariants, ordering
   constraints, protocol contracts, rejected alternatives, platform behavior.
2. Do not record a reason that is not known. Write what was decided and stop.
3. Name symbols and files. Do not use line numbers.
4. When a decision changes, edit its record in the same change, or add a new
   record and mark the old one `Superseded by ADR-NNNN`.
