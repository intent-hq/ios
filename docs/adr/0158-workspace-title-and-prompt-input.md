# ADR-0158: Workspace title editing and the creation prompt text view

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceTitleEditor` (`Intent/Views/Workspaces/WorkspaceTitleEditor.swift`), `WorkspaceDetailSupport` title field (`Intent/Views/Workspaces/WorkspaceDetailSupport.swift`), `WorkspaceTitle` (`Intent/Views/Workspaces/WorkspaceTitle.swift`), `WorkspacePromptUITextView`, `WorkspacePromptTextView` (`Intent/Views/Workspaces/WorkspacePromptTextView.swift`)

## Decisions

### 1. A read-only connection keeps the title draft

Applies to: `WorkspaceTitleEditor.save(connection:store:isReadOnly:)`, `WorkspaceDetailSupport`

While the Mac connection is read-only, the draft is kept and nothing is sent.
The draft stays in the field until the Mac is back.

### 2. The title mask keeps descenders

Applies to: `WorkspaceTitle`

Callers may trim the frame to cap height and baseline, so the mask extends
vertically by `maskOutset` to keep descenders unmasked.

### 3. The creation prompt keeps Return as a newline

Applies to: `WorkspacePromptUITextView`

The text view is scoped to workspace creation: Return remains a newline on
every device.

### 4. Image paste never reads the clipboard early

Applies to: `WorkspacePromptUITextView.canPerformAction(_:withSender:)`, `WorkspacePromptUITextView.paste(_:)`

`hasImages` is a metadata check. The view never reads clipboard content on
render or focus. Both edit-menu Paste and Command-V use the `paste(_:)`
responder action.

### 5. The native editor fills the prompt's blank area

Applies to: `WorkspacePromptTextView.sizeThatFits`

The native editor must fill the prompt's blank area so taps can focus it. A
minimum frame on its SwiftUI container only adds non-editable space.
