# ADR-0121: The workspace text file viewer uses TextKit 2 with fixed-height lines

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceTextFileView` (`Intent/Views/Conversation/Content/WorkspaceTextFileView.swift`), `LineNumberTextView` (`Intent/Views/Conversation/Content/LineNumberTextView.swift`)

## Context

Workspace text files can be large. The viewer shows them with optional line
wrapping and a line-number gutter.

## Decisions

### 1. TextKit 2 lays out only the visible viewport

Applies to: `WorkspaceTextFileView`

TextKit 2 lays out the visible viewport, rather than one giant SwiftUI `Text`.
The viewer keeps its native selection and scrolling. Never access the legacy
`layoutManager`.

### 2. Every line has the same fixed height

Applies to: `LineNumberTextView.applyLineHeight()`, `LineNumberTextView.linePitch`

A fixed line height keeps empty lines as tall as text lines. TextKit 2 spaces
empty paragraphs unevenly with `lineSpacing`. The height is applied again when
Dynamic Type changes the font. Every row, including empty ones, is
`linePitch` tall, and fixed-height rows put the extra space above the text.

### 3. Scroll anchoring corrects to the measured baseline

Applies to: `LineNumberTextView` (scroll anchor restore)

TextKit 2 repositions estimated fragments once the viewport lays out. After
the first restore, the view corrects the offset to the measured baseline of the
anchor line.

### 4. The text container size is applied after layout

Applies to: `LineNumberTextView` (text container sizing)

The container size is applied after the view receives its frame. This includes
a saved unwrapped preference on first presentation.
