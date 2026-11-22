# ADR-0174: Connection sheet and saved connection cards

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConnectionSheet` (`Intent/Views/Connection/ConnectionSheet.swift`), `ConnectionSheetText` (`Intent/Views/Connection/ConnectionSheetText.swift`), `SavedConnectionCard` (`Intent/Views/Connection/SavedConnectionCard.swift`), `SavedConnectionDetails` (`Intent/Views/Connection/SavedConnectionDetails.swift`), `ConnectionPairingButtons` (`Intent/Views/Connection/ConnectionPairingButtons.swift`)

## Decisions

### 1. Native sheet chrome with a measured detent

Applies to: `ConnectionSheet`

The connection destinations share native sheet chrome. The detent follows the
measured content, while the system limits tall sheets and manages the keyboard.

### 2. Text spacing is measured at Figma's edges

Applies to: `ConnectionSheetText`

Figma measures from cap top to last baseline. The view keeps the full native
glyphs (including descenders) and wrapping, but measures spacing at those same
edges.

### 3. Presenting screens own behavior

Applies to: `SavedConnectionCard`, `ConnectionPairingButtons`

`SavedConnectionCard` is a shared card label; selection and management remain
owned by each presenting screen. `ConnectionPairingButtons` are shared pairing
actions; each presenting screen owns pairing and dismissal. The laptop icon
matches Figma for all saved connections.

### 4. Saved connection details never show secrets

Applies to: `SavedConnectionDetails`

The details are secondary metadata, reached through the card's existing
context-menu affordance. They never render the saved API token or the
certificate fingerprint.
