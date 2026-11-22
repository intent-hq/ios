# ADR-0164: Toast appearance and drag

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `View.toastBackground()`, `ToastButtonStyle` (`Intent/Views/Components/ToastBackground.swift`), `ToastView` (`Intent/Views/Components/ToastView.swift`)

## Decisions

### 1. Light mode uses frosted Liquid Glass; dark mode uses thin material

Applies to: `View.toastBackground()`

Light mode uses frosted Liquid Glass so the banner separates from light content.
Dark mode keeps the thin material, which already contrasts.

### 2. Only the material banner dims on press

Applies to: `ToastButtonStyle`

Interactive glass gives its own press feedback, so only the dark-mode material
banner dims when pressed.

### 3. Light mode uses the completed-task fill for the completion icon

Applies to: `ToastView.completionIcon`

Light glass washes out the lime outline, so light mode uses the completed-task
fill instead.
