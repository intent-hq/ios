# ADR-0144: Workspace attention cue on visionOS

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `workspaceNeedsInput(_:)`, `WorkspaceAttentionCueTracker`, `WorkspaceAttentionCueCenter`, `View.visionAttentionCue(_:reduceMotion:)`, `View.visionAttentionChipBrightness(_:)`, `View.visionWorkspaceAttentionSound(_:)`, `VisionWorkspaceAttentionSoundModifier` (`Intent/Views/Workspaces/WorkspaceAttentionCue.swift`), `WorkspaceAttentionCuePresentation` (`Intent/Views/Workspaces/WorkspaceActionMenuDepth.swift`)

## Context

On visionOS, a workspace row that needs user input gets a depth cue, a
brighter status chip and a one-shot sound. The same agent event can also
trigger the agent-completion alert chime in `NotificationManager`.

## Decisions

### 1. What "needs input" means

Applies to: `workspaceNeedsInput(_:)`

A workspace needs input when its display status is a blocker or attention
status (blocker, discussion, question, plan approval), or when the
server-owned unread attention flag is set. This drives the visionOS attention
cue: z-lift, brighter status chip and one-shot sound. The unread part clears
through `workspace.markSeen` on open. The status part clears when the request
resolves.

### 2. The tracker primes silently and reports only new items

Applies to: `WorkspaceAttentionCueTracker`, `WorkspaceAttentionCueTracker.observe(universe:attention:)`

The tracker is a pure detector behind the once-per-new-item sound cue. The
first observation of a non-empty universe primes silently, so items that were
already pending at launch never chime. After that, only absent-to-present
transitions report as new. A cleared item can trigger again if its workspace
raises attention again.

`observe` takes one observation of the full workspace universe and its
attention subset. It returns the workspaces that newly entered the attention
set after the priming observation, and an empty set otherwise.

### 3. One shared center per session, idempotent observations

Applies to: `WorkspaceAttentionCueCenter`, `WorkspaceAttentionCueCenter.observe(workspaces:)`

Several list surfaces feed the center the current workspace snapshot.
Identical observations are idempotent, so dual-mounted lists never
double-chime. The center emits one cue per batch that contains at least one
workspace newly needing attention.

### 4. The window plays the cue on visionOS

Applies to: `WorkspaceAttentionCueCenter.windowEmitsCueSound`, `WorkspaceAttentionCueCenter.WindowCueEvent`, `WorkspaceAttentionCueCenter.windowCueEvent`

The cue is either a short global system sound or, where the window emits the
cue (visionOS), a `WindowCueEvent`. The session's window plays the event from
within its own scene, so spatial audio localizes the cue to the window whose
workspace list observed the new attention. The global system sound is
non-spatial on visionOS. This is the same routing that `NotificationManager`
applies to the agent-completion chime (`windowEmitsFeedbackSound`).

`windowEmitsCueSound` is injectable because tests run on the iOS simulator.

Each `WindowCueEvent` has a fresh `id`, which distinguishes back-to-back cues.
`windowCueEvent` is the latest cue for the session's window. Window roots
observe it (`WindowFeedbackSoundEmitter` in `RootView`). It is never set on
platforms that play the global system sound.

### 5. Chime and cue suppress each other per workspace

Applies to: `WorkspaceAttentionCueCenter.noteAlertChimeWillPlay(workspaceId:)`, `WorkspaceAttentionCueCenter.observe(workspaces:)`, `WorkspaceAttentionCueCenter.lastAlertChime`, `WorkspaceAttentionCueCenter.lastCueSound`

`lastAlertChime` and `lastCueSound` hold per-workspace timestamps of the last
audible trigger of each kind. A timestamp is recorded only when a sound
actually played or was published.

`NotificationManager` calls `noteAlertChimeWillPlay` just before it plays or
publishes the agent-completion alert chime for a workspace. The method returns
whether the chime should play audibly. It returns false when this center
sounded the attention cue for the same workspace within `dedupInterval`,
because the same agent event already produced an audible cue. When it returns
true, it records the chime, so an attention flip for the workspace right
after it stays silent.

`observe` drops new workspaces whose alert chime just sounded (the same agent
event). The batch stays silent only when a chime covered every new item.

### 6. The depth cue is single-step and gentle

Applies to: `View.visionAttentionCue(_:reduceMotion:)`, `View.visionAttentionChipBrightness(_:)`

The cue is a subtle, single-step visionOS depth cue for rows that need input:
a slight z-lift plus scale, animated once on a state change. There is no
continuous animation, following the HIG guidance for gentle, non-looping
attention cues. Other platforms get no cue. The status chip brightens on
visionOS while its workspace needs input, pairing with the row's depth cue.

### 7. The open Intent menu suppresses raised rows

Applies to: `WorkspaceAttentionCuePresentation`, `View.visionAttentionCue(_:reduceMotion:)`

`WorkspaceAttentionCuePresentation` is how a row's attention cue presents
relative to the Intent menu:

- `raised`: needs input. The row lifts slightly toward the viewer.
- `resting`: no pending input. The row stays in the window plane.
- `suppressed`: needs input while the Intent menu is open. The row is
  invisible, takes no input and is absent from accessibility until the menu
  closes.

While the menu is open, raised rows are hidden entirely, so nothing competes
with the menu's action cards. This is presentation only: the workspace and its
server-owned unread flag are never marked read, filtered or changed, so rows
that still apply return raised when the menu closes.

The hidden state is not animated. A row suppressed while the menu opens, or a
row raising attention under the open menu, never shows a lift on the way.

### 8. Sound feed per session window

Applies to: `View.visionWorkspaceAttentionSound(_:)`, `VisionWorkspaceAttentionSoundModifier`

Attach the modifier to each workspace list surface. It feeds workspace
snapshots to the window session's cue center, so a short system sound plays
once per workspace that newly needs input (visionOS only). Routing to the
session's center makes pinned windows chime for their own backend. When no
session is in the environment (previews and tests), it falls back to the
shared center.
