#!/usr/bin/env python3
"""Opt-in, one/two-worker UI trial protocol (standard library only).

The wrapper owns init/plan/attempt/finish; workflows call aggregate. All JSON uses
schema_version=1. Identifiers are canonical Target/Suite/method (without ()).
Durations are seconds, timestamps Unix seconds. No logs, attachments or app text
are copied. See CLI --help and xcodebuild.sh's UI_TEST_SHARD_* documentation.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sys
import time


class Invalid(Exception):
    def __init__(self, message, code=83):
        super().__init__(message)
        self.code = code


def require(condition, message, code=83):
    if not condition:
        raise Invalid(message, code)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def load(path):
    return json.loads(Path(path).read_text(), object_pairs_hook=unique_object)


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def fields(value, names):
    require(isinstance(value, dict) and set(value) == set(names.split()), "invalid JSON fields")


def number(value):
    require(type(value) in (int, float) and math.isfinite(value) and value >= 0,
            "expected finite nonnegative seconds")
    return value


def interval(value):
    fields(value, "started_at finished_at")
    require(number(value["finished_at"]) >= number(value["started_at"]), "reversed timing interval")
    return value


def identifier(value, method=True):
    require(isinstance(value, str), "test identifier must be a string")
    value = value.removesuffix("()")
    parts = value.split("/")
    require(parts[0] == "IntentUITests" and (len(parts) == 3 if method else 1 <= len(parts) <= 3)
            and all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", part) for part in parts),
            "invalid UI test identifier")
    return value


def identifiers(values, method=True):
    require(isinstance(values, list), "expected identifier list")
    result = [identifier(value, method) for value in values]
    require(len(result) == len(set(result)), "duplicate test identifier")
    return sorted(result)


def covered(ident, selector):
    return ident == selector or ident.startswith(selector + "/")


def identity(value):
    require(isinstance(value["revision"], str) and re.fullmatch(r"[0-9a-f]{40}", value["revision"]),
            "expected full checkout revision")
    require(isinstance(value["run_id"], str) and re.fullmatch(r"[A-Za-z0-9_-]+", value["run_id"]),
            "expected content-free run id")
    require(type(value["run_attempt"]) is int and value["run_attempt"] > 0, "invalid run attempt")


def context(value):
    fields(value, "schema_version run_id run_attempt revision environment cache build")
    require(type(value["schema_version"]) is int and value["schema_version"] == 1, "unsupported context version")
    identity(value)
    fields(value["environment"], "xcode sdk runtime device_type runner architecture configuration")
    for item in value["environment"].values():
        require(isinstance(item, str) and re.fullmatch(r"[A-Za-z0-9_.+ /()-]{1,160}", item),
                "invalid environment fact")
    require(value["environment"]["configuration"] == "Debug", "trial requires Debug")
    fields(value["cache"], "spm tailcat")
    require(all(item in ("hit", "miss", "restored", "disabled") for item in value["cache"].values()),
            "invalid cache fact")
    interval(value["build"])
    return value


def shard(count, index):
    require(type(count) is int and count in (1, 2), "shard count must be 1 or 2", 1)
    require(type(index) is int and 0 <= index < count, "shard index is zero-based and must be below count", 1)


# Advisory observations from run 36163693922, attempt 1, checkout
# ab641e54f31ed4c126dd104ccab8dfc409388510 (26 passed, two existing skips).
# These six measured hot methods are NOT a coverage inventory. Unknown/renamed
# methods get 150s, conservatively above the largest observation (145.089s).
FALLBACK_SECONDS = 150
HINTS = {
    "IntentUITests/ConversationTranscriptScrollUITests/" + name: seconds
    for name, seconds in [
        ("testHooksRowLandingRightAfterColdEntryKeepsLastMessageOnScreen", 145.089),
        ("testFirstOpenOfLongConversationShowsLastMessageWithNoBlankBand", 139.846),
        ("testEnteringConversationRepeatedlyRestsAtBottomWithGoToEndHidden", 134.672),
        ("testGoToEndFromTopOfLongTranscriptLandsAtEndInOneTap", 125.214),
        ("testGoToEndAppearsWhenScrolledUpAndHidesAtBottom", 76.176),
    ]
}
HINTS["IntentUITests/InlineResponseImageUITests/testSavedAndMissingImagesPreserveResponseAndLightboxAfterReopening"] = 74.374


def catalog(document):
    require(isinstance(document, dict) and not document.get("errors")
            and isinstance(document.get("values"), list) and document["values"], "unverifiable catalog")
    enabled, disabled = [], []
    for group in document["values"]:
        require(isinstance(group, dict) and isinstance(group.get("enabledTests"), list), "invalid catalog group")
        for key, destination in (("enabledTests", enabled), ("disabledTests", disabled)):
            items = group.get(key, [])
            require(isinstance(items, list), "invalid catalog list")
            for item in items:
                raw = item.get("identifier") if isinstance(item, dict) else item
                require(isinstance(raw, str), "catalog entry has no identifier")
                if raw == "IntentUITests" or raw.startswith("IntentUITests/"):
                    destination.append(raw)
    enabled, disabled = identifiers(enabled), identifiers(disabled, False)
    enabled = [ident for ident in enabled if not any(covered(ident, off) for off in disabled)]
    require(enabled, "no enabled UI methods", 82)
    return enabled, disabled


def weights(cases, path):
    hints = HINTS
    if path:
        doc = load(path)
        fields(doc, "schema_version seconds")
        require(type(doc["schema_version"]) is int and doc["schema_version"] == 1
                and isinstance(doc["seconds"], dict), "invalid duration hints")
        hints = {identifier(key): number(value) for key, value in doc["seconds"].items()}
        require(len(hints) == len(doc["seconds"]), "duplicate duration hint")
        require(all(value > 0 for value in hints.values()), "duration hints must be positive")
    return {ident: hints.get(ident, FALLBACK_SECONDS) for ident in cases}


def partition(cases, costs, count):
    assignments, totals = [[] for _ in range(count)], [0] * count
    for ident in sorted(cases, key=lambda item: (-costs[item], item)):
        index = min(range(count), key=lambda item: (totals[item], item))
        assignments[index].append(ident)
        totals[index] += costs[ident]
    require(all(assignments), "empty UI shard", 82)
    return [sorted(items) for items in assignments]


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def check_plan(plan):
    fields(plan, "schema_version context count index simulator_udid catalog disabled weights assignments catalog_sha256 discovery")
    require(type(plan["schema_version"]) is int and plan["schema_version"] == 1, "unsupported plan version")
    require(isinstance(plan["simulator_udid"], str)
            and re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", plan["simulator_udid"]),
            "invalid simulator UDID")
    context(plan["context"])
    shard(plan["count"], plan["index"])
    cases = identifiers(plan["catalog"])
    off = identifiers(plan["disabled"], False)
    require(cases and cases == plan["catalog"] and off == plan["disabled"], "invalid catalog order")
    require(not any(covered(ident, skip) for ident in cases for skip in off), "disabled method selected")
    require(isinstance(plan["weights"], dict) and set(plan["weights"]) == set(cases), "weights do not cover catalog")
    require(all(number(cost) > 0 for cost in plan["weights"].values()), "invalid weight")
    require(plan["assignments"] == partition(cases, plan["weights"], plan["count"]), "assignment differs from deterministic partition")
    require(plan["catalog_sha256"] == digest([cases, off]), "catalog digest mismatch")
    interval(plan["discovery"])
    require(plan["discovery"]["started_at"] >= plan["context"]["build"]["finished_at"], "discovery precedes build")
    return plan


def result_cases(path):
    doc = load(path)
    require(isinstance(doc, dict) and isinstance(doc.get("testNodes"), list), "missing result testNodes")
    cases = []

    def walk(nodes, bundle=""):
        require(isinstance(nodes, list), "malformed result children")
        for node in nodes:
            require(isinstance(node, dict), "malformed result node")
            kind = node.get("nodeType", "")
            current = node.get("name", "") if kind.lower().endswith("test bundle") else bundle
            if kind == "Test Case":
                raw = node.get("nodeIdentifier")
                require(isinstance(raw, str) and current == "IntentUITests", "foreign or unnamed result")
                ident = identifier(raw if raw.startswith(current + "/") else current + "/" + raw)
                outcome = node.get("result")
                require(outcome in ("Passed", "Failed", "Skipped", "Expected Failure"), "unknown case outcome")
                # Xcode's display duration is rounded and version-dependent; retain only
                # simple seconds when supplied, never guess a duration from a display label.
                duration = node.get("duration")
                seconds = None
                if isinstance(duration, str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+)?s", duration):
                    seconds = number(float(duration[:-1]))
                cases.append({"identifier": ident, "outcome": outcome, "duration_seconds": seconds})
            else:
                walk(node.get("children", []), current)
    walk(doc["testNodes"])
    identifiers([case["identifier"] for case in cases])
    return sorted(cases, key=lambda case: case["identifier"])


def reconcile(plan, attempts):
    assigned = plan["assignments"][plan["index"]]
    require(isinstance(attempts, list) and 1 <= len(attempts) <= 2, "expected one attempt and at most one crash retry")
    terminal = {}
    previous_end = plan["discovery"]["finished_at"]
    for index, attempt in enumerate(attempts):
        fields(attempt, "exit_code restarted selectors timing cases")
        require(type(attempt["exit_code"]) is int and 0 <= attempt["exit_code"] <= 255
                and type(attempt["restarted"]) is bool, "invalid attempt status")
        interval(attempt["timing"])
        require(attempt["timing"]["started_at"] >= previous_end, "attempt timings overlap")
        previous_end = attempt["timing"]["finished_at"]
        selected = identifiers(attempt["selectors"])
        require(selected and selected == attempt["selectors"] and set(selected) <= set(assigned), "foreign retry selection")
        if index == 0:
            require(selected == assigned, "primary selection differs from assignment")
        else:
            require(attempts[0]["restarted"] and attempts[0]["exit_code"] != 0, "retry without a failed crashed primary")
            for ident in selected:
                terminal.pop(ident, None)
        require(isinstance(attempt["cases"], list), "invalid cases")
        ids = []
        for case in attempt["cases"]:
            fields(case, "identifier outcome duration_seconds")
            ident = identifier(case["identifier"])
            require(ident == case["identifier"] and ident in selected, "unassigned case evidence")
            require(case["outcome"] in ("Passed", "Failed", "Skipped", "Expected Failure"), "unknown case outcome")
            if case["duration_seconds"] is not None:
                number(case["duration_seconds"])
            ids.append(ident)
            terminal[ident] = dict(case, attempt=index + 1)
        identifiers(ids)
        if index:
            require(set(ids) == set(selected), "crash retry left a method unrecovered", 82)
    last = attempts[-1]
    require(last["exit_code"] == 0, "test attempt failed", 80 if last["restarted"] else last["exit_code"])
    require(set(terminal) == set(assigned), "missing assigned case evidence", 82)
    require(not any(case["outcome"] == "Failed" for case in terminal.values()), "failed terminal case", 65)
    return [terminal[ident] for ident in sorted(terminal)]


def initialize(args):
    shard(args.count, args.index)
    ctx = context(load(args.context))
    require(ctx["revision"] == args.revision, "context revision differs from checkout")
    directory = Path(args.directory)
    directory.mkdir(parents=True, exist_ok=False)  # Never reuse stale evidence.
    write(directory / "request.json", {"context": ctx, "count": args.count, "index": args.index})


def make_plan(args):
    directory = Path(args.directory)
    request = load(directory / "request.json")
    cases, off = catalog(load(args.catalog))
    costs = weights(cases, args.weights)
    plan = dict(request, schema_version=1, simulator_udid=args.simulator_udid, catalog=cases, disabled=off, weights=costs,
                assignments=partition(cases, costs, request["count"]), catalog_sha256=digest([cases, off]),
                discovery={"started_at": args.started_at, "finished_at": args.finished_at})
    check_plan(plan)
    write(directory / "plan.json", plan)
    print("\n".join(plan["assignments"][plan["index"]]))


def add_attempt(args):
    directory = Path(args.directory)
    plan = check_plan(load(directory / "plan.json"))
    path = directory / "attempts.json"
    attempts = load(path) if path.exists() else []
    require(len(attempts) < 2, "too many attempts")
    selected = identifiers(args.selectors.split()) if attempts else plan["assignments"][plan["index"]]
    attempts.append({"exit_code": args.status, "restarted": args.restarted == "1", "selectors": selected,
                     "timing": interval({"started_at": args.started_at, "finished_at": args.finished_at})})
    write(path, attempts)


def finish(args):
    started = number(args.started_at)
    directory = Path(args.directory)
    report = {"schema_version": 1, "plan": check_plan(load(directory / "plan.json")),
              "attempts": load(directory / "attempts.json"), "cases": [], "exit_code": args.status,
              "validation": {"started_at": started, "finished_at": started}}
    code = 0
    try:
        require(len(report["attempts"]) == (2 if args.retry_results else 1), "retry evidence missing")
        for attempt, path in zip(report["attempts"], [args.results, args.retry_results]):
            attempt["cases"] = result_cases(path)
        report["cases"] = reconcile(report["plan"], report["attempts"])
    except Invalid as error:
        code = error.code
        print("error: " + str(error), file=sys.stderr)
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        code = 83
        print("error: unreadable shard result evidence", file=sys.stderr)
    report["exit_code"] = args.status or code
    report["validation"]["finished_at"] = time.time()
    write(directory / "worker.json", report)
    return report["exit_code"]


def aggregate(args):
    started = time.time()
    shard(args.count, 0)
    expected = {"run_id": args.run_id, "run_attempt": args.run_attempt, "revision": args.revision}
    identity(expected)
    jobs = load(args.jobs)
    fields(jobs, "schema_version run_id run_attempt revision workflow_created_at workers")
    identity(jobs)
    require(type(jobs["schema_version"]) is int and jobs["schema_version"] == 1
            and all(jobs[key] == value for key, value in expected.items()), "foreign job manifest")
    created = number(jobs["workflow_created_at"])
    require(isinstance(jobs["workers"], list) and len(jobs["workers"]) == args.count, "missing or extra job receipt")
    job_indices, active_seconds = [], 0
    for job in jobs["workers"]:
        fields(job, "index conclusion started_at completed_at")
        shard(args.count, job["index"])
        require(job["conclusion"] == "success", "worker job failed, cancelled or incomplete")
        require(created <= number(job["started_at"]) <= number(job["completed_at"]) <= started,
                "invalid authoritative job timestamps")
        active_seconds += job["completed_at"] - job["started_at"]
        job_indices.append(job["index"])
    require(sorted(job_indices) == list(range(args.count)), "duplicate or missing worker job")
    require(len(args.workers) == args.count, "missing or extra worker evidence")
    reports, indices, all_cases, common = [], [], [], None
    for path in args.workers:
        report = load(path)
        fields(report, "schema_version plan attempts cases exit_code validation")
        require(type(report["schema_version"]) is int and report["schema_version"] == 1
                and type(report["exit_code"]) is int and report["exit_code"] == 0,
                "worker did not finish successfully")
        plan = check_plan(report["plan"])
        ctx = plan["context"]
        require(all(ctx[key] == value for key, value in expected.items()) and plan["count"] == args.count,
                "foreign worker run, attempt, revision or shard count")
        shared = [plan[key] for key in ("catalog", "disabled", "weights", "assignments", "catalog_sha256")]
        shared.append(ctx["environment"])
        require(common is None or common == shared, "worker catalog, assignment or environment mismatch")
        common = shared
        cases = reconcile(plan, report["attempts"])
        require(cases == report["cases"], "terminal outcomes differ from attempt evidence")
        interval(report["validation"])
        require(report["validation"]["started_at"] >= report["attempts"][-1]["timing"]["finished_at"],
                "validation precedes execution")
        job = next(job for job in jobs["workers"] if job["index"] == plan["index"])
        require(job["started_at"] <= ctx["build"]["started_at"]
                and report["validation"]["finished_at"] <= job["completed_at"], "evidence outside worker job")
        indices.append(plan["index"])
        all_cases.extend(cases)
        reports.append(report)
    require(sorted(indices) == list(range(args.count)), "duplicate or missing shard")
    require(identifiers([case["identifier"] for case in all_cases]) == common[0], "incomplete combined coverage")
    ended = time.time()
    write(args.output, dict(expected, schema_version=1, count=args.count, catalog=common[0], disabled=common[1],
                           cases=sorted(all_cases, key=lambda case: case["identifier"]),
                           workers=sorted(reports, key=lambda report: report["plan"]["index"]), jobs=jobs,
                           validation={"started_at": started, "finished_at": ended},
                           feedback_seconds=ended - created, active_ui_runner_minutes=active_seconds / 60))
    print("Verified %d UI methods across %d worker(s); runtime skips remain explicit." % (len(all_cases), args.count))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("init", "plan", "attempt", "finish", "aggregate"):
        cmd = commands.add_parser(name)
        if name != "aggregate":
            cmd.add_argument("--directory", required=True)
        if name in ("init", "aggregate"):
            cmd.add_argument("--revision", required=True)
            cmd.add_argument("--count", type=int, required=True)
        if name == "init":
            cmd.add_argument("--context", required=True)
            cmd.add_argument("--index", type=int, required=True)
        if name in ("plan", "attempt"):
            cmd.add_argument("--finished-at", type=float, required=True)
        if name in ("plan", "attempt", "finish"):
            cmd.add_argument("--started-at", type=float, required=True)
        if name == "plan":
            cmd.add_argument("--catalog", required=True)
            cmd.add_argument("--simulator-udid", required=True)
            cmd.add_argument("--weights")
        if name in ("attempt", "finish"):
            cmd.add_argument("--status", type=int, required=True)
        if name == "attempt":
            cmd.add_argument("--restarted", choices=("0", "1"), required=True)
            cmd.add_argument("--selectors", default="")
        if name == "finish":
            cmd.add_argument("--results", required=True)
            cmd.add_argument("--retry-results")
        if name == "aggregate":
            cmd.add_argument("--run-id", required=True)
            cmd.add_argument("--run-attempt", type=int, required=True)
            cmd.add_argument("--jobs", required=True, help="independent same-attempt GitHub job receipts, not worker claims")
            cmd.add_argument("--output", required=True)
            cmd.add_argument("workers", nargs="+")
    args = parser.parse_args()
    try:
        return {"init": initialize, "plan": make_plan, "attempt": add_attempt,
                "finish": finish, "aggregate": aggregate}[args.command](args) or 0
    except Invalid as error:
        print("error: " + str(error), file=sys.stderr)
        return error.code
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        print("error: unreadable or malformed shard evidence (or output directory already exists)", file=sys.stderr)
        return 83


if __name__ == "__main__":
    sys.exit(main())