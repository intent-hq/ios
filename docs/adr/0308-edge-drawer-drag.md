# ADR-0308: Edge drawer drags are computed in the drawer's opening frame

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `EdgeDrawerSide`, `EdgeDrawerDrag` (`Intent/Presentation/EdgeDrawerDrag.swift`)

## Decisions

### 1. Drawer sides are physical screen sides

Applies to: `EdgeDrawerSide`

`EdgeDrawerSide` names the physical screen side a drawer slides out from
(`left`, `right`), not a layout direction.

### 2. Drag rules use one opening frame

Applies to: `EdgeDrawerDrag`, `towardOpening(_:side:)`, `distanceFromEdge(_:width:side:)`

The drag rules are shared by the edge drawers. Every value is in the drawer's
opening frame: a distance from its own edge, positive toward opening.
`towardOpening` converts screen-space translation or velocity into that frame,
and `distanceFromEdge` converts a screen-space x position.
