#!/usr/bin/env python3
"""Read-only public draft generation for an explicitly selected iOS build.

Apple OpenAPI 4.5 (2026-09-27), checksum/source in release_notes.py:
appStoreVersions has NO sort or actual release-date field. createdDate and
earliestReleaseDate are not release timestamps. Never sort by them or uploads.
The unique current READY_FOR_DISTRIBUTION APP_STORE iOS version identifies the
current release, but that state alone also covers preorders. Require downloadable
and an AVAILABLE territory (not available=true, which is merely configuration).
No current/ambiguous/preorder/removed-only history fails closed; no older fallback.
Apple Help: reference/app-information/app-and-submission-statuses/ and
manage-your-apps-availability/publish-for-pre-order/ under help/app-store-connect/.
This conservatively supports a currently available release, not historical
reconstruction of removed apps. There are no Apple writes in this entry point.
"""

import argparse
import json
import sys

import release_notes as notes
import testflight_notes
from promote_testflight import BUNDLE_ID, Client, Credentials

VERSION_QUERY = {"filter[platform]": "IOS", "fields[appStoreVersions]":
                 "platform,versionString,appVersionState,reviewType,downloadable,app,build", "limit": 200}
AVAILABILITY_QUERY = {"fields[territoryAvailabilities]": "contentStatuses", "limit": 200}
STATES = {"ACCEPTED", "DEVELOPER_REJECTED", "IN_REVIEW", "INVALID_BINARY", "METADATA_REJECTED",
          "PENDING_APPLE_RELEASE", "PENDING_DEVELOPER_RELEASE", "PREPARE_FOR_SUBMISSION",
          "PROCESSING_FOR_DISTRIBUTION", "READY_FOR_DISTRIBUTION", "READY_FOR_REVIEW", "REJECTED",
          "REPLACED_WITH_NEW_VERSION", "WAITING_FOR_EXPORT_COMPLIANCE", "WAITING_FOR_REVIEW"}


def baseline(read, app_id):
    versions = notes.collection(read, f"/v1/apps/{app_id}/appStoreVersions", VERSION_QUERY, "appStoreVersions")
    current = []
    for row in versions:
        meta = notes.attrs(row)
        notes.require(meta.get("platform") == "IOS" and notes.relation(row, "app", "apps")["id"] == app_id,
                      "Unexpected app or platform in public version history.")
        notes.require(meta.get("appVersionState") in STATES and meta.get("reviewType") in ("APP_STORE", "NOTARIZATION"),
                      "Unknown public version state or distribution method.")
        if meta["reviewType"] == "APP_STORE" and meta["appVersionState"] == "READY_FOR_DISTRIBUTION":
            current.append(row)
    notes.require(len(current) == 1, "No unique current iOS App Store release; first or ambiguous baselines require human review.")
    row = current[0]
    notes.require(notes.attrs(row).get("downloadable") is True, "Current version is not downloadable; no released baseline proven.")
    availability = notes.resource(notes.read_page(read, f"/v1/apps/{app_id}/appAvailabilityV2").get("data"), "appAvailabilities")
    # Client accepts absolute same-origin v2 URLs; collection also validates every
    # next link against the original endpoint, so use its path-aware adapter.
    territories = notes.collection(read, f"/v2/appAvailabilities/{availability['id']}/territoryAvailabilities",
                                   AVAILABILITY_QUERY, "territoryAvailabilities")
    available = []
    for territory in territories:
        statuses = notes.attrs(territory).get("contentStatuses")
        notes.require(isinstance(statuses, list) and all(isinstance(s, str) for s in statuses), "Missing App Store availability evidence.")
        if statuses == ["AVAILABLE"]:
            available.append(territory["id"])
    notes.require(bool(available), "App Store has no proven AVAILABLE territory; preorders and removed apps need human review.")
    return {"version_id": row["id"], "version": notes.version(notes.attrs(row).get("versionString")),
            "build_id": notes.relation(row, "build", "builds")["id"], "available_territories": sorted(available)}


def generate(repo, candidate, sources, read):
    notes.identifier(candidate)
    notes.require(isinstance(sources, dict), "Source mappings must be keyed by exact build IDs.")
    for key in sources:
        notes.identifier(key)
    apps = notes.collection(read, "/v1/apps", {"filter[bundleId]": BUNDLE_ID, "fields[apps]": "bundleId", "limit": 200}, "apps")
    notes.require(len(apps) == 1 and notes.attrs(apps[0]).get("bundleId") == BUNDLE_ID, "Cannot resolve the exact public app.")
    app = apps[0]["id"]
    selected = baseline(read, app)
    notes.require(selected["build_id"] != candidate, "Candidate is already the current App Store build; choose an explicit unreleased candidate.")
    request = {"app_id": app, "bundle_id": BUNDLE_ID, "repository": testflight_notes.REPOSITORY,
               "channel": "app-store", "locale": "en-US",
               "baseline_reference": f"Unique current IOS APP_STORE version {selected['version_id']}; READY_FOR_DISTRIBUTION, downloadable, AVAILABLE territory verified; no date ordering.",
               "baseline": {"build_id": selected["build_id"], "source": sources.get(selected["build_id"], {"kind": "xcode-cloud"})},
               "candidate": {"build_id": candidate, "source": sources.get(candidate, {"kind": "xcode-cloud"})}}
    payload = notes.generate(repo, request, read)
    notes.require(payload["baseline"]["version"] == selected["version"], "Released version/build relationship disagrees with build identity.")
    notes.require(selected == baseline(read, app), "Public baseline changed during generation; no draft retained.")
    return {"schema_version": 1, "payload": payload}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--sources")
    args = parser.parse_args(argv)
    try:
        client = Client(Credentials(), apply=False)
        def read(path, query=None):
            return client.request("https://api.appstoreconnect.apple.com" + path if path.startswith("/v2/") else path, query)
        frozen = generate(".", args.candidate, notes.load_json(args.sources) if args.sources else {}, read)
        testflight_notes.save_new(args.output, frozen)
        print(json.dumps(frozen["payload"], ensure_ascii=True))
        return 0
    except Exception:
        print(json.dumps({"status": "error", "action": "Public draft failed safely; verify current released baseline, candidate and source mappings. No Apple writes occurred."}))
        return 1


if __name__ == "__main__":
    sys.exit(main())