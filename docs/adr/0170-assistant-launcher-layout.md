# ADR-0170: Assistant launcher layout

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AssistantLauncherLayout` (`Intent/Views/Components/AssistantLaunchButton.swift`)

## Decisions

### 1. One type owns the launcher geometry

Applies to: `AssistantLauncherLayout`

`AssistantLauncherLayout` keeps the visible control, the hit shape, the menu
anchor, and the scroll clearance together, so they cannot drift apart.
