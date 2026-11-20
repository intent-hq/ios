# ADR-0306: iPad panes stay retained, and focus is scoped to the visible pane

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationPresentation`, `EnvironmentValues.isIPadPaneVisible` (`Intent/Presentation/ConversationPresentation.swift`), `IPadTypingFocus`, `IPadTypingFocusRow`, `ConversationFocusHeaderInset` (`Intent/Presentation/IPadTypingFocus.swift`), `IPadPaneBounds`, `IPadNavigationVisibilityBridge` (`Intent/Presentation/RetainedIPadPane.swift`)

## Context

The iPad shell keeps panes alive while they are hidden, and it has a typing
focus mode where the conversation fills a focus panel.

## Decisions

### 1. iPad chrome is an explicit presentation policy

Applies to: `ConversationPresentation`

The presentation is explicit, not derived from width: a narrow iPad window
still has iPad chrome.

### 2. Hidden panes keep state but give up keyboard focus

Applies to: `EnvironmentValues.isIPadPaneVisible`, `RetainedIPadPane`

Hidden iPad panes retain their state but must relinquish keyboard focus.

### 3. Input focus drives the conversation focus mode

Applies to: `IPadTypingFocus`, `IPadTypingFocusRow`, `ConversationFocusHeaderInset`

Input focus controls the retained iPad conversation pane: focus moves it to
`conversationEditing`. `IPadTypingFocusRow` keeps the same editor subtree while
the close control next to it appears. `ConversationFocusHeaderInset` hides only
the navigation chrome while the existing conversation fills its focus panel.

### 4. Pane bounds add no accessibility container

Applies to: `IPadPaneBounds`

`IPadPaneBounds` scopes visibility without adding another accessibility
container. Retained panes already group their children. An outer group around
native content can claim window-sized bounds after focus changes and obscure
adjacent controls.

### 5. Hidden navigation stacks are hidden through UIKit

Applies to: `IPadNavigationVisibilityBridge.Controller.applyVisibility()`

The native children of a `NavigationStack` escape outer SwiftUI hiding. The
bridge therefore sets `accessibilityElementsHidden` and
`isUserInteractionEnabled` on the navigation controller's view, and restores
the original values when it is removed.
