#!/usr/bin/env python3
"""Own one disposable iPad for the optional, filtered, non-gating CI lane."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid


def write_json(path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def run(args):
    return subprocess.run(args, text=True, capture_output=True, check=False)


def checked(args):
    result = run(args)
    if result.returncode:
        raise RuntimeError(f"{args[:3]} exited {result.returncode}: {result.stderr}")
    return result.stdout


def validate(env):
    family = env.get("SIMULATOR_FAMILY", "iphone")
    if family not in ("iphone", "ipad"):
        raise ValueError("simulator_family must be iphone or ipad")
    selectors = list(dict.fromkeys(env.get("ONLY_TESTING", "").split()))
    if family == "ipad":
        pattern = r"(?:IntentTests|IntentUITests)/[A-Za-z_]\w*(?:/[A-Za-z_]\w*(?:\([^()\s]*\))?)?"
        if env.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
            raise ValueError("iPad selection is only available to workflow_dispatch")
        if not 1 <= len(selectors) <= 20 or any(not re.fullmatch(pattern, item) for item in selectors):
            raise ValueError("iPad requires 1–20 bounded Target/Suite[/test] selectors; full bundles are refused")
    return family, selectors


def device_rows(document):
    return [(runtime, device) for runtime, devices in document["devices"].items() for device in devices]


def choose_ipad(document):
    # An available installed device establishes a compatible type/runtime pair.
    # Create a new instance of that pair; never boot or reuse the listed device.
    runtimes = {item["identifier"]: item for item in document["runtimes"]
                if item.get("isAvailable") is True and ".SimRuntime.iOS-" in item["identifier"]}
    types = {item["identifier"]: item for item in document["devicetypes"]
             if item.get("productFamily") == "iPad" or item.get("name", "").startswith("iPad")}
    choices = [(runtime, device) for runtime, device in device_rows(document)
               if runtime in runtimes and device.get("isAvailable") is True
               and device.get("deviceTypeIdentifier") in types]
    if not choices:
        raise ValueError("No available compatible iPad and installed iOS runtime; refusing iPhone fallback")
    runtime, device = max(choices, key=lambda item: (
        tuple(int(part) for part in runtimes[item[0]]["version"].split(".")),
        item[1]["deviceTypeIdentifier"], item[1]["udid"]))
    return {"runtime": runtimes[runtime], "deviceType": types[device["deviceTypeIdentifier"]]}


def prepare(env, directory):
    family, selectors = validate(env)
    if family != "ipad":
        raise ValueError("prepare is reserved for the iPad lane; default iPhone selection stays in xcodebuild.sh")
    if (directory / "ownership.json").exists():
        raise ValueError("An iPad ownership receipt already exists; refusing another simulator")
    document = json.loads(checked(["xcrun", "simctl", "list", "--json"]))
    write_json(directory / "available-simulators.json", document)
    selection = choose_ipad(document)
    plan = dict(selection, name="Intent CI iPad " + str(uuid.uuid4()), selectors=selectors,
                preexisting=[device["udid"] for _, device in device_rows(document)],
                createdUDID=None, createAttempted=False,
                provenance={key: env.get(key) for key in (
                    "GITHUB_SHA", "GITHUB_REF", "GITHUB_HEAD_REF", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT")})
    plan["checkout"] = checked(["git", "rev-parse", "HEAD"]).strip()
    plan["tree"] = checked(["git", "rev-parse", "HEAD^{tree}"]).strip()
    plan["parents"] = checked(["git", "show", "-s", "--format=%P", "HEAD"]).strip().split()
    plan["xcode"] = checked(["xcodebuild", "-version"]).strip()
    # Persist the unique creation intent first so always-cleanup can recover
    # from termination between simctl creation and recording its returned UDID.
    plan["createAttempted"] = True
    write_json(directory / "ownership.json", plan)
    result = run(["xcrun", "simctl", "create", plan["name"],
                  selection["deviceType"]["identifier"], selection["runtime"]["identifier"]])
    write_json(directory / "creation.json", {"exitCode": result.returncode, "stdout": result.stdout, "stderr": result.stderr})
    if result.returncode:
        raise RuntimeError("simctl create failed; retained creation output and ownership intent for cleanup")
    udid = result.stdout.strip()
    if not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", udid) or udid in plan["preexisting"]:
        raise ValueError("simctl did not return a new simulator UDID")
    plan["createdUDID"] = udid
    write_json(directory / "ownership.json", plan)
    with Path(env["GITHUB_ENV"]).open("a") as output:
        output.write(f"SIM_UDID={udid}\n")
    print(f"Fresh non-gating iPad: {selection['deviceType']['name']} / {selection['runtime']['name']} / {udid}")


def cleanup(directory):
    receipt = directory / "ownership.json"
    if not receipt.exists():
        write_json(directory / "cleanup.json", {"result": "no simulator creation attempted"})
        return
    plan = json.loads(receipt.read_text())
    if not plan.get("createAttempted"):
        raise ValueError("Missing creation intent; refusing simulator cleanup")
    document = json.loads(checked(["xcrun", "simctl", "list", "--json"]))
    matches = [device for runtime, device in device_rows(document)
               if device.get("name") == plan["name"]
               and runtime == plan["runtime"]["identifier"]
               and device.get("deviceTypeIdentifier") == plan["deviceType"]["identifier"]
               and device["udid"] not in plan["preexisting"]]
    if not matches:
        if any(device["udid"] == plan["createdUDID"] for _, device in device_rows(document)):
            raise ValueError("Created UDID has different ownership metadata; refusing cleanup")
        write_json(directory / "cleanup.json", {"result": "owned simulator absent", "udid": plan["createdUDID"]})
        return
    if len(matches) != 1 or plan["createdUDID"] not in (None, matches[0]["udid"]):
        raise ValueError("Simulator ownership does not match; refusing cleanup")
    udid = matches[0]["udid"]
    # This also recovers a successful create whose receipt write was interrupted.
    shutdown = run(["xcrun", "simctl", "shutdown", udid])
    deletion = run(["xcrun", "simctl", "delete", udid])
    write_json(directory / "cleanup.json", {"udid": udid, "shutdownExit": shutdown.returncode,
               "shutdownError": shutdown.stderr, "deleteExit": deletion.returncode, "deleteError": deletion.stderr})
    if deletion.returncode:
        raise RuntimeError("Could not delete the owned simulator; cleanup evidence retained")


def matches_selector(selector, identifier):
    wanted, actual = selector.split("/"), identifier.split("/")
    if len(wanted) > len(actual):
        return False
    return all(want == have or index == len(actual) - 1
               and want.split("(", 1)[0] == have.split("(", 1)[0] and ("(" not in want or "(" not in have)
               for index, (want, have) in enumerate(zip(wanted, actual)))


def result_cases(bundle, directory, label):
    result = run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)])
    (directory / (label + "-results.json")).write_text(result.stdout)
    (directory / (label + "-results.stderr")).write_text(result.stderr)
    if result.returncode:
        raise RuntimeError(f"Cannot read {label} result bundle (exit {result.returncode})")
    document = json.loads(result.stdout)
    if not isinstance(document, dict) or not isinstance(document.get("testNodes"), list):
        raise ValueError("Result bundle has no testNodes; iPad coverage cannot be verified")
    cases = {}

    def walk(nodes, target=""):
        for node in nodes:
            kind = node.get("nodeType", "")
            if kind.lower().endswith("test bundle"):
                target = node.get("name", "")
            if kind == "Test Case":
                identifier = node.get("nodeIdentifier") or node.get("name", "")
                if target and not identifier.startswith(target + "/"):
                    identifier = target + "/" + identifier
                # Count declarations, as the wrapper's flat catalog does. Keep
                # parameter labels distinct; invocations/attempts below a Test
                # Case never create another resolved declaration.
                identifier = identifier.removesuffix("()")
                cases.setdefault(identifier, set()).add(node.get("result", ""))
            else:
                walk(node.get("children", []), target)

    walk(document["testNodes"])
    return cases


def verify_execution(env, directory):
    _, selectors = validate(env)
    # Keep the wrapper's enumeration, xcresult accounting, retry and error
    # semantics unchanged. This extra platform-proof check requires the whole
    # resolved selection, counting each declaration once across attempts.
    log = (directory / "test.log").read_text()
    bundle = Path(env.get("RESULT_BUNDLE", "TestResults"))
    cases = result_cases(bundle, directory, "primary")
    retry = bundle.with_name(bundle.stem + "-retry.xcresult") if bundle.suffix == ".xcresult" else Path(str(bundle) + "-retry")
    if retry.exists():
        notices = re.findall(r"^notice: re-running the interrupted suite\(s\) once, alone: (.+)$", log, re.MULTILINE)
        if len(notices) != 1:
            raise ValueError("Retry bundle has no unambiguous interrupted-suite transcript")
        interrupted = notices[0].split()
        # Primary results from an interrupted suite are not proof. Only its
        # retry can restore coverage; never sum passes from repeated attempts.
        cases = {key: value for key, value in cases.items() if not any(matches_selector(suite, key) for suite in interrupted)}
        cases.update(result_cases(retry, directory, "retry"))
    rows = []
    for selector in selectors:
        matches = re.findall(r"^\s*" + re.escape(selector) + r"\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$", log, re.MULTILINE)
        values = list(map(int, matches[-1])) if matches else None
        selected = {key: sorted(value) for key, value in cases.items() if matches_selector(selector, key)}
        rows.append({"selector": selector, "counts": values, "uniqueCases": selected})
    write_json(directory / "execution.json", {"columns": ["resolved", "executed", "skipped", "failed", "unknown"], "rows": rows})
    if any(row["counts"] is None or row["counts"][0] < 1 or row["counts"][1] < row["counts"][0]
           or any(row["counts"][2:]) or len(row["uniqueCases"]) != row["counts"][0]
           or any(not set(results) <= {"Passed", "Expected Failure"} for results in row["uniqueCases"].values()) for row in rows):
        raise ValueError("iPad proof requires every resolved declaration to execute without skips, failures or unknown results")


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("validate", "prepare", "cleanup", "verify"):
        raise ValueError("usage: ci_simulator.py validate|prepare|cleanup|verify")
    action = sys.argv[1]
    directory = Path(os.environ["IPAD_EVIDENCE_DIR"])
    directory.mkdir(parents=True, exist_ok=True)
    try:
        if action == "validate":
            write_json(directory / "request.json", {"family": os.environ.get("SIMULATOR_FAMILY"),
                       "event": os.environ.get("GITHUB_EVENT_NAME"), "onlyTesting": os.environ.get("ONLY_TESTING")})
            validate(os.environ)
        elif action == "prepare":
            prepare(os.environ, directory)
        elif action == "cleanup":
            cleanup(directory)
        else:
            verify_execution(os.environ, directory)
    except (ValueError, RuntimeError, OSError, KeyError) as error:
        write_json(directory / (action + "-error.json"), {"error": str(error)})
        raise


if __name__ == "__main__":
    main()
