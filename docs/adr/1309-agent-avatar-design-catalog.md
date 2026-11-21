# ADR-1309: The agent avatar catalog matches the desktop bit for bit

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AgentAvatarDesign`, `AgentAvatarGlyph`, `Path.init(svgPathData:)`
  (`Intent/DesignSystem/AgentAvatarDesign.swift`)

## Context

`AgentAvatarDesign` is the desktop agent avatar design catalog, ported from
cloudlands-fe `avatar-design.ts`. Built-in designs map to specialists; fallback
designs are picked deterministically from the agent id. An agent must get the
same avatar on iOS and desktop.

## Decisions

### 1. Case order is behavior

Applies to: `AgentAvatarDesign` cases

The `CaseIterable` order mirrors the desktop avatar catalog and is behaviorally
significant: it changes which fallback design an agent gets. So
`sorted_enum_cases` is disabled for the cases. A desktop catalog change needs
the same change here.

### 2. Built-in designs and lookups mirror avatar-design.ts

Applies to: `AgentAvatarDesign.builtinDesigns`, `AgentAvatarDesign.isBuiltinDesign(_:)`,
`AgentAvatarDesign.builtinSpecialistDesigns`

- `builtinDesigns` are the named designs a specialist `icon` may reference:
  everything except the seeded fallbacks (mirrors `builtinAgentAvatarDesigns`).
- `isBuiltinDesign` tells whether a specialist `icon` names a built-in design
  (mirrors `isBuiltinAgentAvatarDesign`).
- `builtinSpecialistDesigns` mirrors `builtinSpecialistAvatarDesigns`.

### 3. Resolution precedence

Applies to: `AgentAvatarDesign.design(agentId:specialist:icon:)`

Precedence: a valid specialist `icon` (PROTOCOL §5.11), then the hard-coded
specialist-id map, then the seeded fallback (mirrors `getAgentAvatarDesign`).
Unknown or absent icons degrade to the pre-icon behavior.

### 4. The fallback pick reproduces the JS arithmetic

Applies to: `AgentAvatarDesign.fallbackDesign(agentId:)`

The fallback pick is seeded from the agent id and mirrors the desktop
`stringToSeededRandom(agentId).pick(...)` (string hash plus one LCG step) bit for
bit. JS evaluates `seed * 1103515245 + 12345` in float64, losing low bits for
seeds >= 2^22, and `& 0x7fffffff` applies ToUint32. So the LCG step is computed
in `Double` here rather than in exact integer math.

### 5. Glyph geometry uses the desktop 16×16 artwork

Applies to: `AgentAvatarGlyph`, `AgentAvatarDesign.makeBuiltinGlyph(_:)`,
`Path.init(svgPathData:)`

Glyph geometry is precomputed in the desktop 16×16 viewBox space. The verbatim
16×16 artwork coordinates are kept beside their SVG paths to match
`AgentAvatarArt.svelte`, so `no_magic_numbers` is disabled there.
`Path.init(svgPathData:)` parses absolute-command SVG path data: the M/L/H/V/C
subset the desktop avatar glyphs use. Unsupported input stops parsing early.

### 6. Brand assets keep flat stroke ends

Applies to: `AgentAvatarDesign.imageResource`

Brand assets keep the flat stroke ends used by the iOS icon set.
