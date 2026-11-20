# ADR-1312: Layout constants, visionOS targets and the iPad shell

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `Constants` layout extensions (`Intent/DesignSystem/Layout.swift`),
  `Constants.IntentLogo` (`Intent/DesignSystem/ComponentLayout.swift`),
  `IPadShellLayout`, `IPadShellStyle` (`Intent/DesignSystem/IPadShellLayout.swift`),
  `Constants.Conversation.QuestionWizard` (`Intent/DesignSystem/Layout.swift`,
  `Intent/DesignSystem/QuestionWizardLayout.swift`),
  `WorkspaceDetailStyle`, `IntentContentSwitcher` (`Intent/DesignSystem/WorkspaceDetailStyle.swift`)

## Decisions

### 1. Composer targets on visionOS

Applies to: `Constants.Conversation.Composer.controlTarget`,
`Constants.Conversation.Composer.minimumTextViewHeight`

The composer control hit target is 60 pt on visionOS, because gaze targeting
needs at least 60 pt (HIG). Other platforms keep the 44 pt tap minimum. On
visionOS the empty field matches the 60 pt side controls exactly: the minimum
text view height equals the control target with no outer vertical padding,
capsule corners, and short content vertically centered by `KeyCommandTextView`.

### 2. Question free text

Applies to: `Constants.Conversation.QuestionWizard.freeTextMaximumLineCount`,
`Constants.Conversation.QuestionWizard.lineFragmentPadding`

The free-text answer grows from one line up to `freeTextMaximumLineCount` lines,
then scrolls. `lineFragmentPadding` matches `UITextView`'s default line-fragment
padding, for placeholder alignment.

### 3. visionOS attention cue

Applies to: `Constants.WorkspaceRow.attentionCueZOffset`, `attentionCueScale`,
`attentionCueAnimationDuration`, `attentionChipBrightness` (`Layout.swift`)

The visionOS attention cue is a single-step z-lift and scale on rows that need
input, plus a brighter status chip. There is no continuous animation (HIG).

### 4. visionOS window corner and confirmation sheets

Applies to: `Constants.WorkspaceSearch.visionWindowCornerRadius`,
`Constants.WorkspaceSearch.windowCornerInset`, `Constants.WorkspaceDetail.confirmationSheetSpacing`,
`confirmationSheetPadding`, `confirmationSheetWidth` (`Layout.swift`)

The bottom search field sits in a window corner. visionOS fixes the window's
corner radius, so the field's inset keeps its corners concentric with the
window's (HIG) instead of being cut by it. The confirmation-sheet constants are
for visionOS deliberate confirmation sheets for destructive or irreversible
workspace actions (archive, delete).

### 5. Pairing column and toast width

Applies to: `Constants.Pairing.maximumContentWidth`, `Constants.Toast.frostOpacity`,
`Constants.Toast.maximumWidth` (`Layout.swift`)

The Pairing layout follows Connect frame 3051:54405; wide windows keep a
readable centered column. The toast's `frostOpacity` is a background tint that
keeps text behind the glass from competing with the banner. Wide windows keep
the toast to the conversation's readable width instead of the full screen.

### 6. The logo geometry is nonisolated

Applies to: `Constants.IntentLogo`

Shape geometry must stay readable outside the main actor.

### 7. iPad shell

Applies to: `IPadShellLayout`, `IPadShellLayout.tightRailShortSide`,
`IPadShellLayout.sidebarLeadingInset`, `IPadShellStyle`

The shell uses Figma anchors adapted to the window's safe-area width and text
size. `tightRailShortSide` (800) lies between the iPad mini's 744 pt short side
and the 820 pt of the 11-inch iPads. Small windows let the sidebar meet the rail;
it shares the shell background, so its content inset does the spacing.
`IPadShellStyle` roles keep the surrounding chrome distinct from the main panel,
and reuse the approved colors without changing the connection or onboarding
palettes.

### 8. Workspace detail values

Applies to: `WorkspaceDetailStyle.largeTitleTracking`, `WorkspaceDetailStyle.neutral`,
`IntentContentSwitcher.isSidebar`

The iPad main pane's 40 pt title keeps the sidebar title's -3% tracking. The
neutral color keeps Figma Grey400 exactly, for repository text and neutral
avatar tiles. With `isSidebar`, `IntentContentSwitcher` matches the sidebar
filter: no track, so the selected pill lines up with the column text.
