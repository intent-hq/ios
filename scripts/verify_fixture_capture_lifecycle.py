#!/usr/bin/env python3
"""Require a real XCTest assertion abort AND its named teardown PNG on a Mac.

Build with scripts/xcodebuild.sh build-for-testing-ui first, using the same
SIM_UDID and DERIVED_DATA_DIR. Deliberate XCTest failures remain in the bundles;
only this outer evidence contract exits zero. This does not test crash recovery.
"""

import argparse
from collections import Counter
import json
import os
from pathlib import Path
import subprocess

import export_ui_evidence as evidence


ROOT = Path(__file__).resolve().parent.parent
SUITE = "FixtureCaptureLifecycleUITests"
ABORT = "testAssertionAbortRetainsFinalCapture"
PASS = "testPassingFixtureRetainsRepeatedFinalCapture"
MARKER = "fixture-capture-contract-intentional-assertion-abort"
CAPTURES = {ABORT: "fixture-assertion-abort-final-state", PASS: "fixture-passing-final-state"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def nodes(document):
    if isinstance(document, list):
        for value in document:
            yield from nodes(value)
    elif isinstance(document, dict):
        yield document
        yield from nodes(document.get("children", []))


def verify_result(status, tests, details):
    require(status == 65, f"Expected original assertion failure exit 65, got {status}")
    require(isinstance(tests.get("testNodes"), list), "Missing native test tree")
    cases = [node for node in nodes(tests["testNodes"]) if node.get("nodeType") == "Test Case"]
    observed = Counter((evidence.test_identity(node.get("nodeIdentifier")), node.get("result")) for node in cases)
    expected = Counter({((SUITE, ABORT), "Failed"): 1, ((SUITE, PASS), "Passed"): 1})
    require(observed == expected, f"Expected exactly the failed abort and passed fixture, got {observed}")
    require(evidence.test_identity(details.get("testIdentifier")) == (SUITE, ABORT),
            "Failure details belong to the wrong test")
    require(details.get("testResult") == "Failed", "The intentional assertion must remain Failed")
    failures = [node.get("name", "") for node in nodes(details.get("testRuns", []))
                if node.get("nodeType") == "Failure Message"]
    require(len(failures) == 1 and MARKER in failures[0],
            f"Expected only the original intentional assertion, got {failures}")


def verify_captures(output, bundles, revision):
    review = output / "review"
    manifest = json.loads((review / "manifest.json").read_text())
    require(manifest.get("revision") == revision, "Compact evidence belongs to a different revision")
    require(manifest.get("missingCaptures") == [], "Compact export is missing a registered final capture")
    expected = Counter({(str(bundle), test, capture): count
                        for bundle in bundles for test, capture, count in (
                            (ABORT, CAPTURES[ABORT], 1), (PASS, CAPTURES[PASS], 2))})
    observed = Counter()
    files = set()
    for entry in manifest.get("files", []):
        identity = evidence.test_identity(entry.get("testIdentifier"))
        require(identity is not None and identity[0] == SUITE and entry.get("suite") == SUITE,
                "Capture has the wrong test identity")
        require(entry.get("retry") is False, "A retry must not substitute for the original abort capture")
        observed[(entry.get("sourceBundle"), identity[1], entry.get("capture"))] += 1
        relative = Path(entry["file"])
        path = review / relative
        require(not relative.is_absolute() and ".." not in relative.parts and not path.is_symlink()
                and path.resolve().is_relative_to(review.resolve()), "Unsafe compact PNG path")
        require(path not in files, "Repeated captures overwrote a PNG")
        files.add(path)
        require(path.read_bytes().startswith(evidence.PNG_SIGNATURE), "Final capture is not a PNG")
    require(observed == expected, f"Expected exact named captures for each original bundle, got {observed}")
    require(set(output.rglob("*.png")) == files, "Unexpected PNGs escaped the compact manifest")


def read_result(bundle, kind, destination, *arguments):
    result = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", kind,
                             "--path", str(bundle), *arguments],
                            check=True, text=True, capture_output=True)
    document = json.loads(result.stdout)
    destination.write_text(json.dumps(document, indent=2) + "\n")
    return document


def run_contract(output_root, repetitions):
    output_root = output_root.resolve()
    output_root.mkdir(parents=True, exist_ok=False)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    bundles = []
    results = []
    for attempt in range(1, repetitions + 1):
        bundle = output_root / f"attempt-{attempt}.xcresult"
        env = dict(os.environ, ONLY_TESTING=f"IntentUITests/{SUITE}", RESULT_BUNDLE=str(bundle),
                   TEST_RUNNER_INTENT_CAPTURE_LIFECYCLE_CONTRACT="1", TEST_CRASH_RETRY="0")
        with (output_root / f"attempt-{attempt}.log").open("w") as log:
            result = subprocess.run([str(ROOT / "scripts/xcodebuild.sh"), "test-without-building-ui"],
                                    cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=False)
        (output_root / f"attempt-{attempt}-exit.json").write_text(json.dumps({"exitCode": result.returncode}) + "\n")
        # Read/export even after failure so a rejected contract keeps its diagnostic evidence.
        tests = read_result(bundle, "tests", output_root / f"attempt-{attempt}-tests.json")
        details = read_result(bundle, "test-details", output_root / f"attempt-{attempt}-abort.json",
                              "--test-id", f"{SUITE}/{ABORT}()")
        bundles.append(bundle)
        results.append((result.returncode, tests, details))
    compact = output_root / "compact"
    evidence.export_evidence(bundles, compact, revision)
    for result in results:
        verify_result(*result)
    verify_captures(compact, bundles, revision)
    receipt = {"revision": revision, "verified": True, "assertionResult": "Failed",
               "bundles": [str(bundle) for bundle in bundles], "compactManifest": "compact/review/manifest.json"}
    (output_root / "contract.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"PASS: original assertion failures and named teardown PNGs verified in {output_root}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, required=True, help="Fresh directory; never reuses old evidence")
    parser.add_argument("--repetitions", type=int, choices=(1, 2), default=2)
    args = parser.parse_args()
    try:
        run_contract(args.output_root, args.repetitions)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"FAIL: fixture capture lifecycle contract: {error}\n")


if __name__ == "__main__":
    main()
