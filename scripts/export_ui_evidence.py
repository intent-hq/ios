#!/usr/bin/env python3
"""Retain allowlisted fixture attachments, never the complete xcresult export."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


CAPTURES = {
    "ScriptMonitorsUITests": {
        "testOwnedWatchDetailsUpdateAndRemovalWithoutRestart": (
            "script-monitors-active", "script-monitors-details", "script-monitors-text-update",
            "script-monitors-removed-details", "script-monitors-removed", "script-monitors-final-state",
        ),
        "testLoadingFailureRetriesWithoutInventingAnEmptyState": (
            "script-monitors-loading", "script-monitors-error", "script-monitors-retried", "script-monitors-final-state",
        ),
        "testEmptyOwnerCanLoadNextPageAndRetryItsFailure": (
            "script-monitors-empty-owner-more", "script-monitors-page-error", "script-monitors-next-page", "script-monitors-final-state",
        ),
        "testDetailFailureRetainsSummaryAndRetriesOnlySelectedWatch": (
            "script-monitors-detail-error", "script-monitors-detail-retried", "script-monitors-final-state",
        ),
        "testUnsupportedConnectionDoesNotReadOrSubscribe": (
            "script-monitors-unsupported", "script-monitors-final-state",
        ),
        "testDeadlineRemainsVisibleUntilServerExpiry": (
            "script-monitors-deadline", "script-monitors-expired", "script-monitors-final-state",
        ),
        "testSeveralWatchesShareOneCountedPill": (
            "script-monitors-multiple", "script-monitors-multiple-menu", "script-monitors-multiple-details",
            "script-monitors-final-state",
        ),
        "testQuestionFlowKeepsWatchReachableWithAccessibilityText": (
            "script-monitors-question-accessibility", "script-monitors-question-details", "script-monitors-final-state",
        ),
    },
    "WorkspaceFilesUITests": {
        "testBrowseFilesAndPreserveFoldersAcrossTabsInBothThemes": tuple(
            f"{screen}-{appearance}"
            for appearance in ("light", "dark")
            for screen in ("workspace-context", "workspace-files", "workspace-file-preview")
        ),
    },
    "FixtureCaptureLifecycleUITests": {
        "testAssertionAbortRetainsFinalCapture": ("fixture-assertion-abort-final-state",),
        "testPassingFixtureRetainsRepeatedFinalCapture": ("fixture-passing-final-state",),
    },
    "WorkspaceEntryUITests": {
        "testDisclosureAndNoteNavigationKeepSeparateTouchTargets": ("note-viewer-flat-back-button",),
        "testCreateNewAgentMenuOpensAgentSetup": ("new-agent-next", "new-agent-create", "new-browser-open"),
    },
    "WorkspaceBackgroundUITests": {
        "testNoteBackgroundMatchesWorkspaceInBothAppearances": tuple(
            f"workspace-background-{screen}-{appearance}"
            for appearance in ("light", "dark")
            for screen in ("reference", "note")
        ),
        "testNewAgentBackgroundMatchesWorkspaceInBothAppearances": tuple(
            f"workspace-background-{screen}-{appearance}"
            for appearance in ("light", "dark")
            for screen in ("reference", "agent", "provider")
        ),
        "testBrowserBackgroundMatchesWorkspaceInBothAppearances": tuple(
            f"workspace-background-{screen}-{appearance}"
            for appearance in ("light", "dark")
            for screen in ("reference", "browser", "browser-address")
        ),
        "testConversationBackgroundMatchesWorkspaceInBothAppearances": tuple(
            f"workspace-background-{screen}-{appearance}"
            for appearance in ("light", "dark")
            for screen in ("reference", "conversation")
        ),
        "testSettingsBackgroundsMatchWorkspaceInBothAppearances": tuple(
            f"workspace-background-{screen}-{appearance}"
            for appearance in ("light", "dark")
            for screen in ("reference", "settings", "manual", "disconnect-confirmation")
        ),
        "testIPadSettingsSidebarKeepsShellBackground": (
            "ipad-settings-sidebar-light", "ipad-settings-sidebar-dark",
        ),
        "testSettingsSupportBackgroundsMatchWorkspaceInBothAppearances": tuple(
            f"workspace-background-{screen}-{appearance}"
            for appearance in ("light", "dark")
            for screen in ("reference", "acknowledgements", "diagnostics")
        ),
    },
    "AppCoordinatorTests": {
        "iPadWorkspaceBackFollowsWindowWidthAndKeepsSelection": (
            "ipad-wide-workspace-no-back", "ipad-narrow-workspace-back", "ipad-narrow-back-to-workspaces",
        ),
        "iPadCompactLaunchShowsListAndMenuDestinations": tuple(
            f"ipad-narrow-{screen}-{appearance}"
            for appearance in ("light", "dark")
            for screen in ("workspaces", "menu")
        ),
        "iPadCompactResizeRetainsComposerAndDismissesOpenMenu": (
            "ipad-narrow-workspace-draft", "ipad-narrow-assistant-draft",
        ),
    },
    "IPadSidebarUITests": {
        "testSectionsAndPairingRestoreConversationInBothThemes": tuple(
            f"iPad {section} {appearance}"
            for appearance in ("light", "dark")
            for section in (
                "workspace", "collapsed", "Assistant", "connections", "settings", "QR", "manual",
                "Recent sidebar", "Repo sidebar", "Status sidebar", "first workspace selected",
                "focused typing", "focused typing keyboard hidden", "typing restored",
            )
        ),
        "testScrollingIndicatorStaysOutsideWorkspaceRowsInBothThemes": tuple(
            f"iPad scrolling {mode} sidebar {appearance}"
            for appearance in ("light", "dark")
            for mode in ("Recent", "Repo", "Status")
        ),
        "testRailRemainsReachableWithAccessibilityText": ("iPad accessibility manual pairing",),
    },
    "IPadAssistantSwipeUITests": {
        "testSwipeDeletionPreservesSelectionAndSupportsCancellationInBothThemes": (
            "iPad Assistant swipe delete light", "iPad Assistant swipe delete dark",
        ),
    },
    "IPhoneAssistantHistoryUITests": {
        "testSwipeDeletionPreservesDraftAndSelectionInBothThemes": (
            "iPhone Assistant history swipe delete light", "iPhone Assistant history swipe delete dark",
        ),
    },
    "HomeActionMenuUITests": {
        "testDuoWorkspaceDetailKeepsOnlyTheAccessibleContentTitle": ("Duo workspace detail without header",),
        "testClosePreservesWorkspaceScrollAndAssistantIsFirst": ("Intent home action tiles",),
        "testMenuPlacementSurvivesDrawerRoundTrips": (
            "Intent menu placement closed", "Intent menu placement open",
        ),
        "testIPadConversationKeepsDraftAndRailAvailable": (
            "iPad expanded workspace conversation", "iPad collapsed conversation with draft",
            "iPad portrait conversation with draft",
            "iPad focused multiline draft",
        ),
        "testIPadQuestionsKeepNextAndRailAvailable": ("iPad question actions beside persistent rail",),
    },
    "ConversationMermaidUITests": {
        "testDiagramHistoryRemainsUsableWhenItGrowsPastEagerLimit": ("mermaid-history-grown",),
        "testDiagramHistoryReopensAndGoToEndShowsLastAnswer": (
            "mermaid-history-visit-1", "mermaid-history-visit-2", "mermaid-history-visit-3",
        ),
        "testFullscreenButtonEdgeAndInlinePinchAndPan": (
            "mermaid-final-state", "mermaid-inline-before-gestures",
            "mermaid-fullscreen-from-button-edge", "mermaid-inline-after-pinch",
            "mermaid-inline-after-horizontal-pan", "mermaid-inline-after-vertical-pan",
        ),
    },
    "ConversationToolActivityUITests": {
        "testIPadClaudeToolTitlesKeepExpandedDetails": (
            "iPad Claude tools collapsed light", "iPad Claude tools expanded light",
            "iPad Claude tools collapsed dark", "iPad Claude tools expanded dark", "iPad Claude tools final state",
        ),
        "testIPadConsecutiveToolsExpandAndCollapseInBothThemes": (
            "iPad tools collapsed light", "iPad tools expanded light",
            "iPad tools collapsed dark", "iPad tools expanded dark", "iPad tools final state",
        ),
    },
    "ConversationActionsUITests": {
        "testHistoryNoticeAndActionCancellationPreserveConversation": (
            "Conversation-History-Light", "Agent-Actions-Light", "Agent-Delete-Confirmation-Light",
            "Agent-Model-Picker-Light", "Agent-Actions-Updated-Light",
        ),
        "testLargeTextModelPickerWorksAfterSending": (
            "Agent-Actions-Dark-LargeText", "Agent-Model-Picker-Dark-LargeText", "Agent-Model-Picker-Selected-Dark-LargeText",
        ),
    },
    "WorkspaceComposerUITests": {
        "testTranscriptTapDismissesKeyboardAndPreservesDraft": ("Workspace composer resting placement",),
    },
    "ConversationTranscriptScrollUITests": {
        "testControlledEndDerealizationIsRecoveredByTheRealRecoveryPath": ("Transcript recovered release",),
        "testBlankEndSeveralScreensDeepIsRecovered": ("Transcript recovered deep-release",),
        "testLoadingStatusShowsIdleDelayAndRestoresComposer": (
            "Conversation loading before idle light", "Conversation loading after idle light",
            "Conversation loading before idle dark", "Conversation loading after idle dark",
        ),
    },
    "QuestionWizardUITests": {
        "testSkipClearsAnEarlierSelection": ("questions-submitted-transcript",),
        "testDismissRequiresConfirmationAndCancelPreservesQuestions": ("questions-dismissed-transcript",),
        "testCustomAnswersSubmitBesideTheKeyboardWithoutScrolling": (
            "questions-custom-answer-next", "questions-custom-answer-send", "questions-submitted-transcript",
        ),
    },
    "TranscriptVideoUITests": {
        "testSentVideoPosterOpensFullScreenPlayback": (
            "Sent video poster", "Sent video full-screen playback",
        ),
    },
    "InlineResponseImageUITests": {
        "testSavedImageOpensWithKeyboardAndPreservesDraft": (
            "Response image with keyboard open", "Saved response image in lightbox",
        ),
        "testUserImageBlockOpensWithKeyboardAndPreservesDraft": (
            "user image block with keyboard open", "Saved response image in lightbox",
        ),
        "testAssistantImageBlockOpensWithKeyboardAndPreservesDraft": (
            "assistant image block with keyboard open", "Saved response image in lightbox",
        ),
        "testPDFCardAndLinkOpenViewerAndShare": (
            "Inline PDF card and link", "PDF viewer from inline card",
            "PDF viewer from text link", "PDF share sheet", "PDF unavailable with close and retry",
        ),
        "testTextLinkOpensViewerSharesAndRetriesMissingFile": (
            "Text viewer from text link", "Text unavailable with close and retry",
        ),
    },
    "AssistantStateUITests": {
        "testLoadingFailureRetriesToEmptyAndStartsConversation": (
            "Assistant loading light", "Assistant error light", "Assistant empty light",
            "Assistant loading dark", "Assistant error dark", "Assistant empty dark",
        ),
        "testStateActionsRemainReachableWithAccessibilityText": (
            "Assistant loading accessibility", "Assistant error accessibility", "Assistant empty accessibility",
        ),
    },
    "AssistantProposalUITests": {
        "testArchiveSelectionAndSavedOutcome": ("Assistant switches on", "Assistant switches off"),
        "testCreateWorkspaceFromProposalAndOpenIt": ("Workspace proposal review", "Workspace proposal created"),
    },
    "AssistantNavigationUITests": {
        "testWorkspaceBlockOpensWorkspaceOverview": ("Assistant workspace links",),
        "testAssistantButtonOpensAndReturnsToWorkspaces": ("Global Assistant on iOS",),
        "testAssistantComposerKeepsHeaderActionsReachable": (
            "Assistant chat sent message light", "Assistant chat sent message dark",
        ),
    },
    "WatcherMessageUITests": {
        "testWatcherDetailsExpandAndCollapseWithoutLosingTheReport": (
            "Watcher summary", "Watcher expanded details", "Watcher final state",
        ),
    },
    "WorkspaceTitleEditingUITests": {
        "testDoubleTapShowsKeyboardAndDoneSavesTheTitle": (
            "Workspace title editing with keyboard and floating Done",
        ),
    },
    "ConnectionLossUITests": {
        "testDifferentServerAllowsSameMachineReselection": (
            "connection-loss-failure-before-primary-exit", "connection-loss-failure-primary-exit-machine-reselected",
        ),
        "testRepairAllowsSameMachineReselection": (
            "connection-loss-failure-before-primary-exit", "connection-loss-failure-primary-exit-machine-reselected",
        ),
        "testLaunchHidesBackButSelectedMachineCanReturnHome": (
            "connection-loss-launch-connecting-without-back",
            "connection-loss-connection-failure-back", "connection-loss-connecting-back",
        ),
    },
    "WorkspaceSwipeUITests": {
        "testSlowStatusSwipeStaysOpenAfterFingerLifts": ("workspace-status-swipe-stays-open",),
        "testRightSwipeOpensRecentAgentAndBackReturnsToWorkspace": ("workspace-right-swipe-recent-agent",),
        "testArchiveAndDeleteRequireConfirmationAndPersistAfterRefresh": (
            "workspace-archive-delete-swipe", "workspace-archived-badge",
        ),
    },
    "WorkspaceScriptUITests": {
        "testSwipeStopsServerAndDeletesFinishedScript": ("workspace-script-stop-delete-actions",),
    },
    "WorkspaceStatusImageUITests": {
        "testStatusImageIsAbsentFromListAndOpensFullSizeFromDetail": ("workspace-summary-and-image",),
    },
    "ManualConnectionDesignUITests": {
        "testTokenVisibilityKeepsDraftFocusAndSheetPosition": (
            "manual-design-token-visibility-keeps-focus",
            "manual-design-token-visibility-keeps-keyboard-dismissed",
        ),
    },
    "WorkspaceListMenuUITests": {
        "testEmptyWorkspaceButtonOpensCreationAndReturns": ("empty-workspaces-light", "empty-workspaces-dark"),
        "testNewWorkspaceMenuOpensCreationAndReturns": ("new-workspace-menu-light", "new-workspace-menu-dark"),
        "testRecentAgentsOpensAndClosesExistingDrawer": (
            "workspace-list-menu", "workspace-menu-recent-agents",
        ),
        "testRecentConnectionsOpensSwitcherAndSelectsConnection": ("workspace-menu-recent-connections",),
    },
    "WorkspaceSearchUITests": {
        "testWorkspaceControlsHaveSeparateTargetsAndSelectEveryMode": ("Workspace list leading alignment",),
        "testIPadSearchSurvivesCollapseAndSectionChanges": tuple(
            f"iPad {state} {appearance}"
            for appearance in ("light", "dark")
            for state in ("focused search", "focused search keyboard hidden", "search restored")
        ),
        "testSearchAboveKeyboardHidesAssistantUntilClosed": (
            "Workspace search above keyboard without Assistant launcher",
        ),
    },
    "CreateNewRepositoryUITests": {
        "testNewRepositoryWithoutGitHubPreservesDraftAndRetriesCreation": (
            "new-repository-name-with-keyboard", "new-repository-create-with-keyboard", "new-repository-draft-after-retry",
            "new-repository-creating", "new-repository-create-recovered",
        ),
    },
    "CreateWorkspaceSelectionUITests": {
        "testLoadingTransitionsKeepSelectionTitlesStable": (
            "repository-loading", "repository-loaded", "branch-loading", "branch-loaded",
        ),
        "testRepositorySelectionSearchAndClose": (
            "repository-selected", "repository-search-opened", "repository-search-results",
        ),
        "testBackThenForwardPreservesProviderAndNamedModelThroughRefresh": (
            "selected-repository", "selected-branch", "branch-search-opened", "branch-search-results",
            "selected-before-back", "draft-after-source-edit",
        ),
    },
    "CreateWorkspacePreferencesUITests": {
        "testCancelledFormRemembersAgentSettings": ("remembered-agent-settings",),
    },
    "CreateWorkspaceDraftUITests": {
        "testDismissedPromptRestoresAndClearsAfterSuccessfulRetry": ("restored-workspace-draft",),
    },
    "WorkspaceChangesUITests": {
        "testChangesTabOpensStagedUnstagedAndCommitDiffs": (
            "workspace-changes", "unstaged-diff", "commit-diff",
        ),
        "testRepositorySelectionScopesFilesAndCommitDiffs": (
            "submodule-changes", "submodule-unstaged-diff", "submodule-commit-diff",
        ),
        "testSectionsCollapseIndependentlyAndReopen": ("collapsed-changes-sections",),
        "testNestedFoldersPreserveCollapseUntilRepositoryChanges": ("nested-file-tree",),
    },
    "WorkspaceAgentGroupsUITests": {
        "testSectionsLoadOnExpansionAndKeepNestedChildrenWithTheirParent": (
            "agent-group-evidence-Agent groups collapsed with counts",
            "agent-group-evidence-Nested delegated children expanded",
            "agent-group-evidence-Background parent and its delegated child",
            "agent-group-evidence-Orphan parent retains its nested child",
            "agent-group-evidence-Retired section expanded",
        ),
        "testLoadingFailureCanRetryOnlyTheExpandedSection": (
            "agent-group-evidence-Background group loading",
            "agent-group-evidence-Background group failure with retry",
        ),
    },
}
RECOVERY_SUITES = {
    "ConversationTranscriptScrollUITests", "ConversationTranscriptFullGateUITests",
}
ARTIFACTS = ("review", "agent-groups", "recovery")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
UUID = r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}"


def safe_name(value):
    return re.sub(r"[^A-Za-z0-9._-]+", "_", value).strip("._-")[:120] or "attachment"


def test_identity(identifier):
    if not isinstance(identifier, str):
        return None
    match = re.fullmatch(
        r"(?:(Intent(?:UI)?Tests)/)?([A-Za-z0-9_]+)/([A-Za-z0-9_]+)(?:\((?:[A-Za-z_][A-Za-z0-9_]*:)*\))?",
        identifier,
    )
    if not match:
        return None
    target, suite, test = match.groups()
    expected_target = "IntentUITests" if suite.endswith("UITests") else "IntentTests"
    if target and target != expected_target:
        return None
    return suite, test


def capture_matches(name, capture, extension):
    # xcresulttool appends an occurrence index and UUID, including when the
    # attachment already has an extension in its XCTest name.
    return bool(re.fullmatch(
        re.escape(capture) + rf"(?:\.{extension})?(?:_\d+_{UUID})?\.{extension}", name,
    ))


def screenshot_artifact(suite):
    return "agent-groups" if suite == "WorkspaceAgentGroupsUITests" else "review"


def permitted_attachment(suite, test, attachment):
    name = attachment.get("suggestedHumanReadableName") or attachment.get("exportedFileName", "")
    if not isinstance(name, str):
        return None
    for capture in CAPTURES.get(suite, {}).get(test, ()):
        if capture_matches(name, capture, "png"):
            return screenshot_artifact(suite), capture, "png"
    if suite in RECOVERY_SUITES:
        capture = re.fullmatch(
            rf"(transcript-recovery-evidence-{re.escape(test)}-\d+)(?:_\d+_{UUID})?\.json", name,
        )
        if capture:
            return "recovery", capture[1], "json"
    return None


def warning(message):
    print("::warning::" + str(message).replace("\r", " ").replace("\n", " "))


def retain_export(exported, source, bundle_index, retry, manifests, output_root):
    document = json.loads((exported / "manifest.json").read_text())
    if not isinstance(document, list):
        raise ValueError("attachment manifest must be a list")
    observed = {}
    retained = {}
    for record in document:
        identity = test_identity(record.get("testIdentifier")) if isinstance(record, dict) else None
        if identity is None:
            continue
        suite, test = identity
        observed.setdefault(identity, record["testIdentifier"])
        attachments = record.get("attachments", [])
        if not isinstance(attachments, list):
            warning(f"Invalid attachment list for {suite}/{test} in {source}")
            continue
        for attachment in attachments:
            if not isinstance(attachment, dict):
                continue
            permitted = permitted_attachment(suite, test, attachment)
            if permitted is None:
                continue
            kind, capture, extension = permitted
            filename = attachment.get("exportedFileName")
            if not isinstance(filename, str) or not filename or Path(filename).name != filename:
                warning("Ignoring an unsafe attachment path")
                continue
            path = exported / filename
            if path.is_symlink() or not path.is_file():
                warning("An allowlisted attachment is missing or is a symlink")
                continue
            data = path.read_bytes()
            if extension == "png" and not data.startswith(PNG_SIGNATURE):
                warning("Ignoring a non-PNG attachment with a screenshot name")
                continue
            if extension == "json":
                try:
                    if not isinstance(json.loads(data), dict):
                        raise ValueError("recovery evidence must be an object")
                except (ValueError, UnicodeError):
                    warning("Ignoring invalid recovery JSON")
                    continue
            entries = manifests[kind]["files"]
            relative = Path(f"{bundle_index:02d}-{safe_name(source.name)}") / suite / test / (
                f"{safe_name(capture)}-{len(entries) + 1:04d}.{extension}"
            )
            destination = output_root / kind / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open("xb") as output:
                output.write(data)
            entries.append({
                "file": relative.as_posix(),
                "suite": suite,
                "testIdentifier": record["testIdentifier"],
                "sourceBundle": str(source),
                "retry": retry,
                "capture": capture,
                "exportedFileName": filename,
            })
            if extension == "png":
                retained.setdefault(identity, set()).add(capture)
    for (suite, test), identifier in observed.items():
        missing = sorted(set(CAPTURES.get(suite, {}).get(test, ())) - retained.get((suite, test), set()))
        if not missing:
            continue
        manifests[screenshot_artifact(suite)]["missingCaptures"].append({
            "suite": suite,
            "testIdentifier": identifier,
            "sourceBundle": str(source),
            "retry": retry,
            "captures": missing,
        })
        warning(f"Missing fixture captures for {identifier} in {source} (retry={retry}): "
                + ", ".join(missing) + ". Captures may not have been reached before a test failure.")


def bundle_paths(bundle):
    retry = bundle.with_name(
        bundle.stem + "-retry.xcresult" if bundle.suffix == ".xcresult" else bundle.name + "-retry",
    )
    return ((bundle, False), (retry, True))


def export_evidence(bundles, output_root, revision, env=None, run=subprocess.run):
    env = os.environ if env is None else env
    # Refuse reuse so an empty/failed export can never upload a previous run's images.
    output_root.mkdir(parents=True, exist_ok=False)
    manifests = {kind: {
        "schemaVersion": 2,
        "revision": revision,
        "runId": env.get("GITHUB_RUN_ID"),
        "runAttempt": env.get("GITHUB_RUN_ATTEMPT"),
        "files": [],
        "missingCaptures": [],
    } for kind in ARTIFACTS}
    seen = set()
    for bundle in bundles:
        for source, retry in bundle_paths(bundle):
            if source.resolve() in seen:
                continue
            seen.add(source.resolve())
            if not source.is_dir():
                print(f"No result bundle at {source}; nothing to export")
                continue
            try:
                with tempfile.TemporaryDirectory(prefix="ui-evidence-") as scratch:
                    scratch = Path(scratch)
                    link = scratch / "results.xcresult"
                    link.symlink_to(source.resolve(), target_is_directory=True)
                    exported = scratch / "attachments"
                    result = run([
                        "xcrun", "xcresulttool", "export", "attachments", "--path", str(link),
                        "--output-path", str(exported),
                    ], check=False)
                    if result.returncode:
                        warning(f"Could not export attachments from {source}")
                        continue
                    retain_export(exported, source, len(seen), retry, manifests, output_root)
            except (OSError, ValueError, TypeError) as error:
                warning(f"Could not retain attachments from {source}: {error}")
    counts = {}
    for kind, manifest in manifests.items():
        counts[kind] = len(manifest["files"])
        if manifest["files"] or manifest["missingCaptures"]:
            (output_root / kind).mkdir(parents=True, exist_ok=True)
            (output_root / kind / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a") as output:
            for kind, count in counts.items():
                output.write(f"{kind}_count={count}\n")
                available = bool(count or manifests[kind]["missingCaptures"])
                output.write(f"{kind}_available={str(available).lower()}\n")
    print("Retained UI evidence: " + json.dumps(counts))
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--bundles", required=True, help="Result bundle paths, one per line; retries are included")
    args = parser.parse_args()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    bundles = [Path(line) for line in args.bundles.splitlines() if line.strip()]
    export_evidence(bundles, args.output_root, revision)


if __name__ == "__main__":
    main()
