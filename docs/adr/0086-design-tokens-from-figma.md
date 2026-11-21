# 0086. Design tokens from Figma

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The iOS screens follow approved Figma frames. Designers compare the running app with those frames, and a redesign of one screen must not change another. Native text layout, Dynamic Type and Bold Text differ from the Figma model, so some values cannot be copied as they are.

## Decision

1. **Exact colors.** `DesignPalette` stores Figma's exported 8-bit sRGB values as `0xRRGGBB`, and alpha as an 8-bit byte (`EightBitChannel.fraction(_:)`), not a rounded percentage. Each constant stays comparable with the design file.
2. **Scoped palettes.** A redesigned area gets its own palette and reuses shipped colors without changing other palettes. The global theme does not change. Examples: `Constants.Pairing` (Connect and Manual), `Constants.Conversation.Design.Palette`, `IPadShellStyle`, `ConnectionSheet`. Nil sheet overrides keep the appearance of destinations that were not redesigned, such as Details.
3. **Composed, not copied, where the system adds layers.** The connection backdrop's `manualOpacity` sits under the system's modal dimmer, so it is not the Figma alpha; compare the rendered composition. `ConnectionSceneBackdrop` sits outside the `NavigationStack`, so content and navigation chrome get the same effect; native sheets keep their own foreground and touch shield.
4. **Backdrop state.** `ConnectionBackdropPreference` is set by the presenting view, not by the sheet content. When the presenter goes, its preference goes, so no scene-global visibility state survives navigation or leaks into another window.
5. **Sizes are baselines, not caps.** Figma heights are visual baselines. They never cap text; Dynamic Type and platform hit targets win. A sheet's `initialSheetHeight` is an estimate that measured content replaces; row count and text height are not capped.
6. **Opt-in redesigns.** iPad opts in to `Constants.Conversation.Design` explicitly. Other regular-width callers and visionOS stay unchanged.
7. **Typography.**
   1. `Constants.Typography` holds the Inter styles from the "IOS Working" Figma page. Sizes are the `.large` Dynamic Type baseline, and each style scales relative to a system text style. There is no fixed size and no category cap.
   2. Regular and Medium are static 450 and 550 instances of Inter 4.1; SemiBold is 600. Regenerate them with `scripts/generate-inter-instances.py`.
   3. Apply Inter to text and text inputs only. Native controls, SF Symbols and monospaced fonts keep their fonts. Scripts and emoji that Inter does not cover use the platform fallback.
   4. Use `interFont(_:)` on SwiftUI text: custom fonts scale with Dynamic Type but need an explicit face for Bold Text (`legibleFace`). Accessibility emphasis is separate from the Figma "Bold" tokens.
   5. `uiFont(compatibleWith:)` is for UIKit text. Pass the view's current traits and resolve again when they change. Do not scale the result a second time. It is `nonisolated` because Textual measures attachments off the main actor.
   6. Figma tracking is a percent of point size, and each design keeps its own tracking. Native line boxes include leading that Figma trims: keep the visible text gap, and never force Figma's trimmed line-box heights on native text.
8. **Readable column.** `conversationReadableColumn()` keeps one structural identity as the window or sidebar resizes.
9. **Copy passthrough.** In a transcript row, every `IntentButtonStyle` button sets `passesThroughCopyMenu`, which puts a rectangular passthrough marker behind the whole pill, so taps on its padding reach the button inside the row's copy overlay. Taps in the corners outside the rounded pill reach neither the button nor Copy. `CopyContextMenuPassthroughPolicyTests` enforces this.

## Consequences

- A design change starts in Figma and copies the exported values; it does not tune constants by eye.
- A redesign adds a scoped palette instead of editing a shared one.

## Code

- `DesignPalette`, `EightBitChannel`, `Color(sRGBHex:)`
- `Constants.Pairing`, `Constants.Conversation.Design`, `Constants.Conversation.Design.Palette`, `IPadShellStyle`, `ConnectionSheet`
- `ConnectionBackdropPreference`, `ConnectionSceneBackdrop`
- `Constants.Typography`: `Style`, `legibleFace`, `font`, `uiFont(compatibleWith:)`; `interFont(_:)`
- `conversationReadableColumn()`
- `IntentButtonStyle`: `passesThroughCopyMenu`
