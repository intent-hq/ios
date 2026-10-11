#!/usr/bin/env python3
"""Reject false greens in the native assertion-abort evidence verifier."""

import copy
import unittest

import verify_fixture_capture_lifecycle as contract


def native_results():
    tests = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": f"{contract.SUITE}/{test}()",
                            "result": result} for test, result in ((contract.ABORT, "Failed"), (contract.PASS, "Passed"))]}
    details = {"testIdentifier": f"{contract.SUITE}/{contract.ABORT}()", "testResult": "Failed", "testRuns": [
        {"nodeType": "Test Case Run", "children": [
            {"nodeType": "Failure Message", "name": "XCTAssertTrue failed - " + contract.MARKER},
        ]},
    ]}
    return tests, details


class ResultTests(unittest.TestCase):
    def test_requires_original_failure_and_passing_companion(self):
        tests, details = native_results()
        contract.verify_result(65, tests, details)
        for status in (0, 1, 80, 81, 82, 83):
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, "exit 65"):
                contract.verify_result(status, tests, details)

    def test_rejects_green_skipped_unknown_and_missing_execution(self):
        for result in ("Passed", "Skipped", "Expected Failure", "unknown"):
            tests, details = native_results()
            tests["testNodes"][0]["result"] = result
            with self.subTest(result=result), self.assertRaisesRegex(ValueError, "exactly"):
                contract.verify_result(65, tests, details)
        for remove in (0, 1):
            tests, details = native_results()
            del tests["testNodes"][remove]
            with self.assertRaisesRegex(ValueError, "exactly"):
                contract.verify_result(65, tests, details)

    def test_rejects_wrong_identity_and_additional_tests(self):
        tests, details = native_results()
        tests["testNodes"].append(copy.deepcopy(tests["testNodes"][0]))
        with self.assertRaisesRegex(ValueError, "exactly"):
            contract.verify_result(65, tests, details)
        tests, details = native_results()
        details["testIdentifier"] = f"UnrelatedTests/{contract.ABORT}()"
        with self.assertRaisesRegex(ValueError, "wrong test"):
            contract.verify_result(65, tests, details)

    def test_rejects_incidental_failure_and_continued_execution(self):
        for message in ("App failed to launch", "fixture-capture-contract-continued-after-abort"):
            tests, details = native_results()
            details["testRuns"][0]["children"][0]["name"] = message
            with self.assertRaisesRegex(ValueError, "original intentional assertion"):
                contract.verify_result(65, tests, details)
        tests, details = native_results()
        details["testRuns"][0]["children"].append({"nodeType": "Failure Message", "name": "teardown failed"})
        with self.assertRaisesRegex(ValueError, "original intentional assertion"):
            contract.verify_result(65, tests, details)


if __name__ == "__main__":
    unittest.main()
