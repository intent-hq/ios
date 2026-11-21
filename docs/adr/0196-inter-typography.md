# ADR-0196: Inter typography tokens

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `Constants.Typography` (`Intent/DesignSystem/Typography.swift`),
  `Constants.Typography.Style.uiFont(compatibleWith:)` (`Intent/DesignSystem/Typography+UIKit.swift`),
  `View.interFont(_:)` (`Intent/DesignSystem/InterFontModifier.swift`)

## Decisions

### 1. Source and scope of the styles

Applies to: `Constants.Typography`

The styles are Inter styles from the IOS Working Figma page. Sizes are the
`.large` Dynamic Type baseline. Regular and Medium are static 450 and 550
instances of Inter 4.1; SemiBold is 600. Regenerate them with
`scripts/generate-inter-instances.py`. Tracking stays scoped to each design.
Apply the styles to text only; keep native control, SF Symbol and monospaced
fonts. Use `interFont` on SwiftUI text for Bold Text support. Unsupported
scripts and emoji use the platform's glyph fallback; Inter does not cover every
Unicode character.

Figma tracking is a percent of point size. Native line boxes include leading
that Figma trims: keep the visible text gap, and never force Figma's trimmed
line-box heights on native text.

### 2. Token mapping

| Style | Figma token | Size/weight | Scaling role and use |
| --- | --- | --- | --- |
| `heading1` | IOS/IOS H1 | 40/600 | Large title; prominent custom page headings |
| `heading2` | IOS/IOS H2 | 28/600 | Title; custom screen and section headings |
| `bodyM` | IOS/IOS Body M | 18/550 | Headline; primary row titles |
| `bodyS` | IOS/IOS Body S | 16/450 | Body; prose and action descriptions |
| `bodySEmphasized` | IOS/IOS Body S Bold | 16/550 | Body; emphasis changes the face, not the scaling role |
| `bodyXS` | IOS/IOS Body XS | 14/450 | Subheadline; secondary supporting text |
| `bodyXSEmphasized` | IOS/IOS Body XS Bold | 14/550 | Subheadline; shares the secondary-text role |
| `subtextXXS` | IOS/IOS Subtext XXS | 12/450 | Caption; timestamps and compact metadata |
| `eyebrow` | IOS/IOS Eyebrow | 12/450 | Caption; small group labels, no forced uppercase |

### 3. Scaling and faces

Applies to: `Style.font`, `Style.withFace(_:)`, `Face.legibleFace`

SwiftUI resolves scaling from the current environment; there is no fixed size or
category cap. `withFace` keeps the size and scaling role when genuine bold or
italic is required. Accessibility emphasis (`legibleFace`) is separate from the
documented Figma "Bold" tokens.

### 4. `interFont` applies only to text

Applies to: `View.interFont(_:)`

Apply `interFont` only to text and text inputs, never to a screen or a Label's
symbol. Custom fonts scale with Dynamic Type but need an explicit face for Bold
Text.

### 5. UIKit fonts are resolved from traits

Applies to: `Style.uiFont(compatibleWith:)`

`uiFont` is for UIKit text and attributed runs. Supply the view's current traits,
and resolve again when they change. Do not scale this already-scaled font a
second time. Textual attachment measurement also resolves fonts outside the main
actor, so the method is nonisolated.
