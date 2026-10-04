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
    "ConnectionLossUITests": {
        "testDifferentServerAllowsSameMachineReselection": (
            "connection-loss-failure-before-primary-exit", "connection-loss-failure-primary-exit-machine-reselected",
        ),
        "testRepairAllowsSameMachineReselection": (
            "connection-loss-failure-before-primary-exit", "connection-loss-failure-primary-exit-machine-reselected",
        ),
        "testLaunchHidesBackButSelectedMachineCanReturnHome": (
            "connection-loss-connection-failure-back", "connection-loss-connecting-back",
        ),
    },
    "WorkspaceSwipeUITests": {
        "testArchiveAndDeleteRequireConfirmationAndPersistAfterRefresh": ("workspace-archived-badge",),
    },
    "WorkspaceListMenuUITests": {
        "testRecentAgentsOpensAndClosesExistingDrawer": (
            "workspace-list-menu", "workspace-menu-recent-agents",
        ),
        "testRecentConnectionsOpensSwitcherAndSelectsConnection": ("workspace-menu-recent-connections",),
    },
    "WorkspaceSearchUITests": {
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
        r"(?:IntentUITests/)?([A-Za-z0-9_]+)/([A-Za-z0-9_]+)(?:\(\))?", identifier,
    )
    return match.groups() if match else None


def capture_matches(name, capture, extension):
    # xcresulttool appends an occurrence index and UUID, including when the
    # attachment already has an extension in its XCTest name.
    return bool(re.fullmatch(
        re.escape(capture) + rf"(?:\.{extension})?(?:_\d+_{UUID})?\.{extension}", name,
    ))


def permitted_attachment(suite, test, attachment):
    name = attachment.get("suggestedHumanReadableName") or attachment.get("exportedFileName", "")
    if not isinstance(name, str):
        return None
    for capture in CAPTURES.get(suite, {}).get(test, ()):
        if capture_matches(name, capture, "png"):
            kind = "agent-groups" if suite == "WorkspaceAgentGroupsUITests" else "review"
            return kind, capture, "png"
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
    for record in document:
        identity = test_identity(record.get("testIdentifier")) if isinstance(record, dict) else None
        if identity is None:
            continue
        suite, test = identity
        for attachment in record.get("attachments", []):
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
        "schemaVersion": 1,
        "revision": revision,
        "runId": env.get("GITHUB_RUN_ID"),
        "runAttempt": env.get("GITHUB_RUN_ATTEMPT"),
        "files": [],
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
        if manifest["files"]:
            (output_root / kind / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a") as output:
            for kind, count in counts.items():
                output.write(f"{kind}_count={count}\n")
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
