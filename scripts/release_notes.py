#!/usr/bin/env python3
"""Offline-first release-note entry generator; no credentials, network, or writes.

generate(repo, request, read) returns a JSON-compatible, review-required payload.
`read(path, query)` is a GET-only adapter (e.g. a caller-owned Client.request).
The caller selects the exact candidate and previous Beta / released App Store
baseline, records baseline_reference, and retains this payload across retries.
This module verifies their identities/provenance, NOT their channel membership.

CLI: --repo CHECKOUT --input REQUEST.json --responses SNAPSHOT.json. Responses
are keyed by path plus sorted URL-encoded query (request_key). It only prints
JSON; even preview cannot authenticate or access Apple. Snapshots and explicit
human attestations are trusted inputs, not cryptographically signed receipts.

Apple OpenAPI 4.5 checked 2026-09-27 (public schema, no ASC calls):
https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip
JSON SHA256: 1e8ef250d6a41bab0f5670b669abf3f06298ef129c8455ba258149fda86927b2
GET builds/{id}: app + preReleaseVersion identify app, platform, version/build.
GET apps/{id}/ciProduct; ciProducts/{id}/buildRuns?filter[builds]={buildID};
GET ciBuildRuns/{id}/relationships/builds verifies exact build membership.
sourceCommit.commitSha + sourceBranchOrTag -> GET scmGitReferences/{id},
including repository.httpCloneUrl, bind non-PR source to the expected repository.
There is NO builds/{id}/ciBuildRun endpoint. Missing/ambiguous/PR provenance
requires a separate, explicit human-verified mapping, never an automatic fallback.
Expiry does not invalidate a historical source baseline. This is not a build
eligibility check. No source dates, build numbers, tags or HEAD are SHA guesses.

Output is an entry payload for root CHANGELOG.md only: version_heading,
channel_heading, entry_key, markdown_entry, plain_text, changes and provenance.
The later publisher owns version ordering, PM-edit protection and concurrency;
this module never reads/writes CHANGELOG.md or creates per-release Markdown.
Local bounds (not claims about Apple's limits): 1000 commits, 200 bullets,
280 characters per subject, 3500 plain-text characters; overflow fails closed.
"""

import argparse
from datetime import datetime
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unicodedata
from urllib.parse import urlencode, urlsplit

MAX_BYTES = 8 * 1024 * 1024
BUILD_QUERY = {
    "fields[builds]": "version,app,preReleaseVersion",
    "include": "app,preReleaseVersion",
    "fields[apps]": "bundleId",
    "fields[preReleaseVersions]": "version,platform",
}
RUN_FIELDS = "sourceCommit,destinationCommit,isPullRequestBuild,executionProgress,completionStatus,product,sourceBranchOrTag"


class NotesError(Exception):
    """Fixed, credential-free actionable messages only."""


def require(condition, message):
    if not condition:
        raise NotesError(message)


def text(value, limit=500):
    require(isinstance(value, str) and 0 < len(value) <= limit,
            "Missing or oversized text; provide explicit bounded metadata.")
    require(not any(unicodedata.category(c).startswith("C") or c in "\u2028\u2029" for c in value),
            "Control characters in metadata; provide plain single-line text.")
    require(bool(value.strip()), "Empty metadata; provide an explicit value.")
    return value


def identifier(value):
    require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9-]{1,100}", value),
            "Missing or invalid resource ID.")
    return value


def revision(value):
    require(isinstance(value, str) and re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", value),
            "A full lowercase source commit SHA is required; refs and short SHAs are refused.")
    return value


def version(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9]{1,10}(?:\.[0-9]{1,10}){0,2}", value),
            "Expected a numeric Apple version/build identifier.")
    return value


def repository_url(value):
    # This repository's delivery target is GitHub. Do not accept credentials,
    # queries, fragments, local paths, arbitrary hosts or executable transports.
    require(isinstance(value, str), "Expected a GitHub repository URL.")
    match = re.fullmatch(r"(?:https://github\.com/|git@github\.com:)([A-Za-z0-9_-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?", value)
    require(match is not None, "Expected a credential-free GitHub repository URL.")
    require(all(part not in (".", "..") for part in match[1].split("/")), "Invalid repository path.")
    return "https://github.com/" + match[1].lower()


def resource(value, kind, expected_id=None):
    require(isinstance(value, dict) and value.get("type") == kind, "Missing or unexpected Apple resource.")
    identifier(value.get("id"))
    require(expected_id is None or value["id"] == expected_id, "Apple returned the wrong resource ID.")
    return value


def attrs(value):
    result = value.get("attributes")
    require(isinstance(result, dict), "Missing Apple resource attributes.")
    return result


def relation(value, name, kind):
    relationships = value.get("relationships")
    require(isinstance(relationships, dict), "Missing Apple resource relationships.")
    item = relationships.get(name)
    require(isinstance(item, dict), "Missing Apple relationship.")
    return resource(item.get("data"), kind)


def included(page, link, kind):
    items = page.get("included")
    require(isinstance(items, list), "Missing included Apple resources.")
    matches = [v for v in items if isinstance(v, dict) and v.get("type") == kind and v.get("id") == link["id"]]
    require(len(matches) == 1, "Missing or ambiguous included Apple resource.")
    return resource(matches[0], kind, link["id"])


def request_key(path, query=None):
    return path + ("?" + urlencode(sorted(query.items())) if query else "")


def read_page(read, path, query=None):
    try:
        result = read(path, query)
    except Exception:
        raise NotesError("Apple read unavailable; supply verified provenance or repair the read source.") from None
    require(isinstance(result, dict), "Invalid Apple response.")
    return result


def collection(read, path, query, kind):
    by_id, seen = {}, set()
    endpoint = path
    for _ in range(20):
        page = read_page(read, path, query)
        require(isinstance(page.get("data"), list), "Missing Apple collection.")
        for item in page["data"]:
            item = resource(item, kind)
            key = item["id"]
            require(key not in by_id or by_id[key] == item, "Apple resources changed across pages.")
            by_id[key] = item
        require(len(by_id) <= 1000, "Apple collection exceeds the safety bound.")
        links = page.get("links")
        require(isinstance(links, dict) and isinstance(links.get("self"), str), "Incomplete Apple pagination metadata.")
        # PagedDocumentLinks requires self, but next is optional on the last page.
        next_url = links.get("next")
        if next_url is None:
            return list(by_id.values())
        require(isinstance(next_url, str), "Invalid Apple pagination link.")
        parsed = urlsplit(next_url)
        require(parsed.scheme == "https" and parsed.netloc == "api.appstoreconnect.apple.com"
                and parsed.path == endpoint and not parsed.fragment and next_url not in seen,
                "Unsafe or repeated Apple pagination link.")
        seen.add(next_url)
        path, query = next_url, None
    raise NotesError("Apple pagination exceeds the safety bound; no partial result generated.")


def build_identity(read, build_id, app_id, bundle_id):
    page = read_page(read, f"/v1/builds/{identifier(build_id)}", BUILD_QUERY)
    build = resource(page.get("data"), "builds", build_id)
    app = included(page, relation(build, "app", "apps"), "apps")
    require(app["id"] == app_id and attrs(app).get("bundleId") == bundle_id, "Build belongs to the wrong app.")
    release = included(page, relation(build, "preReleaseVersion", "preReleaseVersions"), "preReleaseVersions")
    require(attrs(release).get("platform") == "IOS", "Build platform must be IOS.")
    return {"app_id": app_id, "bundle_id": bundle_id, "platform": "IOS", "build_id": build_id,
            "version": version(attrs(release).get("version")), "build_number": version(attrs(build).get("version"))}


def cloud_source(read, identity, repository):
    product = resource(read_page(read, f"/v1/apps/{identity['app_id']}/ciProduct",
                                {"fields[ciProducts]": "app,productType"}).get("data"), "ciProducts")
    require(attrs(product).get("productType") == "APP"
            and relation(product, "app", "apps")["id"] == identity["app_id"], "Xcode Cloud product belongs to the wrong app.")
    runs = collection(read, f"/v1/ciProducts/{product['id']}/buildRuns",
                      {"filter[builds]": identity["build_id"], "fields[ciBuildRuns]": RUN_FIELDS, "limit": 200}, "ciBuildRuns")
    require(len(runs) == 1, "Missing or ambiguous Xcode Cloud run; supply an explicit human-verified mapping.")
    run = runs[0]
    require(relation(run, "product", "ciProducts")["id"] == product["id"], "Xcode Cloud run product mismatch.")
    members = collection(read, f"/v1/ciBuildRuns/{run['id']}/relationships/builds", {"limit": 200}, "builds")
    require(identity["build_id"] in {b["id"] for b in members}, "Xcode Cloud run does not contain the selected build.")
    metadata = attrs(run)
    require(metadata.get("isPullRequestBuild") is False and metadata.get("destinationCommit") is None,
            "PR or merged-source provenance is unsupported; supply a human-verified mapping.")
    require(metadata.get("executionProgress") == "COMPLETE" and metadata.get("completionStatus") == "SUCCEEDED",
            "Xcode Cloud run must be complete and successful.")
    commit = metadata.get("sourceCommit")
    require(isinstance(commit, dict), "Missing Xcode Cloud source commit.")
    sha = revision(commit.get("commitSha"))
    ref_id = relation(run, "sourceBranchOrTag", "scmGitReferences")["id"]
    page = read_page(read, f"/v1/scmGitReferences/{ref_id}",
                     {"fields[scmGitReferences]": "repository", "include": "repository",
                      "fields[scmRepositories]": "httpCloneUrl"})
    ref = resource(page.get("data"), "scmGitReferences", ref_id)
    repo = included(page, relation(ref, "repository", "scmRepositories"), "scmRepositories")
    require(repository_url(attrs(repo).get("httpCloneUrl")) == repository, "Xcode Cloud source repository mismatch.")
    return {"kind": "xcode-cloud", "sha": sha, "repository": repository, "run_id": run["id"],
            "product_id": product["id"], "source_ref_id": ref_id, "repository_id": repo["id"]}


def resolve_build(read, selection, app_id, bundle_id, repository):
    require(isinstance(selection, dict), "Select an explicit baseline and candidate build; first releases need a baseline decision.")
    identity = build_identity(read, selection.get("build_id"), app_id, bundle_id)
    source = selection.get("source")
    require(isinstance(source, dict), "Choose Xcode Cloud or an explicit human-verified source mapping.")
    if source.get("kind") == "xcode-cloud":
        provenance = cloud_source(read, identity, repository)
    else:
        require(source.get("kind") == "human-verified", "Unknown source mapping method.")
        require(all(source.get(k) == v for k, v in identity.items()), "Human mapping does not match the exact Apple build identity.")
        require(repository_url(source.get("repository")) == repository, "Human mapping repository mismatch.")
        verified_at = text(source.get("verified_at"))
        try:
            require(datetime.fromisoformat(verified_at.replace("Z", "+00:00")).tzinfo is not None,
                    "Human verification date must include a timezone.")
        except ValueError:
            raise NotesError("Invalid human verification date.") from None
        provenance = {"kind": "human-verified", "sha": revision(source.get("sha")), "repository": repository,
                      "verified_by": text(source.get("verified_by"), 100), "verified_at": verified_at,
                      "evidence": text(source.get("evidence"))}
    return dict(identity, source=provenance)


class Git:
    def __init__(self, path, repository):
        self.path = str(Path(path).resolve())
        require(self.run("rev-parse", "--is-shallow-repository").strip() == b"false",
                "A complete, non-shallow checkout is required.")
        urls = self.run("config", "--get-all", "remote.origin.url").decode().splitlines()
        require(len(urls) == 1 and repository_url(urls[0]) == repository, "Checkout origin does not match the source repository.")
        require(not self.run("for-each-ref", "--format=%(refname)", "refs/replace/").strip(),
                "Git replacement objects are not supported.")
        grafts = self.run("rev-parse", "--git-path", "info/grafts").decode().strip()
        require(not (Path(self.path) / grafts).exists(), "Git grafts are not supported.")
        require(not self.run("config", "--get-regexp", r"^(extensions\.partialclone|remote\..*\.promisor)$", allowed=(0, 1)).strip(),
                "Partial clones are not supported; supply a complete offline checkout.")

    def run(self, *args, allowed=(0,)):
        env = {"PATH": os.defpath, "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
               "GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1"}
        try:
            with tempfile.TemporaryFile() as output:
                result = subprocess.run(["git", "--no-pager", "-c", "core.fsmonitor=false", "-C", self.path, *args],
                                        stdout=output, stderr=subprocess.DEVNULL, env=env, timeout=20)
                require(result.returncode in allowed, "Git verification failed; check full source revisions and repository history.")
                require(output.tell() <= MAX_BYTES, "Git output exceeds the safety bound.")
                output.seek(0)
                return output.read()
        except (OSError, subprocess.SubprocessError):
            raise NotesError("Local Git read failed or timed out; no release notes generated.") from None

    def changes(self, baseline, candidate):
        for sha in (baseline, candidate):
            require(self.run("cat-file", "-t", sha).strip() == b"commit", "Source SHA must identify an available commit.")
        self.run("merge-base", "--is-ancestor", baseline, candidate)
        objects = self.run("rev-list", "--objects", "--missing=print", baseline, candidate, "--")
        require(not any(line.startswith(b"?") for line in objects.splitlines()), "Source history contains unavailable objects.")
        commits = self.run("rev-list", "--reverse", "--topo-order", f"{baseline}..{candidate}", "--").decode().splitlines()
        require(len(commits) <= 1000, "Comparison exceeds 1000 commits; choose an explicit narrower baseline.")
        changes, excluded = {}, []
        for sha in commits:
            description = self.run("show", "--no-patch", "--format=%P%x00%s", sha, "--")
            parents, subject = description.split(b"\0", 1)
            # First-parent tree comparison counts merge resolutions but excludes
            # a notes-only merge even if its other parent lacks baseline changes.
            pair = [parents.decode().split()[0], sha] if parents else [sha]
            paths = set(self.run("diff-tree", "--root", "--no-commit-id", "--name-only", "-z", "-r", "-m",
                                 "--no-renames", *pair, "--").split(b"\0")) - {b""}
            if not paths or paths == {b"CHANGELOG.md"}:
                excluded.append({"sha": sha, "reason": "changelog-only" if paths else "empty"})
                continue
            subject = text(subject.decode("utf-8").strip(), 1000)
            prefix = re.match(r"^(feat|fix|perf|revert|build|chore|ci|docs|style|refactor|test)(?:\([^\r\n)]*\))?!?:\s*", subject, re.I)
            maintenance = prefix and prefix[1].lower() in {"build", "chore", "ci", "docs", "style", "refactor", "test"}
            category = "maintenance" if maintenance or subject.startswith("Merge ") else "product"
            cleaned = subject[prefix.end():] if prefix else subject
            # Only trailing (#123) tokens are treated as repository references.
            prs = []
            while match := re.search(r"\s+\(#([1-9][0-9]{0,9})\)$", cleaned):
                prs.append(int(match[1]))
                cleaned = cleaned[:match.start()].strip()
            cleaned = text(cleaned.strip(), 280)
            key = (category, " ".join(cleaned.casefold().split()))
            change = changes.setdefault(key, {"category": category, "subject": cleaned, "commits": [], "references": []})
            change["commits"].append(sha)
            change["references"] = sorted(set(change["references"] + prs))
        require(len(changes) <= 200, "Comparison exceeds 200 bullets; manual review is required.")
        return list(changes.values()), excluded


def markdown(value):
    escaped = re.sub(r"([\\`*_{}\[\]()#+.!|~-])", r"\\\1", value)
    return html.escape(escaped, quote=False).replace("@", "&#64;")


def render(payload):
    candidate, baseline, repo = payload["candidate"], payload["baseline"], payload["repository"]
    heading = f"Build {candidate['build_number']} — {candidate['build_id']}"
    lines = [f"#### {heading}", "", "Draft for human review (en-US).", ""]
    plain = [f"{candidate['version']} ({candidate['build_number']}) — changes for review"]
    for category, label in (("product", "Product changes"), ("maintenance", "Maintenance")):
        selected = [c for c in payload["changes"] if c["category"] == category]
        if not selected:
            continue
        lines.extend([f"**{label}**", ""])
        plain.extend(["", label])
        for change in selected:
            refs = [f"[{sha[:12]}]({repo}/commit/{sha})" for sha in change["commits"]]
            refs += [f"[#{pr}]({repo}/pull/{pr})" for pr in change["references"]]
            lines.append(f"- {markdown(change['subject'])} ({', '.join(refs)})")
            plain.append("- " + change["subject"] + "".join(f" (#{pr})" for pr in change["references"]))
        lines.append("")
    if not payload["changes"]:
        lines.extend(["No product or maintenance changes in this verified range.", ""])
        plain.extend(["", "No product or maintenance changes in this verified range."])
    lines.extend(["**Comparison and provenance**", "", f"- Entry: `{payload['entry_key']}`",
                  f"- App: `{candidate['app_id']}` / `{candidate['bundle_id']}`; platform: IOS; locale: en-US.",
                  f"- Baseline selection: {markdown(payload['baseline_reference'])}",
                  f"- [Included source range]({payload['comparison_url']})"])
    for label, build in (("Baseline", baseline), ("Candidate", candidate)):
        source = build["source"]
        lines.append(f"- {label}: {build['version']} ({build['build_number']}), build `{build['build_id']}`, "
                     f"source `{source['sha']}`, repository {repo}.")
        if source["kind"] == "xcode-cloud":
            lines.append(f"  - Xcode Cloud run `{source['run_id']}`, product `{source['product_id']}`, "
                         f"source ref `{source['source_ref_id']}`, repository `{source['repository_id']}`.")
        else:
            lines.append(f"  - Human verified by {markdown(source['verified_by'])} at {markdown(source['verified_at'])}: "
                         f"{markdown(source['evidence'])}")
    for excluded in payload["excluded_commits"]:
        lines.append(f"- Excluded {excluded['reason']}: `{excluded['sha']}`.")
    result = "\n".join(plain)
    require(len(result) <= 3500, "Plain-text notes exceed 3500 characters; review the range rather than silently truncate.")
    entry = "\n".join(lines) + "\n"
    require(len(entry.encode()) <= 128 * 1024, "Markdown entry exceeds the safety bound.")
    return entry, result


def generate(repo, request, read):
    """Generate one immutable draft entry; caller owns baseline selection/publishing."""
    require(isinstance(request, dict), "Expected a release-note request object.")
    require(request.get("channel") in ("beta", "app-store"), "Choose beta or app-store channel.")
    require(request.get("locale") == "en-US", "Only explicit en-US notes are supported.")
    require(request.get("baseline") is not None, "Missing baseline; first releases require an explicit human baseline decision.")
    app_id, bundle_id = identifier(request.get("app_id")), text(request.get("bundle_id"), 200)
    require(re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id), "Invalid bundle identifier.")
    repository = repository_url(request.get("repository"))
    baseline_reference = text(request.get("baseline_reference"))
    git = Git(repo, repository)
    baseline = resolve_build(read, request["baseline"], app_id, bundle_id, repository)
    candidate = resolve_build(read, request.get("candidate"), app_id, bundle_id, repository)
    require(baseline["build_id"] != candidate["build_id"] or baseline == candidate, "Conflicting provenance for one build.")
    start, end = baseline["source"]["sha"], candidate["source"]["sha"]
    changes, excluded = git.changes(start, end)
    key = f"{app_id}:IOS:{candidate['version']}:{request['channel']}:{candidate['build_id']}:en-US"
    payload = {"schema_version": 1, "status": "draft", "review_required": True, "target_path": "CHANGELOG.md",
               "channel": request["channel"], "locale": "en-US", "repository": repository, "entry_key": key,
               "version_heading": "## " + candidate["version"],
               "channel_heading": "### Beta" if request["channel"] == "beta" else "### App Store",
               "baseline_reference": baseline_reference, "baseline": baseline, "candidate": candidate,
               "comparison": f"{start}..{end}", "comparison_url": f"{repository}/compare/{start}...{end}",
               "changes": changes, "excluded_commits": excluded}
    payload["markdown_entry"], payload["plain_text"] = render(payload)
    payload["content_sha256"] = hashlib.sha256(json.dumps(payload, sort_keys=True, ensure_ascii=True).encode()).hexdigest()
    return payload


def load_json(path):
    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "Duplicate JSON keys are ambiguous; provide one explicit value.")
            result[key] = value
        return result

    with open(path, "rb") as source:
        raw = source.read(MAX_BYTES + 1)
    require(len(raw) <= MAX_BYTES, "JSON input exceeds the safety bound.")
    return json.loads(raw, object_pairs_hook=unique_keys)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--input", required=True, help="Explicit build selection and source-mapping JSON")
    parser.add_argument("--responses", required=True, help="Offline Apple GET response snapshot JSON; never a live API")
    args = parser.parse_args(argv)
    try:
        responses = load_json(args.responses)
        require(isinstance(responses, dict), "Expected a response snapshot object.")
        result = generate(args.repo, load_json(args.input), lambda path, query: responses[request_key(path, query)])
    except NotesError as error:
        result = {"status": "error", "action": str(error)}
    except (OSError, ValueError, UnicodeError, RecursionError):
        result = {"status": "error", "action": "Invalid local input or Git text; no release notes generated."}
    print(json.dumps(result, ensure_ascii=True, sort_keys=True))
    return 1 if result["status"] == "error" else 0


if __name__ == "__main__":
    sys.exit(main())
