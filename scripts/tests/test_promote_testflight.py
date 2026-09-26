"""Offline behavioral/API-contract tests; no ASC connections or credentials."""

import base64
from contextlib import redirect_stdout, redirect_stderr
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import urllib.parse

SCRIPT = Path(__file__).resolve().parents[1] / "promote_testflight.py"
spec = importlib.util.spec_from_file_location("promotion", SCRIPT)
promotion = importlib.util.module_from_spec(spec)
spec.loader.exec_module(promotion)
FIXTURE = json.loads((Path(__file__).parent / "fixtures/testflight_api.json").read_text())


class Response(io.BytesIO):
    def __init__(self, value, status=200):
        super().__init__(value if isinstance(value, bytes) else json.dumps(value).encode())
        self.status = status


class FixtureAPI:
    """Only the documented reads and append endpoint exist in this offline server."""

    def __init__(self, case):
        self.case = case
        self.data = copy.deepcopy(FIXTURE)
        self.calls = []
        self.page_size = 200
        self.failures = []
        self.post_status = 204
        self.post_persists = True
        self.next_override = None
        self.on_detail = None
        self.on_post = None
        self.contract_errors = []

    @property
    def writes(self):
        return [c for c in self.calls if c[0] != "GET"]

    def open(self, req, timeout):
        try:
            return self.respond(req, timeout)
        except AssertionError as error:
            self.contract_errors.append(str(error))
            raise

    def respond(self, req, timeout):
        url = urllib.parse.urlsplit(req.full_url)
        query = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        method = req.get_method()
        body = json.loads(req.data) if req.data else None
        self.calls.append((method, url.path, query, body))
        self.case.assertEqual(url.netloc, "api.appstoreconnect.apple.com")
        self.case.assertEqual(timeout, 30)
        self.case.assertTrue(req.get_header("Authorization").startswith("Bearer "))
        if self.failures:
            failure = self.failures.pop(0)
            if isinstance(failure, Exception):
                raise failure
            return failure
        detail = url.path.startswith("/v1/builds/")
        contract = self.data["query_contracts"].get("/v1/builds/{id}" if detail else url.path)
        self.case.assertIsNotNone(contract, "Undocumented or forbidden endpoint was called")
        for key, value in query.items():
            if key == "cursor":
                continue
            self.case.assertIn(key, contract)
            if contract[key] is not None:
                self.case.assertTrue(set(value.split(",")).issubset(contract[key]))
        if method == "POST":
            self.case.assertEqual(url.path, "/v1/betaGroups/102/relationships/builds")
            self.case.assertEqual(body, self.data["assignment_request"])
            if self.post_persists:
                self.data["destination_members"].extend(copy.deepcopy(body["data"]))
            if self.on_post:
                self.on_post()
            if self.post_status != 204:
                raise urllib.error.HTTPError(req.full_url, self.post_status, "private response", {}, io.BytesIO(b"private body"))
            return Response(None, self.data["assignment_response_status"])
        self.case.assertEqual(method, "GET")
        if url.path == "/v1/apps":
            if "cursor" not in query:
                self.case.assertEqual(query.get("filter[bundleId]"), "dev.intentapp.ios")
            items = self.data["apps"]
        elif url.path == "/v1/apps/100/betaGroups":
            items = self.data["groups"]
        elif url.path == "/v1/builds":
            if "cursor" not in query:
                self.case.assertEqual(query.get("filter[app]"), "100")
                self.case.assertEqual(query.get("filter[betaGroups]"), "101")
            items = self.data["builds"]
        elif detail:
            if self.on_detail:
                self.on_detail()
            build = next(b for b in self.data["builds"] if b["id"] == url.path.rsplit("/", 1)[1])
            return Response({"data": build, "included": self.data["included"]})
        else:
            items = self.data["destination_members"]
        cursor = int(query.get("cursor", "0"))
        end = cursor + self.page_size
        next_url = f"https://api.appstoreconnect.apple.com{url.path}?cursor={end}" if end < len(items) else None
        if self.next_override:
            next_url = self.next_override
        return Response({"data": items[cursor:end], "links": {"next": next_url}, "included": self.data["included"]})


class PromotionTests(unittest.TestCase):
    def setUp(self):
        self.api = FixtureAPI(self)
        self.env = patch.dict(os.environ, {}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        # Even an accidentally unmocked transport cannot contact a live API.
        network = patch.object(socket, "create_connection", side_effect=AssertionError("Offline tests forbid network"))
        network.start()
        self.addCleanup(network.stop)

    def run_cli(self, apply=False):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(promotion, "Credentials") as credentials, \
                patch.object(promotion.urllib.request, "build_opener", return_value=self.api), \
                patch.object(promotion.time, "sleep"), redirect_stdout(stdout), redirect_stderr(stderr):
            credentials.return_value.token.return_value = "synthetic-test-token"
            status = promotion.main(["--apply"] if apply else [])
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(self.api.contract_errors, [], "Negative test failed for an unrelated API-contract reason")
        return status, json.loads(stdout.getvalue())

    def clone_build(self, identifier, **attrs):
        build = copy.deepcopy(self.api.data["builds"][0])
        build["id"] = identifier
        build["attributes"].update(attrs)
        self.api.data["builds"].append(build)
        return build

    def set_state(self, state):
        self.api.data["included"][2]["attributes"]["internalBuildState"] = state

    def test_default_is_read_only_and_resolves_exact_group_types(self):
        # Legacy pins must not silently redirect the revised source/destination.
        with patch.dict(os.environ, {"ASC_INTERNAL_GROUP_ID": "104", "ASC_EXTERNAL_GROUP_ID": "103"}):
            status, result = self.run_cli()
        self.assertEqual(status, 0)
        self.assertEqual(result["result"], "would_assign")
        self.assertEqual((result["source_group_id"], result["destination_group_id"]), ("101", "102"))
        self.assertIs(result["destination_has_access_to_all_builds"], False)
        self.assertFalse(self.api.writes)

    def test_apply_appends_only_selected_build_and_second_run_is_noop(self):
        before = copy.deepcopy(self.api.data)
        for expected in ("assigned", "already_assigned"):
            status, result = self.run_cli(apply=True)
            self.assertEqual((status, result["result"]), (0, expected))
        self.assertEqual(len(self.api.writes), 1)
        before["destination_members"].append({"type": "builds", "id": "200"})
        self.assertEqual(self.api.data, before)

    def test_pagination_selects_by_upload_instant_not_version_or_response_order(self):
        self.api.page_size = 1
        self.clone_build("201", version="999", uploadedDate="2026-09-24T13:00:00+02:00")
        self.clone_build("202", version="1", uploadedDate="2026-09-24T08:30:00-07:00")
        self.api.data["destination_members"].append({"type": "builds", "id": "202"})
        status, result = self.run_cli(apply=True)
        self.assertEqual((status, result["build_id"], result["result"]), (0, "202", "already_assigned"))
        self.assertFalse(self.api.writes)

    def test_equal_upload_dates_have_stable_id_tiebreaker(self):
        self.clone_build("201")
        for _ in range(2):
            status, result = self.run_cli()
            self.assertEqual((status, result["build_id"]), (0, "201"))
            self.api.data["builds"].reverse()

    def test_newer_unprocessed_expired_and_non_ios_builds_are_not_candidates(self):
        for i, attrs in enumerate(({"processingState": "PROCESSING"}, {"processingState": "FAILED"},
                                   {"processingState": "INVALID"}, {"expired": True},
                                   {"expirationDate": "2000-01-01T00:00:00Z"})):
            build = self.clone_build(str(210 + i), uploadedDate="2026-09-25T12:00:00Z", **attrs)
            if "processingState" in attrs:
                build.pop("relationships")
        for i, platform in enumerate(("VISION_OS", "MAC_OS", "TV_OS")):
            build = self.clone_build(str(220 + i), uploadedDate="2026-09-25T12:00:00Z")
            version = {"type": "preReleaseVersions", "id": str(320 + i)}
            build["relationships"]["preReleaseVersion"]["data"] = version
            self.api.data["included"].append(dict(version, attributes={"platform": platform}))
        status, result = self.run_cli()
        self.assertEqual((status, result["build_id"]), (0, "200"))

    def test_no_candidate_is_a_clear_noop(self):
        self.api.data["builds"][0]["attributes"]["expired"] = True
        status, result = self.run_cli(apply=True)
        self.assertEqual((status, result["result"]), (0, "no_candidate"))
        self.assertFalse(self.api.writes)

    def test_internal_only_newest_build_is_assigned_without_falling_back(self):
        self.clone_build("201", uploadedDate="2026-09-25T12:00:00Z", buildAudienceType="INTERNAL_ONLY")
        self.api.data["assignment_request"]["data"][0]["id"] = "201"
        status, result = self.run_cli(apply=True)
        self.assertEqual(status, 0, result)
        self.assertEqual((status, result["result"], result["build_id"]), (0, "assigned", "201"))
        self.assertEqual(result["internal_state"], "IN_BETA_TESTING")
        self.assertEqual(len(self.api.writes), 1)

    def test_every_apple_internal_state_and_blocker_never_falls_back(self):
        older = self.clone_build("199", uploadedDate="2026-09-23T12:00:00Z")
        older["relationships"]["buildBetaDetail"]["data"]["id"] = "401"
        self.api.data["included"].append({"type": "buildBetaDetails", "id": "401",
                                          "attributes": {"internalBuildState": "IN_BETA_TESTING"}})
        for state in FIXTURE["internal_states"]:
            with self.subTest(state=state):
                self.set_state(state)
                expected = "would_assign" if state in ("READY_FOR_BETA_TESTING", "IN_BETA_TESTING") else "blocked"
                status, result = self.run_cli(apply=expected == "blocked")
                self.assertEqual(status, 0)
                self.assertEqual((result["result"], result["build_id"]), (expected, "200"))
        self.assertFalse(self.api.writes)

    def test_assigned_build_missing_compliance_is_not_reported_as_distributed(self):
        self.api.data["destination_members"].append({"type": "builds", "id": "200"})
        self.set_state("MISSING_EXPORT_COMPLIANCE")
        status, result = self.run_cli(apply=True)
        self.assertEqual((status, result["result"], result["assigned"]), (0, "blocked", True))
        self.assertFalse(self.api.writes)

    def test_ready_assignment_does_not_claim_testing_or_send_notifications(self):
        self.set_state("READY_FOR_BETA_TESTING")
        for _ in range(2):
            status, result = self.run_cli(apply=True)
            self.assertEqual((status, result["result"]), (0, "assigned_pending_testing"))
            self.assertIn("Internal Testing", result["action"])
            self.assertNotIn("Notify Testers", result["action"])
        self.assertEqual(len(self.api.writes), 1)

    def test_external_review_metadata_cannot_gate_internal_distribution(self):
        linkage = {"type": "betaAppReviewSubmissions", "id": "500"}
        for state in (None, "WAITING_FOR_REVIEW", "IN_REVIEW", "REJECTED", "APPROVED", "FUTURE"):
            with self.subTest(review=state):
                self.api = FixtureAPI(self)
                self.api.data["included"][2]["attributes"]["externalBuildState"] = "NOT_APPLICABLE"
                if state is not None:
                    self.api.data["builds"][0]["relationships"]["betaAppReviewSubmission"] = {"data": linkage}
                    self.api.data["included"].append(dict(linkage, attributes={"betaReviewState": state}))
                status, result = self.run_cli(apply=True)
                self.assertEqual((status, result["result"]), (0, "assigned"))
                self.assertEqual(len(self.api.writes), 1)

    def test_ambiguous_groups_require_matching_pinned_id(self):
        for index, env, field in ((0, "ASC_SOURCE_GROUP_ID", "source_group_id"),
                                  (1, "ASC_DESTINATION_GROUP_ID", "destination_group_id")):
            with self.subTest(group=field):
                self.api = FixtureAPI(self)
                self.api.page_size = 1
                original = self.api.data["groups"][index]
                self.api.data["groups"].append(dict(copy.deepcopy(original), id="105"))
                status, result = self.run_cli(apply=True)
                self.assertEqual((status, result["result"]), (1, "error"))
                self.assertIn(env, result["action"])
                with patch.dict(os.environ, {env: original["id"]}):
                    status, result = self.run_cli()
                    self.assertEqual((status, result[field]), (0, original["id"]))
                self.assertFalse(self.api.writes)

    def test_group_pins_cannot_bypass_app_name_or_type(self):
        for name, values in (("ASC_SOURCE_GROUP_ID", ("102", "104", "999")),
                             ("ASC_DESTINATION_GROUP_ID", ("101", "103", "999"))):
            for value in values:
                with self.subTest(env=name, pin=value), patch.dict(os.environ, {name: value}):
                    status, _ = self.run_cli(apply=True)
                    self.assertEqual(status, 1)
        self.assertFalse(self.api.writes)

    def test_destination_must_explicitly_disable_all_build_access(self):
        for value in (True, None, "false", 0):
            with self.subTest(value=value):
                self.api.data["groups"][1]["attributes"]["hasAccessToAllBuilds"] = value
                status, result = self.run_cli(apply=True)
                self.assertEqual((status, result["result"]), (1, "error"))
                self.assertIn("all-build access", result["action"])
        self.assertFalse(self.api.writes)

    def test_source_and_destination_must_be_distinct_resources(self):
        self.api.data["groups"][1]["id"] = "101"
        status, result = self.run_cli(apply=True)
        self.assertEqual((status, result["result"]), (1, "error"))
        self.assertIn("different resources", result["action"])
        self.assertFalse(self.api.writes)

    def test_group_type_requires_boolean_not_truthiness(self):
        for value in (None, "false", 0):
            self.api.data["groups"][1]["attributes"]["isInternalGroup"] = value
            status, result = self.run_cli(apply=True)
            self.assertEqual(status, 1)
            self.assertIn("type", result["action"])
        self.assertFalse(self.api.writes)

    def test_app_ambiguity_on_later_page_fails_without_writes(self):
        self.api.page_size = 1
        self.api.data["apps"].append({"type": "apps", "id": "900", "attributes": {"bundleId": "dev.intentapp.ios"}})
        status, _ = self.run_cli(apply=True)
        self.assertEqual(status, 1)
        self.assertFalse(self.api.writes)

    def test_missing_or_wrong_app_and_missing_internal_groups_fail(self):
        for field, value in (("apps", []), ("apps", [{"type": "apps", "id": "100", "attributes": {"bundleId": "other"}}]),
                             ("groups", FIXTURE["groups"][1:]),
                             ("groups", [g for g in FIXTURE["groups"] if g["id"] != "102"]), ("groups", [])):
            with self.subTest(field=field):
                self.api.data = copy.deepcopy(FIXTURE)
                self.api.data[field] = value
                self.assertEqual(self.run_cli(apply=True)[0], 1)
        self.assertFalse(self.api.writes)

    def test_missing_selection_and_eligibility_metadata_fail_closed(self):
        mutations = [
            lambda d: d["builds"][0]["attributes"].pop("uploadedDate"),
            lambda d: d["builds"][0]["attributes"].pop("expired"),
            lambda d: d["builds"][0]["attributes"].pop("expirationDate"),
            lambda d: d["builds"][0]["attributes"].pop("buildAudienceType"),
            lambda d: d["builds"][0]["attributes"].update(processingState="FUTURE"),
            lambda d: d["builds"][0]["attributes"].update(uploadedDate="2026-09-25"),
            lambda d: d["included"][1]["attributes"].update(platform="UNKNOWN"),
            lambda d: d["included"][2]["attributes"].update(internalBuildState="UNKNOWN"),
            lambda d: d["included"][2]["attributes"].update(internalBuildState="BETA_APPROVED"),
            lambda d: d["included"][2]["attributes"].pop("internalBuildState"),
            lambda d: d["included"][0]["attributes"].update(bundleId="other"),
            lambda d: d["builds"][0]["relationships"].pop("buildBetaDetail"),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                self.api.data = copy.deepcopy(FIXTURE)
                # Even a ready external state cannot substitute for internal metadata.
                self.api.data["included"][2]["attributes"]["externalBuildState"] = "IN_BETA_TESTING"
                mutate(self.api.data)
                self.assertEqual(self.run_cli(apply=True)[0], 1)
        self.assertFalse(self.api.writes)

    def test_expiry_is_rechecked_immediately_before_assignment(self):
        self.api.on_detail = lambda: self.api.data["builds"][0]["attributes"].update(expired=True)
        status, result = self.run_cli(apply=True)
        self.assertEqual((status, result["result"]), (0, "blocked"))
        self.assertFalse(self.api.writes)

    def test_post_assignment_state_is_rechecked_without_claiming_availability(self):
        self.api.on_post = lambda: self.set_state("IN_EXPORT_COMPLIANCE_REVIEW")
        status, result = self.run_cli(apply=True)
        self.assertEqual((status, result["result"]), (0, "assigned_but_blocked"))
        self.assertEqual(len(self.api.writes), 1)

    def test_invalid_pagination_never_sends_token_to_other_host_or_applies_partial_result(self):
        for link in ("https://untrusted.example/v1/apps?cursor=1", "https://api.appstoreconnect.apple.com/v1/builds", "https://api.appstoreconnect.apple.com/v1/apps?cursor=0"):
            with self.subTest(link=link):
                self.api.next_override = link
                status, _ = self.run_cli(apply=True)
                self.assertEqual(status, 1)
        self.assertFalse(self.api.writes)

    def test_http_failures_are_bounded_and_do_not_print_response_content(self):
        for code, attempts in ((401, 1), (403, 1), (404, 1), (429, 3), (500, 3)):
            with self.subTest(code=code):
                self.api.calls = []
                self.api.failures = [urllib.error.HTTPError("https://private.invalid", code, "private-marker", {}, io.BytesIO(b"private-marker")) for _ in range(attempts)]
                status, result = self.run_cli(apply=True)
                self.assertEqual(status, 1)
                self.assertEqual(len(self.api.calls), attempts)
                self.assertNotIn("private-marker", json.dumps(result))
        self.assertFalse(self.api.writes)

    def test_page_limit_fails_without_using_partial_selection(self):
        self.api.page_size = 1
        for number in range(201, 401):
            self.clone_build(str(number))
        status, result = self.run_cli(apply=True)
        self.assertEqual(status, 1)
        self.assertIn("Pagination limit", result["action"])
        self.assertFalse(self.api.writes)

    def test_transient_get_failure_retries_but_malformed_json_does_not(self):
        self.api.failures = [urllib.error.URLError("private-marker")]
        self.assertEqual(self.run_cli()[0], 0)
        for value in ("not-an-object", b"not-json", {"data": []}):
            self.api.calls = []
            self.api.failures = [Response(value)]
            self.assertEqual(self.run_cli()[0], 1)
            self.assertEqual(len(self.api.calls), 1)

    def test_connection_failures_are_bounded_and_sanitized(self):
        self.api.failures = [urllib.error.URLError("private-marker") for _ in range(3)]
        status, result = self.run_cli(apply=True)
        self.assertEqual(status, 1)
        self.assertEqual(len(self.api.calls), 3)
        self.assertNotIn("private-marker", json.dumps(result))
        self.assertFalse(self.api.writes)

    def test_uncertain_write_is_never_retried_and_next_run_reconciles(self):
        self.api.post_status = 503
        status, result = self.run_cli(apply=True)
        self.assertEqual(status, 1)
        self.assertIn("may have succeeded", result["action"])
        self.api.post_status = 204
        status, result = self.run_cli(apply=True)
        self.assertEqual((status, result["result"]), (0, "already_assigned"))
        self.assertEqual(len(self.api.writes), 1)

    def test_conflict_only_succeeds_when_membership_is_confirmed(self):
        for persists, expected in ((False, 1), (True, 0)):
            with self.subTest(persists=persists):
                self.api = FixtureAPI(self)
                self.api.post_status = 409
                self.api.post_persists = persists
                self.assertEqual(self.run_cli(apply=True)[0], expected)
                self.assertEqual(len(self.api.writes), 1)

    def test_unconfirmed_assignment_is_not_reported_as_success(self):
        self.api.post_persists = False
        status, result = self.run_cli(apply=True)
        self.assertEqual(status, 1)
        self.assertIn("not yet visible", result["action"])
        self.assertEqual(len(self.api.writes), 1)


class CredentialAndSafetyTests(unittest.TestCase):
    def test_missing_credentials_and_accidental_cli_secrets_are_not_echoed(self):
        output = io.StringIO()
        with patch.dict(os.environ, {}, clear=True), redirect_stdout(output):
            self.assertEqual(promotion.main([]), 1)
        self.assertIn("ASC_PRIVATE_KEY_PATH", output.getvalue())
        output = io.StringIO()
        with redirect_stderr(output), self.assertRaises(SystemExit) as exit_result:
            promotion.main(["--key", "synthetic-private-marker"])
        self.assertEqual(exit_result.exception.code, 2)
        self.assertNotIn("synthetic-private-marker", output.getvalue())

    def test_write_guard_and_redirect_guard_prevent_unapproved_operations(self):
        for apply in (False, True):
            client = promotion.Client(None, apply=apply)
            client.write_path = "/v1/betaGroups/102/relationships/builds" if apply else None
            for path in ("/v1/betaAppReviewSubmissions", "/v1/buildBetaNotifications", "/v1/betaGroups/102",
                         "/v1/betaGroups/101/relationships/builds", "/v1/betaGroups/103/relationships/builds",
                         "/v1/builds/200"):
                with self.subTest(apply=apply, path=path), self.assertRaises(promotion.PromotionError):
                    client.request(path, body={})
        with self.assertRaises(promotion.PromotionError):
            promotion.Client(None).request("/v1/betaGroups/102/relationships/builds", body={})
        with self.assertRaises(promotion.PromotionError):
            promotion.NoRedirects().redirect_request(None, None, 302, "private-marker", {}, "https://other.invalid")

    def test_openssl_signs_verifiable_scoped_es256_without_secret_arguments(self):
        with tempfile.TemporaryDirectory(prefix="testflight-key-test-") as directory:
            key = Path(directory) / "test.p8"
            public = Path(directory) / "test.pub"
            signature = Path(directory) / "signature.der"
            subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(key)], capture_output=True, check=True)
            key.chmod(0o600)
            subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout", "-out", str(public)], capture_output=True, check=True)
            env = {"ASC_KEY_ID": "TESTKEY", "ASC_ISSUER_ID": "test-issuer", "ASC_PRIVATE_KEY_PATH": str(key)}
            with patch.dict(os.environ, env, clear=True), patch.object(promotion.subprocess, "run", wraps=subprocess.run) as process:
                credentials = promotion.Credentials()
                token = credentials.token("GET", "/v1/apps")
                argv = process.call_args.args[0]
                self.assertNotIn("TESTKEY", argv)
                self.assertNotIn("test-issuer", argv)
                self.assertNotIn(key.read_text(), " ".join(argv))
            head, payload, raw = token.split(".")
            decode = lambda x: base64.urlsafe_b64decode(x + "=" * (-len(x) % 4))
            self.assertEqual(json.loads(decode(head)), {"alg": "ES256", "typ": "JWT", "kid": "TESTKEY"})
            claims = json.loads(decode(payload))
            self.assertEqual(claims["aud"], "appstoreconnect-v1")
            self.assertEqual(claims["scope"], ["GET /v1/apps"])
            self.assertEqual(claims["exp"] - claims["iat"], 120)
            raw = decode(raw)
            self.assertEqual(len(raw), 64)
            integers = []
            for value in (raw[:32], raw[32:]):
                value = value.lstrip(b"\x00") or b"\x00"
                if value[0] & 128:
                    value = b"\x00" + value
                integers.append(b"\x02" + bytes([len(value)]) + value)
            encoded = b"".join(integers)
            signature.write_bytes(b"\x30" + bytes([len(encoded)]) + encoded)
            verification = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(public), "-signature", str(signature)], input=(head + "." + payload).encode(), capture_output=True)
            self.assertEqual(verification.returncode, 0)
            with patch.dict(os.environ, env, clear=True):
                key.chmod(0o644)
                with self.assertRaises(promotion.PromotionError):
                    promotion.Credentials()
                key.chmod(0o600)
                key.write_text("not-a-key")
                with self.assertRaises(promotion.PromotionError):
                    promotion.Credentials().token("GET", "/v1/apps")


if __name__ == "__main__":
    unittest.main()