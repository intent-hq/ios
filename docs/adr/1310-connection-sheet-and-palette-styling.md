# ADR-1310: Connection sheet styling and the exact design palette

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `Constants.DesignPalette` (`Intent/DesignSystem/DesignPalette.swift`),
  `ConnectionBackdropPreference`, `ConnectionSceneBackdrop`, `Constants.ConnectionSheet`,
  `Constants.ManualTokenEntry` (`Intent/DesignSystem/ConnectionSheetStyle.swift`),
  `ConnectionSwitcherStyle` (`Intent/DesignSystem/ConnectionSwitcherStyle.swift`),
  `Constants.Connections` (`Intent/DesignSystem/SavedConnectionStyle.swift`),
  `Constants.Pairing` colors (`Intent/DesignSystem/PairingColors.swift`)

## Context

The connection screens (Connect, Manual, Saved, switcher) follow specific Figma
frames. Colors are compared directly against the design exports, and the sheets
sit over a custom backdrop.

## Decisions

### 1. Palette values are exact 8-bit sRGB

Applies to: `Constants.DesignPalette`

The palette holds exact 8-bit sRGB values from the Figma exports, written as
`0xRRGGBB` so each constant stays directly comparable with the design file.
Callers that need an exact channel or alpha keep it as an 8-bit fraction rather
than a rounded percentage. Examples:

- `ConnectionSceneBackdrop.shadeWhite` keeps Figma Fade's `#080808` channel.
- `Constants.Connections.dividerAlpha` keeps Figma's exported `0x26` alpha.
- `Constants.ConnectionSheet` disabled colors keep Figma Grey600 in dark and
  light modes.
- `Constants.ManualTokenEntry.lightLabelForeground` keeps Grey400 for light
  labels, distinct from the Grey500 subtitle.
- `ConnectionSwitcherStyle.selection(for:)` keeps Surface/Grey700 from Figma
  3575:37803 in dark mode.
- The Saved palette in `Constants.Connections` stays directly comparable with
  the design export.

A design change starts in Figma and copies the exported values; constants are
not tuned by eye.

### 2. Pairing colors are connection-scoped

Applies to: `Constants.Pairing` colors

Connect and Manual colors come from full-frame Figma modes: dark 3051:54405,
light 3051:54203. They stay connection-scoped; the app's global `Theme` is
unchanged.

The same rule holds for every redesigned area (`Constants.Pairing`,
`Constants.Conversation.Design.Palette`, `IPadShellStyle`, `ConnectionSheet`):
it gets its own scoped palette and reuses shipped colors instead of editing a
shared palette, so a redesign of one screen never changes another.

### 3. The backdrop is requested by the presenter

Applies to: `ConnectionBackdropPreference`, `ConnectionSceneBackdrop`

The backdrop is an opt-in request from the presenting view, not from the sheet's
content. Removing that presenter also removes its preference, so no scene-global
visibility state can survive navigation or leak into another window. The
modifier lives outside the NavigationStack so content and navigation chrome get
the same effect. Native sheets keep their own foreground and touch shield.

`manualOpacity` and `savedOpacity` are supplemental alpha beneath the system's
modal dimmer. They are not the Figma alpha values: the rendered composition must
be compared.

### 4. Sheet geometry and initial heights

Applies to: `Constants.ConnectionSheet`, `Constants.ManualTokenEntry.initialSheetHeight`,
`Constants.Connections.initialSheetHeight`

`Constants.ConnectionSheet` is reusable destination-sheet geometry from Manual
frames 2989:19990 / 2989:20026. Manual's shared palette is supplied explicitly,
which preserves other sheet callers. Nil sheet overrides keep the appearance
used by unmodified destinations such as Details (`defaultBackground(for:)`).

`ManualTokenEntry.initialSheetHeight` is the Figma content height excluding the
native home-indicator safe area. The sheet replaces this initial estimate with
measured, scalable content.

`Connections.initialSheetHeight` comes from Saved frame 3051:54118. The shared
sheet replaces this two-card estimate with measured content; neither the row
count nor the text height is capped.

In general, Figma heights are visual baselines, never caps on text: Dynamic Type
and platform hit targets win.
