#!/usr/bin/env python3
"""Exercise the production aggregate CLI with GitHub jobs API responses."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CHECK = Path(__file__).with_name("check-ui-test-shards.py")


def job(shard, conclusion="success", status="completed", attempt=1, count=2):
    return {"name": f"iOS UI Tests (shard {shard}/{count})", "status": status,
            "conclusion": conclusion, "run_attempt": attempt}


class UIShardGateTests(unittest.TestCase):
    def check(self, pages, expected, result="success", attempt="1", count=None):
        completed = subprocess.run(
            [sys.executable, str(CHECK), result, attempt] + ([] if count is None else [str(count)]),
            input=json.dumps(pages), capture_output=True, text=True, check=False)
        self.assertEqual(completed.returncode, expected, completed.stderr)

    def test_all_successful_across_pages_with_other_jobs(self):
        for count in (None, 1, 2, 4, 6, 10):
            with self.subTest(count=count):
                jobs = [job(shard, count=count or 2) for shard in range(1, (count or 2) + 1)]
                self.check([{"jobs": list(reversed(jobs[::2])) + [{"name": "SwiftLint"}]},
                            {"jobs": jobs[1::2]}], 0, count=count)

    def test_every_non_successful_matrix_result_fails(self):
        for count in (2, 6):
            for result in ("failure", "cancelled", "skipped", "", "unknown"):
                with self.subTest(count=count, result=result):
                    self.check([{"jobs": [job(i, count=count) for i in range(1, count + 1)]}],
                               1, result=result, count=count)

    def test_each_missing_duplicate_incomplete_or_failed_shard_fails(self):
        for count in (2, 6):
            for shard in range(1, count + 1):
                with self.subTest(count=count, shard=shard):
                    others = [job(i, count=count) for i in range(1, count + 1) if i != shard]
                    self.check([{"jobs": others}], 1, count=count)
                    self.check([{"jobs": others + [job(shard, count=count)] * 2}], 1, count=count)
                    for state in ("queued", "in_progress", None):
                        self.check([{"jobs": others + [job(shard, status=state, count=count)]}],
                                   1, count=count)
                    for conclusion in ("failure", "cancelled", "skipped", "timed_out",
                                       "neutral", "action_required", "stale", None, ""):
                        self.check([{"jobs": others + [job(shard, conclusion, count=count)]}],
                                   1, count=count)

    def test_invalid_count_or_unexpected_shard_names_fail(self):
        jobs = [job(i, count=6) for i in range(1, 7)]
        for count in ("", "0", "-1", "06", "+6", "6.0", "six", " 6", "6\n", "６"):
            with self.subTest(count=count):
                self.check([{"jobs": jobs}], 1, count=count)
        for name in ("0/6", "7/6", "1/2", "01/6", "1/06", "1/6 extra", "unknown"):
            with self.subTest(name=name):
                extra = dict(job(1, count=6), name=f"iOS UI Tests (shard {name})")
                self.check([{"jobs": jobs + [extra]}], 1, count=6)
        self.check([{"jobs": [job(1), job(2)]}], 1, count=6)
        self.check([{"jobs": jobs}], 1)
        self.check([{"jobs": jobs}], 1, count="999999999999999999999999999999")

    def test_malformed_or_missing_evidence_fails(self):
        for pages in (None, {}, [], [{}], [{"jobs": None}], [{"jobs": []}],
                      [{"jobs": [None]}]):
            with self.subTest(pages=pages):
                self.check(pages, 1)
        for attempt in (None, "1", 0, True, 2):
            with self.subTest(attempt=attempt):
                self.check([{"jobs": [job(1), job(2, attempt=attempt)]}], 1)
        for attempt in ("0", "invalid", ""):
            self.check([{"jobs": [job(1), job(2)]}], 1, attempt=attempt)
        completed = subprocess.run(
            [sys.executable, str(CHECK), "success", "1"],
            input="truncated JSON", capture_output=True, text=True, check=False)
        self.assertEqual(completed.returncode, 1)

    def test_partial_rerun_reuses_success_but_never_hides_new_failure(self):
        for count in (2, 6):
            others = [job(i, count=count) for i in range(1, count)]
            self.check([{"jobs": others + [job(count, "failure", count=count),
                                          job(count, attempt=2, count=count)]}],
                       0, attempt="2", count=count)
            for conclusion in ("failure", "cancelled", "skipped"):
                self.check([{"jobs": others + [job(count, count=count),
                                              job(count, conclusion, attempt=2, count=count)]}],
                           1, attempt="2", count=count)
            self.check([{"jobs": others + [job(count, attempt=2, count=count)] * 2}],
                       1, attempt="2", count=count)


class SharedBuildGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.identity = {'run': '900-1', 'revision': 'a' * 40, 'artifact_sha256': 'b' * 64}
        self.env = dict(os.environ, GITHUB_RUN_ID='900', TEST_ARTIFACT_RUN='900-1',
                        TEST_ARTIFACT_REVISION='a' * 40, TEST_ARTIFACT_SHA256='b' * 64, ONLY_TESTING='')
        self.suites = ['IntentTests/' + name for name in ('InfoPlistSyncTests', 'PlatformGuardAllowlistTests',
                       'ObjCCallbackIsolationTests', 'ExternalLinkTests', 'PrivacyManifestDriftTests')]
        self.unit = [suite + '/example()' for suite in self.suites] + ['IntentTests/Other/test()']
        self.ui = [f'IntentUITests/Example/test{i:02}()' for i in range(13)]
        self.jobs = [dict(name=name, status='completed', conclusion='success', run_attempt=1)
                     for name in ('iOS Test Build', 'iOS Unit Tests', 'Go unit tests (TailcatKit)', 'SwiftLint')]
        self.jobs += [job(i, count=6) for i in range(1, 7)]
        self.needs = {key: {'result': 'success'} for key in
                      ('ios-test-build', 'ios-unit-tests', 'go-test', 'swiftlint', 'ios-ui-test-shards')}
        self.reports = {}
        self.reports['unit/unit-selection.json'] = self.report(self.unit, ['IntentTests'])
        self.reports['unit/source-selection.json'] = self.report(self.unit + self.ui, self.suites)
        for i in range(1, 7):
            self.reports[f'shard-{i}/ui-selection.json'] = self.report(self.unit + self.ui, self.ui[i-1::6], i)

    def report(self, enabled, selectors, shard=None):
        return dict(self.identity, schema=1, enabled=sorted(enabled), disabled=[], selectors=selectors,
                    shard=shard, shard_count=6 if shard else None)

    def write_reports(self, attempt=1):
        for key, report in self.reports.items():
            kind, file = key.split('/')
            path = self.root / f'ios-selection-900-{attempt}-{kind}' / file
            path.parent.mkdir(exist_ok=True)
            path.write_text(json.dumps(report))

    def check(self, expected=0, required=False, attempt='1', message=None, write=True):
        if write:
            self.write_reports()
        args = ['--required', attempt, str(self.root)] if required else ['success', attempt, '6', str(self.root)]
        env = dict(self.env, NEEDS_JSON=json.dumps(self.needs))
        completed = subprocess.run([sys.executable, str(CHECK), *args], input=json.dumps([{'jobs': self.jobs}]),
                                   env=env, text=True, capture_output=True, check=False)
        self.assertEqual(completed.returncode, expected, completed.stderr)
        if message:
            self.assertIn(message, completed.stderr)

    def test_full_and_required_gate_success(self):
        self.check()
        self.check(required=True)

    def test_every_prerequisite_fails_closed_in_needs_and_latest_job(self):
        for key, name in zip(('ios-test-build', 'ios-unit-tests', 'go-test', 'swiftlint'),
                             ('iOS Test Build', 'iOS Unit Tests', 'Go unit tests (TailcatKit)', 'SwiftLint')):
            for state in ('failure', 'cancelled', 'skipped', None):
                with self.subTest(key=key, state=state):
                    self.needs[key]['result'] = state
                    self.check(1, required=True, message='prerequisite')
                    self.needs[key]['result'] = 'success'
                    latest = dict(name=name, run_attempt=2, status='completed', conclusion=state)
                    self.jobs.append(latest)
                    self.check(1, required=True, attempt='2', message='successfully')
                    self.jobs.pop()
            saved = self.needs.pop(key)
            self.check(1, required=True, message='prerequisite')
            self.needs[key] = saved
            saved_jobs = self.jobs
            self.jobs = [j for j in self.jobs if j['name'] != name]
            self.check(1, required=True, message='Missing')
            self.jobs = saved_jobs

    def test_identity_digest_and_catalog_mismatches(self):
        key = 'shard-3/ui-selection.json'
        for field, value in (('run', '900-2'), ('revision', 'c' * 40), ('artifact_sha256', 'd' * 64),
                             ('schema', 2), ('shard', 2), ('shard_count', 2)):
            with self.subTest(field=field):
                old = self.reports[key][field]
                self.reports[key][field] = value
                self.check(1)
                self.reports[key][field] = old
        for key, field in (('shard-4/ui-selection.json', 'enabled'), ('shard-5/ui-selection.json', 'disabled'),
                           ('unit/unit-selection.json', 'enabled'), ('unit/source-selection.json', 'enabled')):
            with self.subTest(key=key, field=field):
                self.reports[key][field].append('IntentTests/Unknown/method()')
                self.check(1, message='catalog')
                self.reports[key][field].pop()
        for field in ('TEST_ARTIFACT_RUN', 'TEST_ARTIFACT_REVISION', 'TEST_ARTIFACT_SHA256'):
            old = self.env[field]
            self.env[field] = ''
            self.check(1, required=True)
            self.env[field] = old

    def test_omission_overlap_unknown_duplicate_or_empty_selections_fail(self):
        for selectors in ([], self.ui[0::6][:-1], self.ui[0::6] + [self.ui[1]],
                          self.ui[0::6] + ['IntentUITests/Unknown/test()'], self.ui[0::6] * 2):
            with self.subTest(selectors=selectors):
                self.reports['shard-1/ui-selection.json']['selectors'] = selectors
                self.check(1)

    def test_selection_report_is_not_success_evidence(self):
        for i in range(1, 7):
            for conclusion in ('failure', 'cancelled', 'skipped'):
                self.jobs.append(job(i, conclusion, attempt=2, count=6))
                self.write_reports(attempt=2)
                self.check(1, attempt='2', message='successfully')
                self.jobs.pop()
        self.write_reports()
        self.jobs.pop()
        self.check(1, message='Missing')

    def test_partial_rerun_requires_latest_report_and_same_producer(self):
        self.write_reports()
        self.jobs.append(job(6, attempt=2, count=6))
        self.check(1, attempt='2', write=False, message='report')
        self.write_reports(attempt=2)
        self.check(attempt='2', write=False)
        self.check(required=True, attempt='2', write=False)
        self.jobs.append(dict(name='iOS Test Build', status='completed', conclusion='success', run_attempt=2))
        self.check(1, attempt='2', write=False, message='producer')
        self.env['TEST_ARTIFACT_RUN'] = '900-2'
        self.check(1, attempt='2', write=False, message='producer')

    def test_filtered_dispatch_remains_nongating_and_preserves_source_check(self):
        self.env['ONLY_TESTING'] = 'IntentUITests/Example/test00()'
        self.jobs[1]['name'] = 'iOS Filtered Worker (non-gating)'
        self.reports['unit/unit-selection.json'] = self.report(self.unit + self.ui, [self.env['ONLY_TESTING']])
        self.check(required=True)
        self.check(1, message='Filtered')
        self.reports['unit/source-selection.json']['selectors'] = self.suites[:-1]
        self.check(1, required=True, message='source')

    def test_missing_malformed_or_duplicate_catalog_reports(self):
        self.write_reports()
        path = self.root / 'ios-selection-900-1-shard-2/ui-selection.json'
        for contents in ('{}', 'null', 'truncated JSON'):
            path.write_text(contents)
            self.check(1, write=False)
        path.unlink()
        self.check(1, write=False, message='report')
        self.reports['shard-2/ui-selection.json']['enabled'].append(self.ui[0])
        self.check(1, message='catalog')

    def test_enabled_disabled_alias_disagreement_fails(self):
        for report in self.reports.values():
            report['disabled'] = [self.unit[0].removesuffix('()')]
        self.check(1, required=True, message='catalog disagreement')

    def test_actual_workflow_gate_commands_preserve_failure_status(self):
        workflow = json.loads(subprocess.check_output([
            'ruby', '-ryaml', '-rjson', '-e', 'puts JSON.generate(YAML.load_file(ARGV[0]))',
            str(CHECK.parent.parent / '.github/workflows/ci.yml')], text=True))
        self.write_reports()
        work = self.root / 'workflow'
        (work / 'scripts').mkdir(parents=True)
        (work / 'scripts/check-ui-test-shards.py').symlink_to(CHECK.resolve())
        (work / 'selection-evidence').symlink_to(self.root)
        gh = work / 'gh'
        gh.write_text('#!/usr/bin/env python3\nimport os\nprint(os.environ["JOBS_FIXTURE"])\n')
        gh.chmod(0o755)
        for gate in ('build-and-test', 'ios-ui-tests'):
            command = workflow['jobs'][gate]['steps'][-1]['run']
            for outcome in ('success', 'failure', 'cancelled', 'skipped'):
                self.needs['ios-test-build']['result'] = outcome
                env = dict(self.env, PATH=str(work) + os.pathsep + os.environ['PATH'],
                           GITHUB_RUN_ATTEMPT='1', GITHUB_REPOSITORY='intent-hq/ios',
                           NEEDS_JSON=json.dumps(self.needs), JOBS_FIXTURE=json.dumps([{'jobs': self.jobs}]),
                           SHARD_RESULT='success', EXPECTED_SHARD_COUNT='6')
                completed = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', command],
                                           cwd=work, env=env, capture_output=True, text=True)
                self.assertEqual(completed.returncode, 0 if outcome == 'success' else 1, completed.stderr)
            self.needs['ios-test-build']['result'] = 'success'


if __name__ == "__main__":
    unittest.main()