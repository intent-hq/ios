# 0067. Screen presentation state and iPad panes

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Screens open sheets, alerts and drawers through SwiftUI bindings. A closing sheet can deliver a late `false` after its successor opened. iPad windows retain panes and show a persistent sidebar.

## Decision

1. **One modal per screen.**
   1. `AgentConversationPresentation`, `QuestionWizardPresentation` and `WorkspaceChromePresentation` each hold one optional modal. At most one is open.
   2. A binding clears the modal only while it is still the closing one, so a late `false` cannot close a successor.
   3. State that must outlive modals sits next to the modal, not in it: a confirmed Delete keeps running while menus stay usable, and a dismissed question set stays dismissed while pickers stay usable.
   4. A Delete sent from the conversation navigates away on success, so the `agent:deleted` fallback must not also navigate. A failed delete restores the fallback.
   5. Dismissing questions is reported once, and not while answers submit or the connection is read-only.
   6. Create Workspace always closes the switcher. It opens the sheet only when the coordinator allows creation. `RootView` and `WorkspaceListView` change chrome only through these methods.
2. **iPad chrome.** A narrow iPad window still has iPad chrome; presentation is explicit, not a size class.
3. **Retained panes.**
   1. Hidden panes keep state but give up keyboard focus.
   2. Pane visibility adds no accessibility container. An outer group can claim window-sized bounds after focus changes and hide adjacent controls.
   3. `NavigationStack` children escape SwiftUI hiding, so the bridge sets UIKit `accessibilityElementsHidden` and restores the original value.
   4. The typing-focus row keeps the same editor subtree while its close control appears.
4. **Auto-selection.** Wide iPad windows keep a workspace open; compact windows start on the list. With nothing selected, the top visible row of the user's list opens. Row derivation is shared with the list, so "first workspace" is the row the user sees.
5. **Persistent sidebar.**
   1. The sidebar shows the open workspace beside its agent or note. Back returns both panes to the overview.
   2. The conversation hides its title only for the agent the sidebar lists. A child agent opened from the transcript keeps its title.
   3. While a read that could list the agent is in flight, the conversation does not show its title. A failed or finished read without the row hands the title back.
   4. Each sidebar copy clears only its own report.
   5. Reveal opens each known ancestor's children, and the background section when the chain ends at a background agent.
6. **Transcript disclosure.** The conversation owns disclosure state, so a row moving between lazy history and the eager tail keeps the reader's choices. Previews and other callers get local state.

## Code

- `AgentConversationPresentation`: `Modal`, `Deletion`, `dismiss(_:)`, `beginDeletion()`, `deletionFailed()`, `suppressesMissingAgentFallback`
- `QuestionWizardPresentation`: `isDismissed`, `confirmDismiss(isSubmitting:isReadOnly:)`
- `WorkspaceChromePresentation`: `createWorkspace(canCreate:)`, `setPresenting(_:_:)`
- `ConversationPresentation`, `isIPadPaneVisible`, `IPadTypingFocus`, `IPadTypingFocusRow`
- `RetainedIPadPane`, `IPadPaneBounds`, `IPadNavigationVisibilityBridge`
- `IPadWorkspaceAutoSelection`: `workspaceId(in:)`
- `WorkspaceSidebarContent`: `namesAgent(_:coordinator:)`, `WorkspaceSidebarAgents`, `namesSelection(isListed:isInitialLoadPending:isRevealPending:)`, `revealGroups(for:lookup:)`
- `WorkspaceListRows`: `sorted`, `byRepo(_:)`, `visible`
- `TranscriptDisclosureStore`, `TranscriptDisclosure`
