#!/usr/bin/env python3
"""Manual CI trial boundary: measured context, same-attempt receipts and artifacts.

Uses only the standard library and the runner's authenticated gh CLI. Never prints
API bodies, credentials or environment dumps. Full-attempt reruns are supported;
partial reruns fail closed unless every required worker belongs to this attempt.
The separate shard engine remains the owner of catalog/result reconciliation.
"""

import argparse
from datetime import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time
import zipfile


class Invalid(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Invalid(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def decode(value):
    return json.loads(value, object_pairs_hook=unique_object)


def write(path, value):
    with Path(path).open("x") as output:
        json.dump(value, output, indent=2, sort_keys=True, allow_nan=False)
        output.write("\n")


def command(*args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(result.returncode == 0, "command failed: " + args[0])
    return result.stdout


def fact(*args):
    value = " ".join(command(*args).decode().split())
    require(re.fullmatch(r"[A-Za-z0-9_.+ /()-]{1,160}", value), "invalid environment fact")
    return value


def identity():
    revision, run_id = os.environ["GITHUB_SHA"], os.environ["GITHUB_RUN_ID"]
    attempt = os.environ["GITHUB_RUN_ATTEMPT"]
    require(re.fullmatch(r"[0-9a-f]{40}", revision) and re.fullmatch(r"[1-9][0-9]*", run_id)
            and re.fullmatch(r"[1-9][0-9]*", attempt), "invalid workflow identity")
    require(command("git", "rev-parse", "HEAD").decode().strip() == revision, "checkout differs from workflow revision")
    return {"revision": revision, "run_id": run_id, "run_attempt": int(attempt)}


def validate():
    require(os.environ["GITHUB_EVENT_NAME"] == "workflow_dispatch", "trial is manual only")
    mode = os.environ["TRIAL_MODE"]
    require(mode in ("serial", "two-shards"), "invalid trial mode")
    require(os.environ.get("ONLY_TESTING", "") == "", "trial conflicts with only_testing")
    identity()
    count = 1 if mode == "serial" else 2
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write("count=%d\nmatrix=%s\n" % (count, json.dumps({"index": list(range(count))})))


def build():
    identity()
    require(os.environ["BUILD_CONFIGURATION"] == "Debug", "trial requires Debug")
    require(not Path("trial-build.json").exists(), "build receipt already exists")
    started = time.time()
    status = subprocess.run(["scripts/xcodebuild.sh", "build-for-testing"]).returncode
    require(status == 0, "fresh build-for-testing failed")
    write("trial-build.json", {"started_at": started, "finished_at": time.time()})


def context():
    expected = identity()
    doc = decode(command("xcrun", "simctl", "list", "-j"))
    matches = [(runtime, device) for runtime, devices in doc["devices"].items()
               for device in devices if device["udid"] == os.environ["SIM_UDID"]]
    require(len(matches) == 1, "selected simulator is missing or ambiguous")
    runtime_id, device = matches[0]
    runtimes = [item for item in doc["runtimes"] if item["identifier"] == runtime_id]
    require(len(runtimes) == 1 and runtimes[0]["isAvailable"] and device["isAvailable"],
            "selected simulator runtime is unavailable")
    runtime = runtimes[0]
    types = [item for item in doc["devicetypes"] if item["identifier"] == device["deviceTypeIdentifier"]]
    require(len(types) == 1, "selected simulator device type is unverifiable")
    cache = {}
    for name in ("spm", "tailcat"):
        hit = os.environ[name.upper() + "_CACHE_HIT"]
        require(hit in ("true", "false", ""), "invalid cache observation")
        cache[name] = {"true": "hit", "false": "restored", "": "miss"}[hit]
    write("trial-context.json", dict(expected, schema_version=1, cache=cache,
          build=decode(Path("trial-build.json").read_text()), environment={
              "configuration": os.environ["BUILD_CONFIGURATION"],
              "xcode": fact("xcodebuild", "-version"),
              "sdk": fact("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version") + " "
                     + fact("xcrun", "--sdk", "iphonesimulator", "--show-sdk-build-version"),
              "runtime": " ".join([runtime_id, runtime["version"], runtime["buildversion"]]),
              "device_type": types[0]["identifier"], "architecture": platform.machine(),
              "runner": "macos-15 " + os.environ["ImageOS"] + " " + os.environ["ImageVersion"]}))


def timestamp(value):
    require(isinstance(value, str) and value.endswith("Z"), "missing authoritative timestamp")
    return datetime.fromisoformat(value[:-1] + "+00:00").timestamp()


def api(path):
    return decode(command("gh", "api", path))


def pages(path, key):
    """Explicit bounded pagination; changing totals, duplicates and truncation fail."""
    records, total = [], None
    for page in range(1, 101):
        doc = api(path + "?per_page=100&page=" + str(page))
        size = doc["total_count"]
        require(type(size) is int and size >= 0 and (total is None or size == total), "unstable API total")
        total = size
        batch = doc[key]
        require(isinstance(batch, list) and len(batch) <= 100, "invalid API page")
        records.extend(batch)
        require(len(records) <= total and len({item["id"] for item in records}) == len(records),
                "duplicate or excess API records")
        if len(records) == total:
            return records
        require(len(batch) == 100, "truncated API pagination")
    raise Invalid("API pagination limit exceeded")


def collect(count, directory):
    expected = identity()
    require(count in (1, 2), "invalid worker count")
    repository = os.environ["GITHUB_REPOSITORY"]
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository), "invalid repository")
    base = "repos/%s/actions" % repository
    run_path = base + "/runs/" + expected["run_id"]
    attempt_path = run_path + "/attempts/" + str(expected["run_attempt"])
    run = api(attempt_path)
    require(str(run["id"]) == expected["run_id"] and run["run_attempt"] == expected["run_attempt"]
            and run["head_sha"] == expected["revision"] and run["event"] == "workflow_dispatch"
            and run["path"] == ".github/workflows/ci.yml"
            and run["repository"]["full_name"] == repository, "foreign workflow attempt")
    created = timestamp(run["created_at"])
    attempt_started = timestamp(run["run_started_at"])
    jobs = pages(attempt_path + "/jobs", "jobs")
    names = ["UI Trial Worker %d (non-gating)" % index for index in range(count)]
    workers = [job for job in jobs if job["name"].startswith("UI Trial Worker ")]
    require(len(workers) == count and sorted(job["name"] for job in workers) == names,
            "missing or ambiguous worker job mapping")
    receipts, provenance = [], []
    for index, name in enumerate(names):
        job = next(job for job in workers if job["name"] == name)
        require(str(job["run_id"]) == expected["run_id"] and job["run_attempt"] == expected["run_attempt"]
                and job["head_sha"] == expected["revision"], "stale or partial-attempt worker receipt")
        require(job["status"] == "completed" and job["conclusion"] == "success",
                "worker failed, cancelled or incomplete")
        start, end = timestamp(job["started_at"]), timestamp(job["completed_at"])
        require(created <= attempt_started <= start <= end <= time.time(), "invalid job interval")
        uploads = [step for step in job["steps"] if step["name"] == "Upload UI trial evidence"]
        require(len(uploads) == 1 and uploads[0]["status"] == "completed"
                and uploads[0]["conclusion"] == "success", "missing or failed evidence upload")
        upload_start, upload_end = timestamp(uploads[0]["started_at"]), timestamp(uploads[0]["completed_at"])
        require(start <= upload_start <= upload_end <= end, "invalid upload interval")
        receipts.append({"index": index, "conclusion": job["conclusion"], "started_at": start, "completed_at": end})
        provenance.append({"index": index, "job_id": job["id"], "job_name": name,
                           "upload_started_at": upload_start, "upload_completed_at": upload_end})
    artifacts = pages(run_path + "/artifacts", "artifacts")
    prefix = "ui-trial-%s-%s-%s-" % (expected["revision"], expected["run_id"], expected["run_attempt"])
    candidates = [item for item in artifacts if item["name"].startswith(prefix)]
    require(len(candidates) == count and sorted(item["name"] for item in candidates)
            == [prefix + str(index) for index in range(count)], "missing or ambiguous worker artifacts")
    directory = Path(directory)
    directory.mkdir(exist_ok=False)
    for receipt, source in zip(receipts, provenance):
        index = receipt["index"]
        artifact = next(item for item in candidates if item["name"] == prefix + str(index))
        require(artifact["expired"] is False and artifact["workflow_run"]["id"] == int(expected["run_id"])
                and artifact["workflow_run"]["head_sha"] == expected["revision"], "foreign or expired artifact")
        require(source["upload_started_at"] <= timestamp(artifact["created_at"])
                <= timestamp(artifact["updated_at"]) <= source["upload_completed_at"], "artifact outside worker upload")
        require(0 < artifact["size_in_bytes"] <= 20_000_000, "invalid evidence artifact size")
        digest = artifact["digest"]
        require(isinstance(digest, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", digest), "missing artifact digest")
        archive = command("gh", "api", base + "/artifacts/%d/zip" % artifact["id"])
        require("sha256:" + hashlib.sha256(archive).hexdigest() == digest, "artifact digest mismatch")
        with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
            require(bundle.namelist() == ["worker.json"] and bundle.getinfo("worker.json").file_size <= 10_000_000,
                    "unexpected evidence archive contents")
            report = decode(bundle.read("worker.json"))
        plan = report["plan"]
        require(plan["index"] == index and plan["count"] == count
                and all(plan["context"][key] == value for key, value in expected.items()), "foreign artifact payload")
        write(directory / ("worker-%d.json" % index), report)
        source["artifact"] = {key: artifact[key] for key in ("id", "name", "digest", "created_at", "updated_at")}
    write(directory / "jobs.json", dict(expected, schema_version=1, workflow_created_at=created, workers=receipts))
    write(directory / "provenance.json", dict(expected, schema_version=1, attempt_started_at=attempt_started,
                                             collected_at=time.time(), workers=provenance))
    result = subprocess.run([sys.executable, str(Path(__file__).with_name("ui-test-shards.py")), "aggregate",
                             "--revision", expected["revision"], "--run-id", expected["run_id"],
                             "--run-attempt", str(expected["run_attempt"]), "--count", str(count),
                             "--jobs", str(directory / "jobs.json"), "--output", str(directory / "combined.json"),
                             *[str(directory / ("worker-%d.json" % index)) for index in range(count)]])
    require(result.returncode == 0, "combined coverage validation failed")
    summary(decode((directory / "combined.json").read_text()))


def summary(combined):
    def duration(interval):
        return interval["finished_at"] - interval["started_at"]

    lines = ["## UI trial verified (non-gating)", "",
             "Revision: `%s`; run %s, attempt %s." % tuple(combined[key] for key in ("revision", "run_id", "run_attempt")),
             "Feedback from original workflow creation: %.1fs; active UI runner minutes: %.2f."
             % (combined["feedback_seconds"], combined["active_ui_runner_minutes"]),
             "", "| Worker | Start delay | Setup | Build | Discovery | Primary | Retry | Validation | Other/gaps | Cases |",
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    details = []
    for worker in combined["workers"]:
        plan = worker["plan"]
        job = next(item for item in combined["jobs"]["workers"] if item["index"] == plan["index"])
        setup = plan["context"]["build"]["started_at"] - job["started_at"]
        build_seconds, discovery = duration(plan["context"]["build"]), duration(plan["discovery"])
        primary = duration(worker["attempts"][0]["timing"])
        retry = sum(duration(item["timing"]) for item in worker["attempts"][1:])
        validation = duration(worker["validation"])
        gaps = job["completed_at"] - job["started_at"] - setup - build_seconds - discovery - primary - retry - validation
        lines.append("| %d | %.1fs | %.1fs | %.1fs | %.1fs | %.1fs | %.1fs | %.1fs | %.1fs | %d |" % (
            plan["index"], job["started_at"] - combined["jobs"]["workflow_created_at"], setup,
            build_seconds, discovery, primary, retry, validation, gaps, len(worker["cases"])))
        details.append("Worker %d: advisory assigned weight %.1fs; caches %s." % (
            plan["index"], sum(plan["weights"][case] for case in plan["assignments"][plan["index"]]),
            json.dumps(plan["context"]["cache"], sort_keys=True)))
    lines += [""] + details
    lines += ["", "Environment: " + json.dumps(combined["workers"][0]["plan"]["context"]["environment"], sort_keys=True),
              "", "| Case | Terminal outcome | Attempt | Seconds |", "| --- | --- | ---: | ---: |"]
    for case in combined["cases"]:
        lines.append("| %s | %s | %s | %s |" % tuple(case[key] for key in ("identifier", "outcome", "attempt", "duration_seconds")))
    lines += ["", "Final aggregate validation: %.3fs." % duration(combined["validation"]),
              "Exact catalog, disabled tests, retries, job/artifact receipts and phase timestamps are in the combined artifact.",
              "Start delay is not proven runner queue time. Other/gaps includes boot, selectors, uploads and cleanup.",
              "Compare identical catalogs/outcomes/environments and report cache differences before comparing speed."]
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as output:
        output.write("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("validate", "build", "context", "collect"):
        cmd = commands.add_parser(name)
        if name == "collect":
            cmd.add_argument("--count", required=True, type=int, choices=(1, 2))
            cmd.add_argument("--directory", required=True)
    args = parser.parse_args()
    try:
        if args.command == "collect":
            collect(args.count, args.directory)
        else:
            {"validate": validate, "build": build, "context": context}[args.command]()
        return 0
    except Invalid as error:
        print("error: " + str(error), file=sys.stderr)
    except (OSError, ValueError, TypeError, KeyError, AttributeError, zipfile.BadZipFile):
        print("error: missing or malformed trial evidence/context", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())