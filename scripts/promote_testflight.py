#!/usr/bin/env python3
"""Append the newest processed, unexpired iOS internal Alpha build to internal Beta.

Default: read-only. --apply permits the frozen en-US notes operation, then ONE
additive group-build linkage. An existing handoff is reconciled, never resent.
Credentials (environment only): ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_PATH.
The key must be a private, regular .p8 file (0600), used by installed OpenSSL.
Optional ASC_SOURCE_GROUP_ID / ASC_DESTINATION_GROUP_ID disambiguate groups but
must still match this app, exact names Alpha / Beta, and internal group type.
Beta must report hasAccessToAllBuilds=false. Confirm automatic distribution is
off manually before activation; the API flag alone does not prove that setting.
No review submissions, notifications, tester edits, removals, expiry, or releases.
Exit 0: decision reported (including blocked/no candidate); 1: safe failure; 2: CLI.

Contracts checked against Apple's OpenAPI 4.5 on 2026-09-26:
https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip
https://developer.apple.com/documentation/appstoreconnectapi/internalbetastate
https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers
"""

import argparse
import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import release_notes
import testflight_notes

ORIGIN = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "dev.intentapp.ios"
READY = {"READY_FOR_BETA_TESTING", "IN_BETA_TESTING"}
BLOCKERS = {
    "MISSING_EXPORT_COMPLIANCE": "Complete export compliance manually in App Store Connect.",
    "IN_EXPORT_COMPLIANCE_REVIEW": "Wait for Apple's export compliance review.",
    "PROCESSING": "Wait for Apple to finish beta processing.",
    "PROCESSING_EXCEPTION": "Resolve the beta processing error in App Store Connect.",
    "EXPIRED": "This build expired; no older build was substituted.",
}
BUILD_FIELDS = "version,uploadedDate,expirationDate,expired,processingState,buildAudienceType,app,preReleaseVersion"
BUILD_QUERY = {
    "fields[builds]": BUILD_FIELDS,
    "include": "app,preReleaseVersion",
    "fields[apps]": "bundleId",
    "fields[preReleaseVersions]": "platform",
}


class PromotionError(Exception):
    """Only fixed, credential-free messages may cross the CLI boundary."""


class APIError(PromotionError):
    def __init__(self, status, write=False):
        self.status = status
        message = f"App Store Connect HTTP {status}. Check API access and metadata; no automatic write retry."
        if write:
            message += " Assignment may have succeeded; run a dry run to reconcile before applying again."
        super().__init__(message)


def resource_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9-]{1,100}", value):
        raise PromotionError("Missing or invalid resource ID; stopped safely.")
    return value


def resource(value, kind):
    if not isinstance(value, dict) or value.get("type") != kind:
        raise PromotionError("Missing or unexpected API resource type; stopped safely.")
    resource_id(value.get("id"))
    return value


def attributes(value):
    result = value.get("attributes")
    if not isinstance(result, dict):
        raise PromotionError("Missing API attributes; stopped safely.")
    return result


def date(value):
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if result.tzinfo is not None:
            return result
    except (ValueError, AttributeError, TypeError):
        pass
    raise PromotionError("Missing or invalid timezone-aware build date; stopped safely.")


def b64(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


class Credentials:
    def __init__(self):
        self.key_id = os.environ.get("ASC_KEY_ID", "")
        self.issuer = os.environ.get("ASC_ISSUER_ID", "")
        self.path = os.environ.get("ASC_PRIVATE_KEY_PATH", "")
        if not all((self.key_id, self.issuer, self.path)):
            raise PromotionError("Set ASC_KEY_ID, ASC_ISSUER_ID, and ASC_PRIVATE_KEY_PATH securely before running.")
        try:
            info = os.lstat(self.path)
            if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_uid != os.getuid():
                raise PromotionError("ASC_PRIVATE_KEY_PATH must be an owned regular file accessible only to its owner (0600).")
        except OSError:
            raise PromotionError("Cannot read ASC_PRIVATE_KEY_PATH; check the private key file.") from None

    def token(self, method, path):
        now = int(time.time())
        header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
        payload = {"iss": self.issuer, "iat": now, "exp": now + 120,
                   "aud": "appstoreconnect-v1", "scope": [f"{method} {path}"]}
        message = (b64(json.dumps(header).encode()) + "." + b64(json.dumps(payload).encode())).encode()
        try:
            signed = subprocess.run(
                ["openssl", "dgst", "-sha256", "-sign", self.path], input=message,
                capture_output=True, timeout=10, check=True,
            ).stdout
        except (OSError, subprocess.SubprocessError):
            raise PromotionError("OpenSSL could not sign the request; check the App Store Connect P-256 key and OpenSSL installation.") from None
        # OpenSSL emits DER ECDSA; ES256 JWT needs two unsigned 32-byte integers.
        try:
            if signed[0] != 0x30 or signed[1] != len(signed) - 2:
                raise ValueError
            offset, parts = 2, []
            for _ in range(2):
                if signed[offset] != 2:
                    raise ValueError
                length = signed[offset + 1]
                part = signed[offset + 2:offset + 2 + length]
                if not 1 <= length <= 33 or len(part) != length or part[0] & 0x80:
                    raise ValueError
                parts.append(int.from_bytes(part, "big").to_bytes(32, "big"))
                offset += 2 + length
            if offset != len(signed):
                raise ValueError
        except (IndexError, ValueError, OverflowError):
            raise PromotionError("OpenSSL returned an invalid ES256 signature; use an App Store Connect P-256 key.") from None
        return message.decode() + "." + b64(b"".join(parts))


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise PromotionError("API redirect refused to protect credentials.")


class Client:
    def __init__(self, credentials, apply=False):
        self.credentials = credentials
        self.apply = apply
        self.write_path = None
        self.write_body = None
        self.write_method = None
        self.write_status = None
        self.build_id = self.destination_id = self.note_plan = None
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirects())

    def request(self, path, query=None, body=None, method=None):
        method = method or ("GET" if body is None else "POST")
        if method != "GET" or body is not None:
            if (not self.apply or path != self.write_path or body != self.write_body
                    or method != self.write_method or query is not None or body is None):
                raise PromotionError("Write refused: only the exact frozen notes or Beta append operation is permitted.")
            expected_status = self.write_status
            # Consume approval before transport: even a timeout cannot reuse it.
            self.write_path = self.write_body = self.write_method = self.write_status = None
        url = ORIGIN + path if path.startswith("/v1/") else path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or parsed.netloc != "api.appstoreconnect.apple.com" or parsed.fragment:
            raise PromotionError("Untrusted API URL refused to protect credentials.")
        for attempt in range(3 if body is None else 1):
            token = self.credentials.token(method, parsed.path)
            req = urllib.request.Request(url, method=method,
                                         data=None if body is None else json.dumps(body).encode(),
                                         headers={"Authorization": "Bearer " + token, "Accept": "application/json",
                                                  "Content-Type": "application/json"})
            try:
                with self.opener.open(req, timeout=30) as response:
                    if body is not None:
                        if response.status != expected_status:
                            raise PromotionError("Unexpected write response; use the original handoff to reconcile without retrying.")
                        if expected_status == 204:
                            return None
                    elif response.status != 200:
                        raise PromotionError("Unexpected read response; stopped safely.")
                    raw = response.read(8 * 1024 * 1024 + 1)
                    if len(raw) > 8 * 1024 * 1024:
                        raise PromotionError("API response too large; stopped safely.")
                    result = json.loads(raw)
                    if not isinstance(result, dict):
                        raise ValueError
                    return result
            except urllib.error.HTTPError as error:
                status = error.code
                error.close()  # Never print Apple's error body, URL, or headers.
                if body is not None or status not in (429, 500, 502, 503, 504) or attempt == 2:
                    raise APIError(status, write=body is not None) from None
            except (urllib.error.URLError, TimeoutError, OSError):
                if body is not None or attempt == 2:
                    raise PromotionError("API connection failed. Assignment may be uncertain after apply; run a dry run before retrying.") from None
            except (ValueError, UnicodeError):
                raise PromotionError("Invalid API JSON response; stopped safely.") from None
            time.sleep(1 + attempt)

    def pages(self, path, query=None):
        seen = set()
        expected_path = path
        for _ in range(200):
            page = self.request(path, query)
            if not isinstance(page.get("data"), list):
                raise PromotionError("Missing API collection; stopped safely.")
            yield page
            links = page.get("links")
            if not isinstance(links, dict):
                raise PromotionError("Missing API pagination links; cannot prove selection is complete.")
            next_url = links.get("next")
            if next_url is None:
                return
            if not isinstance(next_url, str) or next_url in seen or urllib.parse.urlsplit(next_url).path != expected_path:
                raise PromotionError("Invalid or repeated pagination link; stopped safely.")
            seen.add(next_url)
            path, query = next_url, None
        raise PromotionError("Pagination limit exceeded; no partial selection was applied.")

    def collection(self, path, query=None):
        return [item for page in self.pages(path, query) for item in page["data"]]

    def approve_write(self, method, path, body, status):
        resource_id(self.build_id)
        resource_id(self.destination_id)
        append = ("POST", f"/v1/betaGroups/{self.destination_id}/relationships/builds",
                  {"data": [{"type": "builds", "id": self.build_id}]}, 204)
        allowed = [append]
        if self.note_plan:
            text = self.note_plan["desired_text"]
            identifier = self.note_plan["localization_id"]
            if identifier:
                resource_id(identifier)
                allowed.append(("PATCH", f"/v1/betaBuildLocalizations/{identifier}",
                                {"data": {"type": "betaBuildLocalizations", "id": identifier,
                                          "attributes": {"whatsNew": text}}}, 200))
            else:
                allowed.append(("POST", "/v1/betaBuildLocalizations",
                                {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": "en-US", "whatsNew": text},
                                          "relationships": {"build": {"data": {"type": "builds", "id": self.build_id}}}}}, 201))
        if (method, path, body, status) not in allowed:
            raise PromotionError("Write operation is outside the selected build notes and Beta append allowlist.")
        self.write_method, self.write_path = method, path
        self.write_body = json.loads(json.dumps(body))
        self.write_status = status


def unique(items, message):
    by_id = {}
    for item in items:
        key = resource_id(item.get("id"))
        if key in by_id and item != by_id[key]:
            raise PromotionError("API resources changed during pagination; rerun a dry run.")
        by_id[key] = item
    if len(by_id) != 1:
        raise PromotionError(message)
    return next(iter(by_id.values()))


def resolve(client):
    apps = client.collection("/v1/apps", {"filter[bundleId]": BUNDLE_ID, "fields[apps]": "bundleId", "limit": 200})
    app = unique([resource(a, "apps") for a in apps if attributes(a).get("bundleId") == BUNDLE_ID],
                 "Expected exactly one app for dev.intentapp.ios; check API access.")
    groups = client.collection(f"/v1/apps/{app['id']}/betaGroups",
                               {"fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds", "limit": 200})
    chosen = []
    for name, env in (("Alpha", "ASC_SOURCE_GROUP_ID"), ("Beta", "ASC_DESTINATION_GROUP_ID")):
        named = [resource(g, "betaGroups") for g in groups if attributes(g).get("name") == name]
        if any(type(attributes(g).get("isInternalGroup")) is not bool for g in named):
            raise PromotionError("Group has missing or invalid internal/external type; stopped safely.")
        pinned = os.environ.get(env)
        if pinned:
            resource_id(pinned)
        matches = [g for g in named if attributes(g)["isInternalGroup"] is True and (not pinned or g["id"] == pinned)]
        chosen.append(unique(matches, f"Cannot uniquely resolve internal {name} group; verify app, name, type, and {env}."))
    if chosen[0]["id"] == chosen[1]["id"]:
        raise PromotionError("Source Alpha and destination Beta must be different resources.")
    if attributes(chosen[1]).get("hasAccessToAllBuilds") is not False:
        raise PromotionError("Internal Beta all-build access must be explicitly false. Verify Beta settings manually; no settings were changed.")
    return app["id"], chosen[0]["id"], chosen[1]["id"]


def related(build, name, included, kind):
    relation = build.get("relationships", {}).get(name, {})
    if "data" not in relation:
        raise PromotionError("Missing build relationship metadata; stopped safely.")
    linkage = relation["data"]
    resource(linkage, kind)
    matches = [r for r in included if r.get("type") == kind and r.get("id") == linkage["id"]]
    return unique(matches, "Missing included build metadata; stopped safely.")


def candidate(build, included, app_id, now):
    resource(build, "builds")
    attrs = attributes(build)
    if attrs.get("processingState") not in ("VALID", "PROCESSING", "FAILED", "INVALID"):
        raise PromotionError("Missing or unknown processing state; stopped safely.")
    # Processing/failed uploads may not have pre-release platform metadata yet.
    if attrs["processingState"] != "VALID":
        return False
    app = related(build, "app", included, "apps")
    if app["id"] != app_id or attributes(app).get("bundleId") != BUNDLE_ID:
        raise PromotionError("Build belongs to an unexpected app; stopped safely.")
    platform = attributes(related(build, "preReleaseVersion", included, "preReleaseVersions")).get("platform")
    if platform not in ("IOS", "MAC_OS", "TV_OS", "VISION_OS"):
        raise PromotionError("Missing or unknown build platform; stopped safely.")
    if platform != "IOS":
        return False
    if type(attrs.get("expired")) is not bool:
        raise PromotionError("Missing build expiry flag; stopped safely.")
    if attrs["expired"] or date(attrs.get("expirationDate")) <= now:
        return False
    date(attrs.get("uploadedDate"))
    return True


def latest(client, app_id, source_id):
    query = dict(BUILD_QUERY, **{"filter[app]": app_id, "filter[betaGroups]": source_id, "limit": 200, "sort": "-uploadedDate"})
    builds = {}
    now = datetime.now(timezone.utc)
    for page in client.pages("/v1/builds", query):
        for build in page["data"]:
            if candidate(build, page.get("included", []), app_id, now):
                key = build["id"]
                if key in builds and builds[key] != build:
                    raise PromotionError("Build changed during pagination; rerun a dry run.")
                builds[key] = build
    return max(builds.values(), key=lambda b: (date(attributes(b)["uploadedDate"]), b["id"]), default=None)


def inspect(client, build_id, app_id):
    query = dict(BUILD_QUERY)
    query.update({"include": "app,preReleaseVersion,buildBetaDetail",
                  "fields[builds]": BUILD_FIELDS + ",buildBetaDetail",
                  "fields[buildBetaDetails]": "internalBuildState"})
    result = client.request(f"/v1/builds/{build_id}", query)
    build = resource(result.get("data"), "builds")
    if build["id"] != build_id:
        raise PromotionError("Unexpected selected build ID; stopped safely.")
    included = result.get("included", [])
    if not candidate(build, included, app_id, datetime.now(timezone.utc)):
        return "UNKNOWN", "Selected build is no longer processed, unexpired iOS; no older build was substituted."
    audience = attributes(build).get("buildAudienceType")
    if audience not in ("INTERNAL_ONLY", "APP_STORE_ELIGIBLE"):
        raise PromotionError("Missing or unknown build audience; cannot establish internal eligibility.")
    state = attributes(related(build, "buildBetaDetail", included, "buildBetaDetails")).get("internalBuildState")
    if state not in READY and state not in BLOCKERS:
        raise PromotionError("Missing or unknown internal beta state; inspect this build manually.")
    return state, BLOCKERS.get(state)


def assigned(client, destination_id, build_id):
    members = client.collection(f"/v1/betaGroups/{destination_id}/relationships/builds", {"limit": 200})
    return build_id in {resource(b, "builds")["id"] for b in members}


def promote(client, repo, handoff=None, sources=None, plan=None, select_only=False):
    app_id, source_id, destination_id = resolve(client)
    summary = {"mode": "apply" if client.apply else "dry-run", "app_id": app_id,
               "source_group_id": source_id, "destination_group_id": destination_id,
               "destination_has_access_to_all_builds": False}
    stored = testflight_notes.load(handoff, repo) if handoff and Path(handoff).exists() else None
    if stored is not None:
        summary["build_id"] = stored["payload"]["candidate"]["build_id"]
        testflight_notes.match(stored, summary)
        summary["internal_state"], _ = inspect(client, summary["build_id"], app_id)
        return testflight_notes.reconcile(client, stored, summary, handoff, assigned)
    build = latest(client, app_id, source_id)
    if build is None:
        return dict(summary, result="no_candidate", action="No fully processed, nonexpired iOS build in internal Alpha.")
    build_id = build["id"]
    client.build_id, client.destination_id = build_id, destination_id
    summary.update(build_id=build_id, uploaded_date=date(attributes(build)["uploadedDate"]).isoformat())
    # Read membership before checking current eligibility, minimizing stale state before a write.
    is_assigned = assigned(client, destination_id, build_id)
    state, blocker = inspect(client, build_id, app_id)
    summary.update(internal_state=state, assigned=is_assigned)
    if blocker:
        return dict(summary, result="blocked", action=blocker)
    if select_only:
        return dict(summary, result="selected", action="Selection only; no notes or assignment writes.")
    if is_assigned:
        summary.update(notes_status="not_managed", assignment_status="confirmed", publication_status="not_requested")
    else:
        if plan:
            frozen = testflight_notes.load(plan, repo)
            testflight_notes.match(frozen, summary)
            if frozen["notes_status"] != "planned" or frozen["assignment_status"] != "not_attempted":
                raise PromotionError("This handoff records attempted writes; pass it as --handoff for read-only reconciliation, not --plan.")
        else:
            frozen = testflight_notes.prepare(client, repo, build, summary, sources or {}, BUILD_QUERY)
        client.note_plan = frozen["metadata"]
        summary.update(payload=frozen["payload"], metadata_operation=frozen["metadata"]["operation"],
                       notes_status="planned", assignment_status="not_attempted", publication_status="not_requested")
        if handoff:
            testflight_notes.save_new(handoff, frozen)
        if not client.apply:
            return dict(summary, result="would_assign", action="Would verify en-US notes, then append to internal Beta. No remote writes; tester availability is not confirmed.")
        if not handoff:
            raise PromotionError("Apply requires a new durable --handoff path; never discard it when retrying.")
        # Membership and all original eligibility guards are checked again after
        # generation, before any metadata write. Never reselect an older build.
        testflight_notes.check_members(client, frozen)
        state, blocker = inspect(client, build_id, app_id)
        if blocker:
            return dict(summary, result="blocked", action=blocker)
        testflight_notes.write_notes(client, frozen, handoff)
        summary["notes_status"] = "verified"
        testflight_notes.check_members(client, frozen)
        state, blocker = inspect(client, build_id, app_id)
        if blocker:
            return dict(summary, result="blocked", action=blocker)
    if not is_assigned:
        path = f"/v1/betaGroups/{destination_id}/relationships/builds"
        body = {"data": [{"type": "builds", "id": build_id}]}
        frozen["assignment_status"] = "uncertain"
        testflight_notes.save(handoff, frozen)
        client.approve_write("POST", path, body, 204)
        try:
            client.request(path, body=body)
        except APIError as error:
            # A concurrent assignment can yield 409. Reconcile, never resend the write.
            if error.status != 409 or not assigned(client, destination_id, build_id):
                raise
        if not assigned(client, destination_id, build_id):
            raise PromotionError("Assignment not yet visible. No write retry; run a dry run to reconcile.")
        frozen["assignment_status"] = "confirmed"
        testflight_notes.save(handoff, frozen)
        summary["assignment_status"] = "confirmed"
        state, blocker = inspect(client, build_id, app_id)
        summary.update(internal_state=state, assigned=True)
        if blocker:
            return dict(summary, result="assigned_but_blocked", action=blocker)
    if state == "IN_BETA_TESTING":
        return dict(summary, result="already_assigned" if is_assigned else "assigned",
                    action="Internal Beta assignment is confirmed and Apple reports internal testing. This does not confirm each tester's access or installation. No notification was sent by this script.")
    return dict(summary, result="assigned_pending_testing",
                action="Assignment exists, but internal testing is not confirmed. Inspect Internal Testing > Beta, build compliance, What to Test, and tester access in App Store Connect. No notification was sent by this script.")


class SafeParser(argparse.ArgumentParser):
    def error(self, message):
        # Do not echo accidental credential arguments.
        self.print_usage(sys.stderr)
        self.exit(2, "Invalid arguments. Use --help; credentials belong only in the environment/private key file.\n")


def main(argv=None):
    parser = SafeParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--apply", action="store_true", help="append one eligible build to internal Beta")
    modes.add_argument("--dry-run", action="store_true", help="read-only (the default)")
    parser.add_argument("--repo", default=".", help="Complete source checkout; only Git data is read")
    parser.add_argument("--handoff", help="New local journal, or original journal to reconcile without writes")
    parser.add_argument("--plan", help="Frozen preview handoff; only a fresh journal may apply it")
    parser.add_argument("--sources", help="Reviewed JSON object mapping exact build IDs to source attestations")
    parser.add_argument("--select-only", action="store_true", help="Read-only candidate identity for workflow artifact lookup")
    args = parser.parse_args(argv)
    try:
        if args.select_only and (args.apply or args.plan or args.handoff):
            raise PromotionError("Selection must be read-only and separate from a handoff.")
        sources = release_notes.load_json(args.sources) if args.sources else None
        result = promote(Client(Credentials(), apply=args.apply), args.repo, args.handoff, sources, args.plan, args.select_only)
    except (PromotionError, release_notes.NotesError) as error:
        print(json.dumps({"result": "error", "action": str(error)}))
        return 1
    except Exception:
        # No tracebacks: network/parsing/signing exceptions can contain credentials.
        print(json.dumps({"result": "error", "action": "Unexpected failure; stopped safely. Run a dry run to reconcile before applying again."}))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())