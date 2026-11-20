# 0083. Desktop parity ports

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Some iOS helpers port a function from the desktop app (cloudlands-fe) so both clients show the same thing for the same data. The port must keep the desktop's results, including its quirks, or the two clients disagree.

## Decision

1. **Compact durations.** `DurationFormat.compact(_:)` ports `formatCompactDuration` (en): at most two adjacent units (d/h/m/s); a zero second unit is left out, so a smaller remainder is truncated with it; rounded to the nearest second; negatives show "0s".
2. **Workspace activity order.** `workspaceActivityDisplayTime(_:)` ports `workspace-activity-time.ts`: the first parseable of `lastActivity`, `createdAt`, `updatedAt`, or 0 when none parses, so unstamped workspaces sort last. `isWorkspaceActivityMoreRecent(_:than:)` is `compareWorkspaceActivityDisplayTimeDesc`.
3. **Linked-task stats.**
   1. `TaskContentParser.parseTaskStats(content:notes:)` ports `parseTaskStats` and `TASK_LINK_REGEX_FLEXIBLE`. It is a local count over `[text](intent://local/task/{id})` links in one note, not the workspace task rollup; the daemon owns that (`task.list`).
   2. Cancelled tasks leave the total. Complete counts as completed. `in_progress` and `review_required` count as in progress. Unresolved ids and other statuses count toward the total only.
   3. The link pattern excludes line terminators, so an unclosed link cannot match a `)` on a later line.
4. **Agent avatar design.**
   1. `AgentAvatarDesign` ports `avatar-design.ts`. Its case order is the desktop catalog order and changes which fallback an agent gets.
   2. `design(agentId:specialist:icon:)` takes a valid specialist `icon` (PROTOCOL §5.11) first, then the specialist-id map, then the seeded fallback. Unknown or absent icons fall back as before icons existed.
   3. `fallbackDesign(agentId:)` matches the desktop `stringToSeededRandom(agentId).pick(...)` bit for bit. JS evaluates `seed * 1103515245 + 12345` in float64, which loses low bits for seeds from 2^22, and `& 0x7fffffff` applies ToUint32. So the LCG step is computed in `Double`, not with exact integer math.
   4. Glyph paths keep the desktop 16×16 viewBox coordinates beside their SVG paths, as in `AgentAvatarArt.svelte`. `AgentAvatarGlyph` parses only the absolute M/L/H/V/C subset the glyphs use.
5. **Hook chips.** A hook name on a chip shows at most `nameMaxLength` characters, like the desktop's max-width truncation.

## Consequences

- A desktop change to one of these functions needs the same change here.

## Code

- `DurationFormat`: `compact(_:)`
- `workspaceActivityDisplayTime(_:)`, `isWorkspaceActivityMoreRecent(_:than:)`
- `TaskStats`, `TaskContentParser`: `parseTaskStats(content:notes:)`, `linkedTaskLines(in:)`
- `AgentAvatarDesign`: `design(agentId:specialist:icon:)`, `fallbackDesign(agentId:)`, `builtinDesigns`; `AgentAvatarGlyph`
- `Constants.Conversation.StatusStrip.BackgroundHooks`: `nameMaxLength`
