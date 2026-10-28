#!/usr/bin/env python3
"""Partition the built full UI inventory and verify the two lanes agree."""

import argparse
import json
import math
import os
from pathlib import Path
import re
import sys


SELECTOR = re.compile(r"IntentUITests/[A-Za-z_][A-Za-z0-9_]*/test[A-Za-z0-9_]+")
DEFAULT_SECONDS = 20


def inventory(document):
    found = {"enabledTests": [], "disabledTests": []}

    def walk(node):
        if isinstance(node, dict):
            if node.get("errors"):
                raise ValueError("test enumeration reported errors")
            for key in found:
                if key not in node:
                    continue
                if not isinstance(node[key], list):
                    raise ValueError(f"invalid {key} inventory")
                for item in node[key]:
                    identifier = item if isinstance(item, str) else item.get("identifier") if isinstance(item, dict) else None
                    if not isinstance(identifier, str):
                        raise ValueError("enumerated test has no identifier")
                    if not identifier.startswith("IntentUITests/"):
                        continue
                    selector = identifier.removesuffix("()")
                    if not SELECTOR.fullmatch(selector):
                        raise ValueError(f"invalid UI test identifier: {identifier}")
                    if selector in found[key]:
                        raise ValueError(f"duplicate UI test: {selector}")
                    found[key].append(selector)
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(document)
    enabled, disabled = (sorted(found[key]) for key in found)
    if not enabled:
        raise ValueError("no enabled UI tests in the built inventory")
    if set(enabled) & set(disabled):
        raise ValueError("UI test is both enabled and disabled")
    if any(selector.split("/")[1] == "AppStoreScreenshotTests" for selector in enabled):
        raise ValueError("AppStoreScreenshotTests must remain disabled by the scheme")
    return enabled, disabled


def partition(enabled, weights):
    suites = {}
    for selector in enabled:
        suites.setdefault(selector.split("/")[1], []).append(selector)
    if len(suites) < 2:
        raise ValueError("full UI inventory needs at least two suites for nonempty shards")
    costs = {}
    for suite, tests in suites.items():
        cost = weights.get(suite, len(tests) * DEFAULT_SECONDS)
        if isinstance(cost, bool) or not isinstance(cost, (float, int)) or not math.isfinite(cost) or cost <= 0:
            raise ValueError(f"invalid duration for {suite}")
        costs[suite] = cost
    shards, seconds = {"1": [], "2": []}, {"1": 0, "2": 0}
    for suite in sorted(suites, key=lambda name: (-costs[name], name)):
        lane = min(seconds, key=lambda key: (seconds[key], key))
        shards[lane].extend(suites[suite])
        seconds[lane] += costs[suite]
    return {key: sorted(value) for key, value in shards.items()}, seconds


def validate_plan(plan):
    if plan.get("version") != 1 or type(plan.get("shard")) is not int or plan["shard"] not in (1, 2):
        raise ValueError("invalid full UI shard plan")
    enabled, disabled = inventory({"enabledTests": plan["catalog"], "disabledTests": plan["disabled"]})
    shards = plan["shards"]
    if not isinstance(shards, dict) or set(shards) != {"1", "2"}:
        raise ValueError("plan must describe both shards")
    flat = []
    for selectors in shards.values():
        if not isinstance(selectors, list) or not selectors or any(not isinstance(s, str) or not SELECTOR.fullmatch(s) for s in selectors):
            raise ValueError("empty or invalid shard selection")
        flat.extend(selectors)
    if len(flat) != len(set(flat)) or set(flat) != set(enabled):
        raise ValueError("shards contain duplicate, missing, or extra tests")
    return enabled, disabled, shards


def verify_plans(root, revision):
    paths = sorted(Path(root).rglob("ui-test-shard-plan.json"))
    if len(paths) != 2:
        raise ValueError("expected exactly two full UI shard plans")
    baseline, seen = None, set()
    for path in paths:
        plan = json.loads(path.read_text())
        signature = validate_plan(plan)
        if plan["shard"] in seen or plan.get("revision") != revision:
            raise ValueError("duplicate shard or incorrect tested revision")
        seen.add(plan["shard"])
        if baseline is not None and signature != baseline:
            raise ValueError("full UI lanes disagree on the built inventory or partition")
        baseline = signature
        identities = json.loads(path.with_name("ui-test-identities.json").read_text())
        selected = plan["shards"][str(plan["shard"])]
        resolved = identities.get("selectors", {})
        if identities.get("version") != 1 or set(resolved) != set(selected):
            raise ValueError("resolved selectors do not match the shard plan")
        for selector in selected:
            if resolved[selector] not in ([selector], [selector + "()"]):
                raise ValueError("resolved test identity differs from the shard plan")
    return len(baseline[0])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path)
    parser.add_argument("--shard", choices=("1", "2"))
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--weights", type=Path, default=Path(__file__).with_name("ui-full-test-durations.json"))
    parser.add_argument("--verify-plans", type=Path)
    parser.add_argument("--revision", default=os.environ.get("GITHUB_SHA", "local"))
    args = parser.parse_args(argv)
    try:
        if args.verify_plans:
            if args.catalog or args.shard or args.plan:
                raise ValueError("plan verification cannot select tests")
            count = verify_plans(args.verify_plans, args.revision)
            print(f"Full UI coverage verified: {count} enabled tests partitioned exactly once across both lanes")
            return 0
        if not args.catalog or not args.shard:
            raise ValueError("selection requires --catalog and --shard")
        enabled, disabled = inventory(json.loads(args.catalog.read_text()))
        weights = json.loads(args.weights.read_text())["suiteSeconds"]
        if not isinstance(weights, dict):
            raise ValueError("invalid suite durations")
        shards, seconds = partition(enabled, weights)
        plan = {"version": 1, "revision": args.revision, "shard": int(args.shard),
                "catalog": enabled, "disabled": disabled, "shards": shards, "estimatedSeconds": seconds}
        validate_plan(plan)
        if args.plan:
            args.plan.write_text(json.dumps(plan, indent=2) + "\n")
        print(f"Full UI shard {args.shard}/2: {len(shards[args.shard])}/{len(enabled)} enabled tests, "
              f"estimated {seconds[args.shard] / 60:.1f} minutes of test bodies", file=sys.stderr)
        print(" ".join(shards[args.shard]))
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    sys.exit(main())
