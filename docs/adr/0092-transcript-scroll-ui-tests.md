# 0092. Transcript scroll UI tests

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The transcript UI tests guard "Go to End" and the resting position of the long demo transcript. The symptoms are intermittent: a viewport that stops past the end over a blank band (intent-hq/ios#271), a viewport that stops short of the end (intent-hq/ios#304), a single Go to End tap that does not reach the end (#305), a keyboard resize that lands at the top (intent-hq/ios#276), and a hooks row that blanks the transcript (intent-hq/ios#338). Earlier versions used guessed delays and geometry sampling, and they raced the app on CI (intent-hq/ios#307, intent-hq/ios#313, intent-hq/intent#5109).

## Decision

1. **Fixture.**
   1. The tests use the "Deflake payment integration tests" demo workspace and its 150+ message transcript (`DemoFixtures.longConversationMessages`). The UI test target cannot import the app, so the tests match fixture text and accessibility identifiers.
   2. The tests open the transcript through the workspace overview and an explicit tap on the agent row. A workspace tap never opens an agent (ios#349). The overview is identified by its Agents/Context control, because the agent name also matches an open conversation title.
   3. Use the `transcript.scrollView` identifier. The hooks row is also a horizontal scroll view, so `scrollViews.firstMatch` can find the wrong view.
2. **Settlement, not delays.**
   1. Every wait polls app state. A test never waits for a guessed idle time.
   2. A forced follow (entry, Go to End, a send) reports its outcome in the transcript accessibility value. A settled state needs that report, an idle viewport, and a last row that holds still across two polls. Entry that keeps a visible viewport without a forced follow also counts.
   3. The report is synchronization only. Its outcome is not asserted, because CI simulators often report `giveUp` with the viewport at the end.
   4. The end is asserted on geometry: the final content row (`EndRow`) rests `endRowGap` above the bottom edge, within `endGapTolerance`. Containment alone does not catch a viewport past the end or short of it.
   5. The final content row is the last suggested prompt while no send is in flight, and the thinking indicator after a send. The first prompt cannot tell "at the end" from "two prompt rows short".
   6. After settlement, Go to End must stay hidden and the end row must stay at the end for `quietWindow`. The window outlasts a late automatic follow and the full landing budget.
3. **Reading frames.** Read a frame from one `snapshot()`. `exists` followed by `frame` resolves the query twice, and a lazy row that derealizes between the two fails the test. Visibility uses the element centre, not `isHittable`, because the selectable text overlay changes hit-test results between runs.
4. **Trigger files.**
   1. Every launch passes a hooks-row trigger file. The fixture holds the hooks row until the file exists, so the row never lands inside a settle or quiet window. Only the footer test creates the file, after a steady baseline. A clock delay raced CI render time (#285).
   2. The controlled recovery tests pass an end-derealization trigger file and a mode. `release` puts the `scroll-bottom` marker back after the recovery pages up. `hold` never does, so the recovery must give up and never report `recovered`.
   3. The runner and the app share the simulator file system, so a temporary-directory path works. Each test case instance has its own paths, and teardown removes them.
5. **Recovery report.**
   1. The `endRecovery=` segment carries a reason, a correction count, an episode count and `endRealized`. `recovered` is valid only when the episode spent a correction and the end row was realized. Every settled report is checked for this shape.
   2. Ordinary launches are not held to `notAttempted`. The marker can derealize during entry.
   3. A controlled test reads its baseline after entry settles and its report is terminal. Only an episode with a higher episode count proves the triggered recovery.
6. **Evidence.** Each cold-entry and controlled launch attaches one content-free JSON record (no message text). The launch is armed before its first assertion, and teardown attaches the record if an assertion stopped the test. The record never asserts.
7. **Repetition.** Cold entry repeats `entryCycles` times with a fresh launch each cycle. A return through the workspace list would mount the cached transcript.
8. **Keyboard.**
   1. The keyboard counts as raised only when the transcript loses `keyboardMinimumShrink`. A simulator with a hardware keyboard raises none.
   2. A missing software keyboard after text entry is an unmet prerequisite (intent-hq/ios#385) and skips. An off-screen keyboard is not.
   3. Only the keyboard-open half is tested. Every tap that dismisses the keyboard also starts app behaviour.
9. **Scrolling.** Use short, slow drags and reverse when the target is below the viewport. A full-speed swipe can jump over the target.

## Consequences

- A failure message always includes the follow report, Go to End presence and where the last row lies (ABOVE, INSIDE, BELOW), so one CI failure is diagnostic (intent-hq/ios#281).
- New transcript tests must use the same settlement helpers and trigger files.

## Code

- `ConversationTranscriptScrollUITests`: `hooksRowTriggerFile`, `endDerealizationTriggerFile`, `pendingRecoveryEvidence`, `tearDownWithError()`, `attachPendingRecoveryEvidence()`, `attachRecoveryEvidence`
- `ConversationTranscriptScrollTestSupport.swift`: `EndRow`, `EndRecoveryReport`, `canBeBaseline(allowRecoveredEntry:)`, `launchDemoApp`, `openLongConversation`, `enterLongConversation`, `leaveConversation`, `waitUntilSettled`, `assertAtEnd`, `assertStaysAtBottom`, `assertRestsAtBottom`, `assertRecoveryReportWellFormed`, `settledRecoveryBaseline`, `waitForTerminalRecovery`, `recoveryEvidenceRecord`, `evidencePosition`, `isAtEnd`, `viewportHasReportedSettlement`, `frame(of:)`, `restingState`, `waitUntilSteady`
- `DemoFixtures`: `longConversationHookListGate`, `configuredEndDerealizationTriggerFile`
