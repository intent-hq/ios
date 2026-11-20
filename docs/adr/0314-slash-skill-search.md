# ADR-0314: Slash skill search lowercases the catalog once

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `SkillSearchIndex` (`Intent/Presentation/SlashSkillContext.swift`)

## Decisions

### 1. The index is built once per catalog

Applies to: `SkillSearchIndex`

`SkillSearchIndex` lowercases every skill name and description once per
catalog, so each query only matches and sorts.
