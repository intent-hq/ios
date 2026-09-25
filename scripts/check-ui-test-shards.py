#!/usr/bin/env python3
"""Fail closed unless every expected UI job and its matrix succeeded.

Usage: check-ui-test-shards.py <matrix-result> <run-attempt> [expected-count]
The count defaults to 2 for existing callers. CI must pass the same configured
count used by the workers (UI_TEST_SHARD_COUNT), never infer it from returned jobs.
Append <reports-directory> for the shared-build UI gate, or use
--required <run-attempt> <reports-directory> for the stable build/unit/Go/lint gate.
Shared gates require NEEDS_JSON and trusted TEST_ARTIFACT_RUN/REVISION/SHA256.
"""

import json
import os
from pathlib import Path
import re
import sys


def require(ok, message):
    if not ok:
        raise ValueError(message)


def read_jobs():
    pages = json.load(sys.stdin)
    if not isinstance(pages, list) or not pages:
        raise ValueError("Missing job pages")
    jobs = []
    for page in pages:
        if not isinstance(page, dict) or not isinstance(page.get("jobs"), list):
            raise ValueError("Invalid job page")
        if any(not isinstance(job, dict) for job in page["jobs"]):
            raise ValueError("Invalid job record")
        jobs.extend(page["jobs"])
    return jobs


def successful_job(jobs, name, attempt):
    matches = [job for job in jobs if job.get('name') == name]
    require(matches, f'Missing {name}')
    require(all(type(j.get('run_attempt')) is int and 1 <= j['run_attempt'] <= attempt for j in matches),
            f'Invalid attempt for {name}')
    latest_attempt = max(j['run_attempt'] for j in matches)
    latest = [j for j in matches if j['run_attempt'] == latest_attempt]
    require(len(latest) == 1, f'Ambiguous records for {name}')
    require(latest[0].get('status') == 'completed' and latest[0].get('conclusion') == 'success',
            f'{name} did not complete successfully')
    return latest_attempt


def prerequisites(jobs, attempt, required):
    filtered = bool(os.environ.get('ONLY_TESTING', ''))
    require(required or not filtered, 'Filtered dispatch cannot satisfy the full UI gate')
    expected = {'ios-test-build': 'iOS Test Build',
                'ios-unit-tests': 'iOS Filtered Worker (non-gating)' if filtered else 'iOS Unit Tests'}
    if required:
        expected.update({'go-test': 'Go unit tests (TailcatKit)', 'swiftlint': 'SwiftLint'})
    needs = json.loads(os.environ['NEEDS_JSON'])
    keys = list(expected) + ([] if required else ['ios-ui-test-shards'])
    require(isinstance(needs, dict) and all(isinstance(needs.get(k), dict)
            and needs[k].get('result') == 'success' for k in keys), 'A prerequisite did not succeed or is missing')
    attempts = {key: successful_job(jobs, name, attempt) for key, name in expected.items()}
    run = os.environ['TEST_ARTIFACT_RUN']
    require(run == f'{os.environ["GITHUB_RUN_ID"]}-{attempts["ios-test-build"]}',
            'Trusted producer identity does not match the latest build job')
    revision, digest = os.environ['TEST_ARTIFACT_REVISION'], os.environ['TEST_ARTIFACT_SHA256']
    require(re.fullmatch('[0-9a-f]{40}', revision) and re.fullmatch('[0-9a-f]{64}', digest),
            'Missing trusted producer revision/digest')
    return {'run': run, 'revision': revision, 'artifact_sha256': digest}, attempts['ios-unit-tests']


def report(root, kind, attempt, file, identity):
    path = root / f'ios-selection-{os.environ["GITHUB_RUN_ID"]}-{attempt}-{kind}' / file
    require(path.is_file() and not path.is_symlink(), f'Missing selection report: {kind}, attempt {attempt}')
    data = json.loads(path.read_text())
    require(isinstance(data, dict) and data.get('schema') == 1, 'Invalid selection report schema')
    require(all(data.get(k) == v for k, v in identity.items()), 'Selection report has a different producer identity/digest')
    for key in ('enabled', 'disabled', 'selectors'):
        values = data.get(key)
        require(isinstance(values, list) and all(isinstance(v, str) and v and v == v.strip() for v in values),
                f'Invalid {key} catalog/selection')
        normalized = [v.removesuffix('()') for v in values]
        require(len(normalized) == len(set(normalized)), f'Duplicate {key} catalog/selection')
    require(data['enabled'] and data['selectors'], 'Empty enabled catalog or selection')
    enabled, disabled = catalog(data)
    require(not enabled & disabled, 'Enabled/disabled catalog disagreement')
    return data


def catalog(data, omit_ui=False):
    return tuple({s.removesuffix('()') for s in data[k]
                  if not omit_ui or not s.startswith('IntentUITests/')} for k in ('enabled', 'disabled'))


def unit_reports(root, attempt, identity):
    unit = report(root, 'unit', attempt, 'unit-selection.json', identity)
    source = report(root, 'unit', attempt, 'source-selection.json', identity)
    filtered = os.environ.get('ONLY_TESTING', '')
    for data in (unit, source):
        require(data.get('shard') is None and data.get('shard_count') is None, 'Unexpected unit/source shard')
    require(unit['selectors'] == (filtered.split() if filtered else ['IntentTests']), 'Wrong unit/filtered selection')
    suites = {'IntentTests/' + name for name in ('InfoPlistSyncTests', 'PlatformGuardAllowlistTests',
              'ObjCCallbackIsolationTests', 'ExternalLinkTests', 'PrivacyManifestDriftTests')}
    require(set(source['selectors']) == suites, 'Incomplete source-independence selection')
    require(catalog(unit) == catalog(source, omit_ui=not filtered), 'Unit/source catalog mismatch')
    return source


def main():
    required = len(sys.argv) == 4 and sys.argv[1] == '--required'
    require(required or len(sys.argv) in (3, 4, 5) and sys.argv[1] == 'success', 'UI shard matrix did not succeed')
    attempt = int(sys.argv[2])
    require(attempt >= 1, 'Invalid workflow attempt')
    jobs = read_jobs()
    shared = required or len(sys.argv) == 5
    if shared:
        identity, unit_attempt = prerequisites(jobs, attempt, required)
        root = Path(sys.argv[-1])
        source = unit_reports(root, unit_attempt, identity)
    if required:
        print('Build, unit, source-independence, Go and lint prerequisites succeeded')
        return
    count = sys.argv[3] if len(sys.argv) >= 4 else '2'
    require(re.fullmatch(r'[1-9][0-9]*', count), 'Expected shard count must be a positive decimal integer')
    count = int(count)
    if count > len(jobs):
        raise ValueError("Fewer job records than expected UI shards")
    expected_names = {f"iOS UI Tests (shard {shard}/{count})" for shard in range(1, count + 1)}
    for job in jobs:
        name = job.get("name")
        if isinstance(name, str) and name.startswith("iOS UI Tests (shard") and name not in expected_names:
            raise ValueError(f"Unexpected UI shard job: {name}")
    selected = set()
    for shard in range(1, count + 1):
        name = f"iOS UI Tests (shard {shard}/{count})"
        latest_attempt = successful_job(jobs, name, attempt)
        if shared:
            data = report(root, f'shard-{shard}', latest_attempt, 'ui-selection.json', identity)
            require(type(data.get('shard')) is int and data['shard'] == shard
                    and type(data.get('shard_count')) is int and data['shard_count'] == count, 'Wrong shard index/count')
            require(catalog(data) == catalog(source), 'UI worker catalog mismatch')
            methods = {s.removesuffix('()') for s in data['selectors']}
            require(all(re.fullmatch(r'IntentUITests/[^/()\s]+/[^/()\s]+', s) for s in methods),
                    'UI selection must contain exact method identifiers')
            require(not selected & methods, 'Overlapping UI shard selections')
            selected.update(methods)
    if shared:
        enabled_ui = {s for s in catalog(source)[0] if s.startswith('IntentUITests/')}
        require(selected == enabled_ui, 'UI selections do not cover the enabled catalog exactly')
    print(f"All {count} UI shards completed successfully")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f"UI test gate failed: {error}", file=sys.stderr)
        sys.exit(1)