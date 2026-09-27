"""Beta-only notes ownership and durable, nonsecret publisher handoff.

Handoff v1 is a reviewed input, not a signed receipt. Never supply untrusted files.
The payload and metadata plan are immutable; only independent observation states
change. Existing journals/recovered artifacts reconcile READ ONLY, even in apply.
If a write is uncertain and absent, a human must repair it; no automatic resend.
Workflow uploads the prepared intent BEFORE enabling writes, then the journal even
on failure. Neither file contains credentials or arbitrary Apple response bodies.
Apple OpenAPI 4.5 (2026-09-27): localization POST -> 201, PATCH -> 200.
"""

from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import tempfile

import release_notes as notes

REPOSITORY = "https://github.com/intent-hq/ios"
MARKER = "[Intent Beta notes"
END = "[/Intent Beta notes]"
LOCALE_QUERY = {"fields[betaBuildLocalizations]": "locale,whatsNew,build", "limit": 200}


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=True).encode()).hexdigest()


def keys(value, expected):
    notes.require(isinstance(value, dict) and set(value) == set(expected.split()),
                  "Invalid handoff fields; retain the original validated artifact.")


def timestamp(value):
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        notes.require(parsed.tzinfo is not None, "Build dates must include a timezone.")
        return parsed
    except (ValueError, AttributeError):
        raise notes.NotesError("Missing historical build date; cannot select a Beta baseline.") from None


def members(client, group):
    return sorted({notes.resource(b, "builds")["id"] for b in
                   client.collection(f"/v1/betaGroups/{group}/relationships/builds", {"limit": 200})})


def check_members(client, frozen):
    notes.require(members(client, frozen["destination_group_id"]) == frozen["beta_members"],
                  "Beta membership changed after planning; retain this handoff and reconcile without writes.")


def localization(client, build_id):
    rows = notes.collection(client.request, f"/v1/builds/{build_id}/betaBuildLocalizations",
                            LOCALE_QUERY, "betaBuildLocalizations")
    english = []
    for row in rows:
        meta = notes.attrs(row)
        notes.text(meta.get("locale"), 100)
        notes.require(notes.relation(row, "build", "builds")["id"] == build_id,
                      "Localization belongs to a different build.")
        if meta["locale"] == "en-US":
            value = meta.get("whatsNew")
            notes.require(value is None or isinstance(value, str), "Invalid What to Test text.")
            english.append({"id": row["id"], "text": value})
    notes.require(len(english) <= 1, "Multiple en-US localizations; resolve ownership manually.")
    return english[0] if english else None


def metadata_plan(payload, existing):
    original = existing["text"] if existing else None
    human = original or ""
    notes.require(MARKER not in human and END not in human,
                  "Generated notes already exist or ownership is ambiguous; recover the original handoff, never overwrite.")
    block = f"{MARKER} v1 {payload['content_sha256']}]\n{payload['plain_text']}\n{END}"
    desired = human + ("\n\n" if human else "") + block
    # 4000 is the What to Test limit; count UTF-16 too, conservatively. Never
    # truncate generated or human text to make a write fit.
    notes.require(len(desired.encode("utf-16-le")) // 2 <= 4000,
                  "Combined handwritten and generated notes exceed 4000 characters; review manually, no truncation.")
    return {"operation": "update" if existing else "create", "localization_id": existing["id"] if existing else None,
            "original_text": original, "desired_text": desired}


def prepare(client, repo, candidate, summary, sources, build_query):
    notes.require(isinstance(sources, dict), "Source mappings must be an object keyed by exact build IDs.")
    for build_id in sources:
        notes.identifier(build_id)
    app, group, selected = summary["app_id"], summary["destination_group_id"], candidate["id"]
    prior_members = members(client, group)
    notes.require(selected not in prior_members, "Candidate was concurrently assigned; no retroactive notes write.")
    choices = []
    for build_id in prior_members:
        page = client.request(f"/v1/builds/{build_id}", build_query)
        build = notes.resource(page.get("data"), "builds", build_id)
        owner = notes.included(page, notes.relation(build, "app", "apps"), "apps")
        notes.require(owner["id"] == app and notes.attrs(owner).get("bundleId") == "dev.intentapp.ios",
                      "Historical Beta build belongs to the wrong app.")
        release = notes.included(page, notes.relation(build, "preReleaseVersion", "preReleaseVersions"), "preReleaseVersions")
        platform = notes.attrs(release).get("platform")
        notes.require(platform in ("IOS", "MAC_OS", "TV_OS", "VISION_OS"), "Unknown historical Beta platform.")
        if platform != "IOS":
            continue
        uploaded = timestamp(notes.attrs(build).get("uploadedDate"))
        notes.require(uploaded < timestamp(notes.attrs(candidate).get("uploadedDate")),
                      "Beta contains an equally new or newer iOS build; refuse an ambiguous baseline or rollback.")
        choices.append((uploaded, build_id))
    notes.require(bool(choices), "No prior iOS Beta baseline; first promotion requires an explicit human baseline decision.")
    choices.sort(reverse=True)
    notes.require(len(choices) == 1 or choices[0][0] != choices[1][0], "Prior Beta upload dates tie; baseline needs human review.")
    baseline = choices[0][1]
    request = {"app_id": app, "bundle_id": "dev.intentapp.ios", "repository": REPOSITORY,
               "channel": "beta", "locale": "en-US",
               "baseline_reference": f"Newest strictly earlier iOS upload in internal Beta {group}; expired history allowed; membership verified before writes.",
               "baseline": {"build_id": baseline, "source": sources.get(baseline, {"kind": "xcode-cloud"})},
               "candidate": {"build_id": selected, "source": sources.get(selected, {"kind": "xcode-cloud"})}}
    payload = notes.generate(repo, request, client.request)
    frozen = {"schema_version": 1, "payload": payload, "source_group_id": summary["source_group_id"],
              "destination_group_id": group, "beta_members": prior_members,
              "metadata": metadata_plan(payload, localization(client, selected)),
              "notes_status": "planned", "assignment_status": "not_attempted", "publication_status": "not_requested"}
    frozen["plan_sha256"] = digest(immutable(frozen))
    return frozen


def immutable(frozen):
    return {k: v for k, v in frozen.items() if k not in
            ("plan_sha256", "notes_status", "assignment_status", "publication_status")}


def validate_payload(repo, payload):
    keys(payload, "schema_version status review_required target_path channel locale repository entry_key version_heading channel_heading baseline_reference baseline candidate comparison comparison_url changes excluded_commits markdown_entry plain_text content_sha256")
    notes.require(payload["schema_version"] == 1 and payload["status"] == "draft" and payload["review_required"] is True
                  and payload["target_path"] == "CHANGELOG.md" and payload["channel"] == "beta"
                  and payload["locale"] == "en-US" and payload["repository"] == REPOSITORY,
                  "Handoff is not an en-US iOS Beta draft for this repository.")
    notes.require(payload["content_sha256"] == digest({k: v for k, v in payload.items() if k != "content_sha256"}),
                  "Frozen release-note payload changed; recover the original artifact.")
    notes.text(payload["baseline_reference"])
    for build in (payload["baseline"], payload["candidate"]):
        keys(build, "app_id bundle_id platform build_id version build_number source")
        notes.identifier(build["app_id"])
        notes.identifier(build["build_id"])
        notes.version(build["version"])
        notes.version(build["build_number"])
        notes.require(build["bundle_id"] == "dev.intentapp.ios" and build["platform"] == "IOS", "Wrong frozen build identity.")
        source = build["source"]
        notes.require(isinstance(source, dict), "Missing frozen source provenance.")
        if source.get("kind") == "xcode-cloud":
            keys(source, "kind sha repository run_id product_id source_ref_id repository_id")
            for field in ("run_id", "product_id", "source_ref_id", "repository_id"):
                notes.identifier(source[field])
        else:
            keys(source, "kind sha repository verified_by verified_at evidence")
            notes.require(source["kind"] == "human-verified", "Unknown frozen source provenance.")
            notes.text(source["verified_by"], 100)
            notes.text(source["evidence"])
            timestamp(source["verified_at"])
        notes.revision(source["sha"])
        notes.require(source["repository"] == REPOSITORY, "Wrong frozen source repository.")
    baseline, candidate = payload["baseline"], payload["candidate"]
    notes.require(baseline["app_id"] == candidate["app_id"] and baseline["build_id"] != candidate["build_id"],
                  "Invalid frozen Beta baseline.")
    start, end = baseline["source"]["sha"], candidate["source"]["sha"]
    changes, excluded = notes.Git(repo, REPOSITORY).changes(start, end)
    notes.require(payload["changes"] == changes and payload["excluded_commits"] == excluded,
                  "Frozen changes do not match the exact source range.")
    notes.require(payload["entry_key"] == f"{candidate['app_id']}:IOS:{candidate['version']}:beta:{candidate['build_id']}:en-US"
                  and payload["version_heading"] == "## " + candidate["version"] and payload["channel_heading"] == "### Beta"
                  and payload["comparison"] == f"{start}..{end}"
                  and payload["comparison_url"] == f"{REPOSITORY}/compare/{start}...{end}", "Invalid frozen entry references.")
    markdown, plain = notes.render(payload)
    notes.require(payload["markdown_entry"] == markdown and payload["plain_text"] == plain, "Frozen rendered notes changed.")


def load(path, repo):
    frozen = notes.load_json(path)
    keys(frozen, "schema_version payload source_group_id destination_group_id beta_members metadata notes_status assignment_status publication_status plan_sha256")
    notes.require(frozen["schema_version"] == 1 and frozen["plan_sha256"] == digest(immutable(frozen)),
                  "Frozen handoff changed; retain the original artifact.")
    validate_payload(repo, frozen["payload"])
    for field in ("source_group_id", "destination_group_id"):
        notes.identifier(frozen[field])
    notes.require(frozen["source_group_id"] != frozen["destination_group_id"], "Invalid frozen groups.")
    group_members = frozen["beta_members"]
    notes.require(isinstance(group_members, list) and 0 < len(group_members) <= 1000,
                  "Missing or excessive frozen Beta membership.")
    for build_id in group_members:
        notes.identifier(build_id)
    notes.require(group_members == sorted(set(group_members)) and frozen["payload"]["baseline"]["build_id"] in group_members
                  and frozen["payload"]["candidate"]["build_id"] not in group_members, "Invalid frozen baseline membership.")
    meta = frozen["metadata"]
    keys(meta, "operation localization_id original_text desired_text")
    if meta["localization_id"] is not None:
        notes.identifier(meta["localization_id"])
    notes.require(meta["original_text"] is None or isinstance(meta["original_text"], str), "Invalid original notes.")
    existing = {"id": meta["localization_id"], "text": meta["original_text"]} if meta["localization_id"] else None
    notes.require(meta == metadata_plan(frozen["payload"], existing), "Frozen metadata operation changed.")
    notes.require(frozen["notes_status"] in ("planned", "uncertain", "verified", "drifted")
                  and frozen["assignment_status"] in ("not_attempted", "uncertain", "confirmed")
                  and frozen["publication_status"] == "not_requested", "Invalid independent handoff states.")
    return frozen


def save_new(path, frozen):
    # Exclusive creation prevents concurrent local processes from both applying.
    with open(path, "x", encoding="utf-8") as output:
        json.dump(frozen, output, sort_keys=True, ensure_ascii=True)
        output.flush()
        os.fsync(output.fileno())
    sync_directory(path)


def sync_directory(path):
    descriptor = os.open(str(Path(path).parent), os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def save(path, frozen):
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=Path(path).parent, delete=False) as output:
        json.dump(frozen, output, sort_keys=True, ensure_ascii=True)
        output.flush()
        os.fsync(output.fileno())
    os.replace(output.name, path)
    sync_directory(path)


def match(frozen, summary):
    build = frozen["payload"]["candidate"]
    notes.require(build["app_id"] == summary["app_id"] and build["build_id"] == summary["build_id"]
                  and all(frozen[k] == summary[k] for k in ("source_group_id", "destination_group_id")),
                  "Frozen handoff does not match the selected app, groups or build; never retarget it.")


def write_notes(client, frozen, path):
    build_id, meta = frozen["payload"]["candidate"]["build_id"], frozen["metadata"]
    current = localization(client, build_id)
    expected = {"id": meta["localization_id"], "text": meta["original_text"]} if meta["localization_id"] else None
    notes.require(current == expected, "What to Test changed after preview; preserve edits and reconcile manually.")
    data = {"type": "betaBuildLocalizations", "attributes": {"whatsNew": meta["desired_text"]}}
    if current is None:
        method, endpoint, status = "POST", "/v1/betaBuildLocalizations", 201
        data["attributes"]["locale"] = "en-US"
        data["relationships"] = {"build": {"data": {"type": "builds", "id": build_id}}}
    else:
        method, endpoint, status = "PATCH", f"/v1/betaBuildLocalizations/{current['id']}", 200
        data["id"] = current["id"]
    frozen["notes_status"] = "uncertain"
    save(path, frozen)
    client.approve_write(method, endpoint, {"data": data}, status)
    response = client.request(endpoint, body={"data": data}, method=method)
    row = notes.resource(response.get("data"), "betaBuildLocalizations", current["id"] if current else None)
    notes.require(notes.attrs(row).get("locale") == "en-US" and notes.attrs(row).get("whatsNew") == meta["desired_text"],
                  "Unexpected localization write response; retain the handoff and reconcile, no assignment.")
    verified = localization(client, build_id)
    notes.require(verified == {"id": row["id"], "text": meta["desired_text"]},
                  "Notes were not verified after write; no assignment or write retry.")
    frozen["notes_status"] = "verified"
    save(path, frozen)


def reconcile(client, frozen, summary, path, assigned):
    match(frozen, summary)
    current = localization(client, summary["build_id"])
    frozen["notes_status"] = "verified" if current and current["text"] == frozen["metadata"]["desired_text"] else "drifted"
    confirmed = assigned(client, summary["destination_group_id"], summary["build_id"])
    # Absence does not prove a previous request failed: retain uncertainty.
    frozen["assignment_status"] = "confirmed" if confirmed else "uncertain"
    save(path, frozen)
    complete = frozen["notes_status"] == "verified" and confirmed
    state = summary.get("internal_state")
    result = "recovery_required"
    if complete:
        result = "already_assigned" if state == "IN_BETA_TESTING" else (
            "assigned_pending_testing" if state == "READY_FOR_BETA_TESTING" else "assigned_but_blocked")
    return dict(summary, result=result,
                action="Original payload retained; read-only reconciliation only. No writes retried. " +
                ("Notes and membership are verified; inspect Internal Testing > Beta and tester access manually." if complete else
                 "A human must reconcile missing or changed notes/assignment before a separately approved repair."),
                payload=frozen["payload"], notes_status=frozen["notes_status"], assignment_status=frozen["assignment_status"],
                publication_status="not_requested")