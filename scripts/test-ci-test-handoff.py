#!/usr/bin/env python3
"""Exercise hosted handoff commands and workflow execution boundaries offline."""

import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / 'scripts/ci-test-handoff.py'
STUB = '''#!/usr/bin/env python3
import json, os, pathlib, sys
config = json.loads(pathlib.Path(os.environ['PLATFORM_FIXTURE']).read_text())
name = pathlib.Path(sys.argv[0]).name
with open(os.environ['CALLS'], 'a') as stream:
    stream.write(json.dumps([name, sys.argv[1:], {k:os.environ.get(k) for k in
        ('ONLY_TESTING', 'UI_TEST_SHARD', 'UI_TEST_SHARD_COUNT', 'TEST_ARTIFACT_RUN',
         'TEST_ARTIFACT_REVISION', 'TEST_ARTIFACT_SHA256', 'TEST_SELECTION_REPORT')}]) + '\\n')
if name == 'uname': print(config['architecture'])
elif name == 'git':
    assert sys.argv[1:] == ['rev-parse', 'HEAD']
    print(config['revision'])
elif name == 'find': print('\\n'.join(config['xcodes']))
elif name == 'xcode-select': print(next(iter(config['xcodes'])) + '/Contents/Developer')
elif name == 'xcodebuild':
    assert sys.argv[1:] == ['-version'], 'unexpected build/SPM fallback'
    version = config['xcodes'][os.environ['DEVELOPER_DIR'].removesuffix('/Contents/Developer')]
    if version == 'broken': sys.exit(1)
    print(version)
elif name == 'xcrun':
    assert sys.argv[1:3] == ['simctl', 'list']
    print(json.dumps({sys.argv[3]:config[sys.argv[3]]}))
elif name == 'xcodebuild.sh':
    if sys.argv[1:] == ['pick-simulator']: print('producer-device')
    else:
        assert sys.argv[1:] in (['test-without-building'], ['test-without-building-unit'], ['build-test-artifact'])
        if os.environ.get('CHECK_SOURCE_UNAVAILABLE'):
            assert not pathlib.Path('Intent/owned-input').exists()
            assert not pathlib.Path('IntentTests/owned-input').exists()
            assert not pathlib.Path('Info-visionOS.plist').exists()
        sys.exit(config.get('wrapper_exit', 0))
elif name == 'gh':
    if sys.argv[1] == 'api': print(json.dumps(config['pages']))
    else:
        assert sys.argv[1:4] == ['run', 'download', '900']
        dest = pathlib.Path(sys.argv[sys.argv.index('--dir') + 1])
        dest.mkdir(parents=True, exist_ok=False)
        (dest / 'downloaded').write_text(sys.argv[sys.argv.index('--name') + 1])
else: raise AssertionError(name)
'''


class HandoffTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = {'architecture': 'arm64', 'revision': 'a' * 40,
                       'xcodes': {},
                       'runtimes': [{'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-2',
                                     'version': '26.2', 'buildversion': '23C54', 'isAvailable': True}],
                       'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-26-2': [
                           {'name': 'iPhone 16', 'udid': 'producer-device', 'isAvailable': True}]},
                       'pages': [{'artifacts': []}]}
        self.add_xcode('Xcode_26.3.app', 'Xcode 26.3\nBuild version 17C1')
        self.add_xcode('Xcode_26.4.app', 'Xcode 26.4\nBuild version 17D2')
        (self.root / 'bin').mkdir()
        (self.root / 'scripts').mkdir()
        for name in ('uname', 'git', 'find', 'xcode-select', 'xcodebuild', 'xcrun', 'gh'):
            self.stub(self.root / 'bin' / name)
        self.stub(self.root / 'scripts/xcodebuild.sh')
        self.env = dict(os.environ, PATH=str(self.root / 'bin') + os.pathsep + os.environ['PATH'],
                        PLATFORM_FIXTURE=str(self.root / 'platform.json'), CALLS=str(self.root / 'calls.jsonl'),
                        GITHUB_ENV=str(self.root / 'env'), GITHUB_OUTPUT=str(self.root / 'outputs'),
                        GITHUB_RUN_ID='900', GITHUB_RUN_ATTEMPT='1', GITHUB_REPOSITORY='intent-hq/ios',
                        GITHUB_SHA='c' * 40, UI_TEST_SHARD_COUNT='6')

    def stub(self, path):
        path.write_text(STUB)
        path.chmod(0o755)

    def add_xcode(self, name, version, executable=True):
        bundle = self.root / name
        self.config['xcodes'][str(bundle)] = version
        if executable:
            tool = bundle / 'Contents/Developer/usr/bin/xcodebuild'
            tool.parent.mkdir(parents=True)
            self.stub(tool)
        return bundle

    def run_helper(self, command, expected=0, message=None):
        Path(self.env['PLATFORM_FIXTURE']).write_text(json.dumps(self.config))
        completed = subprocess.run([sys.executable, str(HELPER), command], cwd=self.root, env=self.env,
                                   capture_output=True, text=True, check=False)
        self.assertEqual(completed.returncode, expected, completed.stderr)
        if message:
            self.assertIn(message, completed.stderr)
        return self.outputs()

    def outputs(self):
        path = Path(self.env['GITHUB_OUTPUT'])
        return dict(line.split('=', 1) for line in path.read_text().splitlines()) if path.exists() else {}

    def prepare_consumer(self):
        producer = self.run_helper('configure')
        self.env.update(TEST_ARTIFACT_RUN=producer['run'], TEST_ARTIFACT_REVISION=producer['revision'],
                        TEST_ARTIFACT_SHA256='b' * 64, TEST_BUILD_CONTEXT=producer['context'])
        return producer

    def test_configure_uses_checkout_revision_and_one_validated_count(self):
        for count in ('1', '2', '6'):
            self.env['UI_TEST_SHARD_COUNT'] = count
            result = self.run_helper('configure')
            self.assertEqual(result['revision'], 'a' * 40)
            self.assertEqual(result['run'], '900-1')
            self.assertEqual(result['artifact'], 'ios-test-build-900-1')
            self.assertEqual(result['count'], count)
            self.assertEqual(json.loads(result['matrix']), list(range(1, int(count) + 1)))
        for count in ('', '0', '06', '-1', '6.0', '257'):
            self.env['UI_TEST_SHARD_COUNT'] = count
            self.run_helper('configure', 1, 'shard count')

    def test_consumer_selects_exact_version_not_newest_or_default(self):
        self.prepare_consumer()
        self.add_xcode('Xcode_27.app', 'Xcode 27.0\nBuild version 18A1')
        self.config['devices'][self.config['runtimes'][0]['identifier']][0]['udid'] = 'consumer-device'
        self.env['GITHUB_RUN_ATTEMPT'] = '2'
        self.run_helper('consume')
        selected = dict(line.split('=', 1) for line in Path(self.env['GITHUB_ENV']).read_text().splitlines())
        self.assertEqual(selected['SIM_UDID'], 'consumer-device')
        self.assertEqual(selected['DEVELOPER_DIR'], str(self.root / 'Xcode_26.4.app/Contents/Developer'))
        self.config['xcodes'][str(self.root / 'Xcode_26.4.app')] = 'Xcode 26.4\nBuild version 17D3'
        self.run_helper('consume', 1, 'Xcode version/build')

    def test_discovery_ignores_unusable_bundles_but_requires_a_compatible_toolchain(self):
        self.add_xcode('Xcodes.app', 'manager, not Xcode', executable=False)
        self.add_xcode('Xcode-not-an-ide.app', 'not an Xcode version')
        self.add_xcode('Xcode-broken.app', 'broken')
        producer = self.prepare_consumer()
        self.assertEqual(json.loads(producer['context'])['xcode'], 'Xcode 26.4\nBuild version 17D2')
        self.run_helper('consume')
        for name in ('Xcode_26.3.app', 'Xcode_26.4.app'):
            (self.root / name / 'Contents/Developer/usr/bin/xcodebuild').unlink()
        self.run_helper('consume', 1, 'Xcode version/build')
        self.run_helper('configure', 1, 'Xcode version/build')

    def test_consumer_rejects_identity_architecture_and_runtime_drift(self):
        self.prepare_consumer()
        original = copy.deepcopy(self.config)
        for field, value in (('architecture', 'x86_64'), ('revision', 'd' * 40)):
            self.config[field] = value
            self.run_helper('consume', 1)
            self.config = copy.deepcopy(original)
        for field, value in (('identifier', 'com.apple.CoreSimulator.SimRuntime.iOS-26-3'),
                             ('version', '26.3'), ('buildversion', '23C55'), ('isAvailable', False)):
            self.config['runtimes'][0][field] = value
            self.run_helper('consume', 1)
            self.config = copy.deepcopy(original)
        for run in ('899-1', '900-2', '', '../900-1'):
            self.env['TEST_ARTIFACT_RUN'] = run
            self.run_helper('consume', 1, 'producer run')

    def test_publish_outputs_and_smoke_download_integrity(self):
        self.prepare_consumer()
        archive = self.root / 'artifact/tests.tar.gz'
        archive.parent.mkdir()
        archive.write_bytes(b'fixture product bytes')
        echo = self.root / 'TailcatKit/build/tcecho'
        echo.parent.mkdir(parents=True)
        echo.write_bytes(b'fixture executable bytes')
        receipt = dict(json.loads(self.env['TEST_BUILD_CONTEXT']), schema=1, architecture='arm64',
                       run='900-1', revision='a' * 40, sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                       bytes=archive.stat().st_size)
        Path(str(archive) + '.json').write_text(json.dumps(receipt))
        self.env['TEST_ARTIFACT_PATH'] = str(archive)
        trusted = self.run_helper('publish')
        self.assertEqual(trusted['sha256'], receipt['sha256'])
        self.assertEqual(trusted['echo_sha256'], hashlib.sha256(echo.read_bytes()).hexdigest())
        self.env['TEST_ECHO_SHA256'] = trusted['echo_sha256']
        self.run_helper('verify-echo')
        self.assertEqual((archive.parent / 'tcecho').stat().st_mode & 0o777, 0o755)
        (archive.parent / 'tcecho').write_bytes(b'corrupt download')
        self.run_helper('verify-echo', 1, 'checksum')
        archive.write_bytes(b'corrupt producer archive')
        self.run_helper('publish', 1, 'archive changed')
        archive.unlink()
        self.run_helper('publish', 1)

    def test_download_reports_preserves_attempt_directories_and_rejects_missing(self):
        names = ['ios-selection-900-1-unit', 'ios-selection-900-2-unit', 'ios-selection-900-2-shard-6']
        self.config['pages'] = [{'artifacts': [{'name': n, 'expired': False} for n in names[:1]]},
                                {'artifacts': [{'name': n, 'expired': False} for n in names[1:]]}]
        self.env['REPORT_KIND'] = 'all'
        self.run_helper('download-reports')
        self.assertEqual(sorted(p.name for p in (self.root / 'selection-evidence').iterdir()), sorted(names))
        self.config['pages'][0]['artifacts'] += self.config['pages'][0]['artifacts']
        self.run_helper('download-reports', 1, 'duplicate')
        self.config['pages'] = [{'artifacts': [{'name': 'ios-selection-899-1-unit', 'expired': False}]}]
        self.run_helper('download-reports', 1, 'missing')

    def workflow(self):
        return json.loads(subprocess.check_output([
            'ruby', '-ryaml', '-rjson', '-e', 'puts JSON.generate(YAML.load_file(ARGV[0]))',
            str(ROOT / '.github/workflows/ci.yml')], text=True))

    def test_workflow_unit_filtered_and_source_unavailable_commands(self):
        self.prepare_consumer()
        steps = self.workflow()['jobs']['ios-unit-tests']['steps']
        tests = [s for s in steps if 'TEST_SELECTION_REPORT' in s.get('env', {})]
        self.assertEqual(len(tests), 2)
        for selection, command in (('', 'test-without-building-unit'),
                                   ('IntentUITests/Example/test()', 'test-without-building')):
            completed = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', tests[0]['run']],
                                       cwd=self.root, env=dict(self.env, ONLY_TESTING=selection),
                                       capture_output=True, text=True)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            call = json.loads(Path(self.env['CALLS']).read_text().splitlines()[-1])
            self.assertEqual(call[1], [command])
            self.assertEqual(call[2]['ONLY_TESTING'], selection or 'IntentTests')
            self.assertEqual(call[2]['TEST_ARTIFACT_RUN'], '900-1')
        for name in ('Intent', 'IntentTests'):
            (self.root / name).mkdir()
            (self.root / name / 'owned-input').write_text('must be restored')
        (self.root / 'Info-visionOS.plist').write_text('must be restored')
        run_temp = self.root / 'runner-temp'
        run_temp.mkdir()
        for outcome in (0, 65):
            self.config['wrapper_exit'] = outcome
            Path(self.env['PLATFORM_FIXTURE']).write_text(json.dumps(self.config))
            completed = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', tests[1]['run']], cwd=self.root,
                                       env=dict(self.env, RUNNER_TEMP=str(run_temp), CHECK_SOURCE_UNAVAILABLE='1',
                                                ONLY_TESTING=tests[1]['env']['ONLY_TESTING']), capture_output=True, text=True)
            self.assertEqual(completed.returncode, outcome, completed.stderr)
            for name in ('Intent', 'IntentTests'):
                self.assertEqual((self.root / name / 'owned-input').read_text(), 'must be restored')
            self.assertEqual((self.root / 'Info-visionOS.plist').read_text(), 'must be restored')
        call = json.loads(Path(self.env['CALLS']).read_text().splitlines()[-1])
        self.assertEqual(call[1], ['test-without-building'])
        self.assertEqual(set(call[2]['ONLY_TESTING'].split()), {'IntentTests/' + s for s in
                         ('InfoPlistSyncTests', 'PlatformGuardAllowlistTests', 'ObjCCallbackIsolationTests',
                          'ExternalLinkTests', 'PrivacyManifestDriftTests')})

    def test_workflow_fanout_gates_and_filtered_names(self):
        jobs = self.workflow()['jobs']
        for name in ('ios-test-build', 'go-test', 'swiftlint', 'visionos-build'):
            self.assertFalse(jobs[name].get('needs'), name)
        for name in ('ios-unit-tests', 'ios-ui-test-shards'):
            self.assertEqual(jobs[name]['needs'], 'ios-test-build')
        self.assertEqual(set(jobs['build-and-test']['needs']),
                         {'ios-test-build', 'ios-unit-tests', 'go-test', 'swiftlint'})
        self.assertEqual(set(jobs['ios-ui-tests']['needs']),
                         {'ios-test-build', 'ios-unit-tests', 'ios-ui-test-shards'})
        # Evaluate the workflow's small boolean admission/name expressions for
        # normal and filtered events; no successful-dependency default may skip a gate.
        for event, selection, full in (('pull_request', '', True), ('workflow_dispatch', '', True),
                                       ('workflow_dispatch', 'IntentTests', False)):
            def evaluate(expression):
                if not expression.startswith('${{'):
                    return expression
                expression = expression[3:-2].replace('always()', 'True')
                expression = expression.replace('github.event_name', repr(event)).replace('inputs.only_testing', repr(selection))
                expression = expression.replace('&&', ' and ').replace('||', ' or ').replace('!(', 'not (')
                return eval(expression, {'__builtins__': {}}, {})
            self.assertTrue(evaluate(jobs['build-and-test']['if']))
            self.assertEqual(evaluate(jobs['ios-ui-tests']['if']), full)
            self.assertEqual(evaluate(jobs['ios-ui-test-shards']['if']), full)
            self.assertEqual(evaluate(jobs['build-and-test']['name']),
                             'iOS Build & Test' if full else 'iOS Filtered Tests (non-gating)')
            self.assertEqual(evaluate(jobs['ios-ui-tests']['name']),
                             'iOS UI Tests' if full else 'iOS UI Tests (non-gating)')


if __name__ == '__main__':
    unittest.main()