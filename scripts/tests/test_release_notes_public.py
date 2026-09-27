"""Public baseline owner: documented states, complete history, availability and GET-only generation.

The generator suite already owns source/Git rendering. These tests use its real
Git fixture but independently specify public selection responses and assertions.
"""

import copy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import test_release_notes as fixtures

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import app_store_notes as public
import release_notes as notes


def version(identity="v199", build="199", state="READY_FOR_DISTRIBUTION"):
    return {"id": identity, "type": "appStoreVersions", "attributes": {
        "versionString": "1.2.0", "platform": "IOS", "reviewType": "APP_STORE",
        "appVersionState": state, "downloadable": True,
        "createdDate": "2099-01-01T00:00:00Z"}, "relationships": {
            "app": {"data": {"id": "100", "type": "apps"}}, "build": {"data": {"id": build, "type": "builds"}}}}


class PublicTests(unittest.TestCase):
    def setUp(self):
        self.owner = fixtures.ReleaseNotesTests()
        self.owner.setUp()
        self.addCleanup(self.owner.doCleanups)
        self.addCleanup(lambda: self.assertEqual(self.owner.api.errors, []))
        self.rows = [version(), version("v-old", "old", "REPLACED_WITH_NEW_VERSION"),
                     version("v-next", "200", "PENDING_DEVELOPER_RELEASE")]
        self.statuses = ["AVAILABLE"]
        self.calls, self.pages, self.version_reads = [], {}, 0
        self.drift = False

    def read(self, path, query=None):
        self.calls.append((path, query))
        if path in self.pages:
            return copy.deepcopy(self.pages[path])
        if path == "/v1/apps":
            self.assertEqual(query, {"filter[bundleId]": "dev.intentapp.ios", "fields[apps]": "bundleId", "limit": 200})
            return {"data": [{"id": "100", "type": "apps", "attributes": {"bundleId": "dev.intentapp.ios"}}], "links": {"self": path}}
        if path == "/v1/apps/100/appStoreVersions":
            self.assertEqual(query, {"filter[platform]": "IOS", "fields[appStoreVersions]":
                                    "platform,versionString,appVersionState,reviewType,downloadable,app,build", "limit": 200})
            self.version_reads += 1
            rows = copy.deepcopy(self.rows)
            if self.drift and self.version_reads > 1:
                rows[0]["relationships"]["build"]["data"]["id"] = "other"
            return {"data": rows, "links": {"self": path}}
        if path == "/v1/apps/100/appAvailabilityV2":
            self.assertIsNone(query)
            return {"data": {"id": "available", "type": "appAvailabilities"}}
        if path == "/v2/appAvailabilities/available/territoryAvailabilities":
            self.assertEqual(query, {"fields[territoryAvailabilities]": "contentStatuses", "limit": 200})
            return {"data": [{"id": "USA", "type": "territoryAvailabilities", "attributes": {
                "available": True, "releaseDate": "2000-01-01", "contentStatuses": self.statuses}}], "links": {"self": path}}
        return self.owner.api(path, query)

    def generate(self):
        return public.generate(self.owner.repo, "200", {}, self.read)["payload"]

    def test_actual_current_release_not_created_order_upload_tag_or_pending_candidate(self):
        for rows in (self.rows, list(reversed(self.rows))):
            self.rows = rows
            payload = self.generate()
            self.assertEqual(payload["baseline"]["build_id"], "199")
            self.assertEqual(payload["candidate"]["build_id"], "200")
            self.assertEqual(payload["channel_heading"], "### App Store")
            self.assertEqual(payload["comparison"], self.owner.base + ".." + self.owner.candidate)
            self.assertIn("v199", payload["baseline_reference"])
        self.assertFalse((self.owner.repo / "CHANGELOG.md").exists())
        self.assertEqual(self.owner.git("status", "--porcelain"), "")

    def test_ready_state_and_available_boolean_do_not_prove_release(self):
        for status in (["AVAILABLE_FOR_PREORDER"], ["AVAILABLE_FOR_SALE_UNRELEASED_APP"],
                       ["PROCESSING_TO_AVAILABLE"], ["CANNOT_SELL"], [], None):
            with self.subTest(status=status):
                self.statuses = status
                with self.assertRaises(notes.NotesError):
                    self.generate()
        self.assertFalse(any("/builds/" in p for p, _ in self.calls))

    def test_missing_ambiguous_wrong_platform_and_unreleased_baselines_fail_closed(self):
        original = copy.deepcopy(self.rows)
        for case in ("first", "duplicate", "unknown", "platform", "app", "notarized", "not-downloadable", "build-version"):
            with self.subTest(case=case):
                self.rows = copy.deepcopy(original)
                if case == "first": self.rows = self.rows[1:]
                elif case == "duplicate": self.rows.append(version("another"))
                elif case == "app": self.rows[0]["relationships"]["app"]["data"]["id"] = "wrong"
                else:
                    field, value = {"unknown": ("appVersionState", "FUTURE"), "platform": ("platform", "MAC_OS"),
                                    "notarized": ("reviewType", "NOTARIZATION"), "not-downloadable": ("downloadable", False),
                                    "build-version": ("versionString", "999.0")}[case]
                    self.rows[0]["attributes"][field] = value
                with self.assertRaises(notes.NotesError): self.generate()

    def test_later_page_ambiguity_and_baseline_drift_never_choose_first_result(self):
        path = "/v1/apps/100/appStoreVersions"
        next_page = "https://api.appstoreconnect.apple.com" + path + "?cursor=2"
        self.pages[path] = {"data": [version()], "links": {"self": path, "next": next_page}}
        self.pages[next_page] = {"data": [version("other")], "links": {"self": next_page}}
        with self.assertRaisesRegex(notes.NotesError, "unique"): self.generate()
        self.pages = {}
        self.drift = True
        self.version_reads = 0
        with self.assertRaisesRegex(notes.NotesError, "changed"): self.generate()

    def test_public_cli_uses_read_only_client_and_writes_new_intent_only(self):
        output = self.owner.root / "intent.json"
        class ReadClient:
            def __init__(client, credentials, apply):
                self.assertFalse(apply)
            def request(client, path, query=None, **kwargs):
                self.assertFalse(kwargs)
                return self.read(path.removeprefix("https://api.appstoreconnect.apple.com"), query)
        import os
        previous = os.getcwd()
        self.addCleanup(os.chdir, previous)
        os.chdir(self.owner.repo)
        with patch.object(public, "Client", ReadClient), patch.object(public, "Credentials"), patch("builtins.print"):
            self.assertEqual(public.main(["--candidate", "200", "--output", str(output)]), 0)
            original = output.read_bytes()
            self.assertEqual(public.main(["--candidate", "200", "--output", str(output)]), 1)
        self.assertEqual(output.read_bytes(), original)
        self.assertEqual(json.loads(original)["payload"]["baseline"]["build_id"], "199")


if __name__ == "__main__":
    unittest.main()