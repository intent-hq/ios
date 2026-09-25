#!/usr/bin/env python3
"""Executable archive boundary and wrapper handoff tests; no Xcode required."""
import copy
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'scripts/test-build-artifact.py'
WRAPPER = ROOT / 'scripts/xcodebuild.sh'
APPS = ('Intent.app', 'IntentUITests-Runner.app')
STUB = '''#!/usr/bin/env python3
import fcntl, json, os, pathlib, shutil, sys, time
name = pathlib.Path(sys.argv[0]).name
a = sys.argv[1:]
if name == 'uname': print(os.environ.get('FAKE_ARCH', 'arm64'))
elif name == 'git': print('a' * 40)
elif name == 'xcrun':
    if a[0] == 'lipo': print(os.environ.get('FAKE_BINARY_ARCH', 'arm64'))
    elif a[:3] == ['simctl', 'list', 'devices']:
        print(json.dumps({'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-26-2': [{'udid': 'device', 'isAvailable': True}]}}))
    elif a[:3] == ['simctl', 'list', 'runtimes']:
        print(json.dumps({'runtimes': [{'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-2', 'version': '26.2', 'buildversion': os.environ.get('FAKE_RUNTIME', '23C54'), 'isAvailable': True}]}))
    elif a[0] == 'xcresulttool':
        tests = ['testA()', 'testB()'] if os.environ.get('ONLY_TESTING') == 'IntentTests/FooTests' else ['testA()']
        print(json.dumps({'testNodes': [{'name': 'IntentTests', 'nodeType': 'Unit test bundle', 'children': [
          {'nodeType': 'Test Case', 'nodeIdentifier': 'FooTests/' + t, 'result': 'Passed'} for t in tests]}]}))
elif name == 'xcodebuild':
    if a == ['-version']: print(os.environ.get('FAKE_XCODE', 'Xcode 26.3\\nBuild version 17C529'))
    else:
        with open(os.environ['CALLS'], 'a') as f: f.write(json.dumps(a) + '\\n')
        if a[0] == 'build-for-testing':
            if os.environ.get('FAKE_BUILD_FAIL'): sys.exit(65)
            dest = pathlib.Path(a[a.index('-derivedDataPath') + 1]) / 'Build/Products'
            shutil.copytree(os.environ['PRODUCT_FIXTURE'], dest)
        elif '-enumerate-tests' in a:
            if os.environ.get('PRODUCER_DISCOVERY_PROBE') == '1':
                with open(pathlib.Path(os.environ['SIM_LOCK_DIR']) / 'xcodebuild-sim-device.lock') as lock:
                    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError: pass
                    else: sys.exit(99)
                assert pathlib.Path(os.environ['TEST_ARTIFACT_PATH'] + '.json').is_file()
                if os.environ.get('FAKE_ENUMERATE_HOLD'):
                    pathlib.Path(os.environ['FAKE_ENUMERATE_HOLD']).write_text(str(os.getpid()))
                    time.sleep(10)
            if os.environ.get('FAKE_ENUMERATE_FAIL', '0') != '0':
                print('private probe output must not appear')
                print('private probe error must not appear', file=sys.stderr)
                sys.exit(int(os.environ['FAKE_ENUMERATE_FAIL']))
            tests = ['IntentTests/FooTests/testA()', 'IntentTests/FooTests/testB()']
            tests += ['IntentUITests/UITests/test%d()' % n for n in range(12)]
            pathlib.Path(a[a.index('-test-enumeration-output-path') + 1]).write_text(json.dumps({'errors': [], 'values': [{'enabledTests': [{'identifier': t} for t in tests], 'disabledTests': []}]}))
        else:
            if '-resultBundlePath' in a: pathlib.Path(a[a.index('-resultBundlePath') + 1]).mkdir()
            state = pathlib.Path(os.environ['CALLS'] + '.crash')
            if os.environ.get('FAKE_CRASH') and not state.exists():
                state.touch()
                print('Restarting after unexpected exit, crash, or test timeout in IntentTests.FooTests/testA(); summary will include totals from previous launches.')
                sys.exit(65)
            print('** TEST EXECUTE SUCCEEDED **')
'''


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.products = self.work / 'producer/Build/Products'
        self.archive = self.work / 'transfer/tests.tar.gz'
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        for name in ('uname', 'git', 'xcrun', 'xcodebuild'):
            tool = self.bin / name
            tool.write_text(STUB)
            tool.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        SIM_UDID='device', SIM_LOCK_DIR=str(self.work / 'locks'), TMPDIR=str(self.work),
                        TEST_ARTIFACT_RUN='123-1', TEST_ARTIFACT_REVISION='a' * 40,
                        TEST_ARTIFACT_PATH=str(self.archive), CALLS=str(self.work / 'calls'),
                        PRODUCT_FIXTURE=str(self.products))
        for key in ('ONLY_TESTING', 'UI_TEST_SHARD', 'UI_TEST_SHARD_COUNT', 'RESULT_BUNDLE', 'BUILD_CONFIGURATION',
                    'GITHUB_STEP_SUMMARY', 'TEST_SELECTION_REPORT', 'TEST_ARTIFACT_SHA256',
                    'CI_PHASE_TIMING', 'PRODUCER_DISCOVERY_PROBE'):
            self.env.pop(key, None)
        targets = []
        for app, target in zip(APPS, ('IntentTests', 'IntentUITests')):
            root = self.products / 'Debug-iphonesimulator' / app
            bundle = root / 'PlugIns' / (target + '.xctest')
            bundle.mkdir(parents=True)
            for product in (root, bundle):
                (product / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'executable'}))
                (product / 'executable').write_bytes(b'fixture executable')
                (product / 'executable').chmod(0o755)
            item = {'BlueprintName': target, 'TestHostPath': '__TESTROOT__/Debug-iphonesimulator/' + app,
                    'TestBundlePath': '__TESTHOST__/PlugIns/' + target + '.xctest'}
            if target == 'IntentUITests':
                item['UITargetAppPath'] = '__TESTROOT__/Debug-iphonesimulator/Intent.app'
                item['UITargetAppEnvironmentVariables'] = {
                    'DYLD_FRAMEWORK_PATH': '__TESTROOT__/Debug-iphonesimulator',
                    'XCODE_SCHEME_NAME': 'Intent', 'APP_DISTRIBUTOR_ID_OVERRIDE': 'com.apple.AppStore'}
            targets.append(item)
        self.source = self.products / 'Debug-iphonesimulator/Intent.app/PlugIns/IntentTests.xctest/TestSourceInputs'
        (self.source / 'Intent').mkdir(parents=True)
        (self.source / 'IntentTests').mkdir()
        (self.source / 'Info-visionOS.plist').write_bytes(b'bundled source fixture')
        self.link = self.products / 'Debug-iphonesimulator/Intent.app/executable-link'
        self.link.symlink_to('executable')
        self.runfile = self.products / 'Intent_generated.xctestrun'
        self.description = {'__xctestrun_metadata__': {'FormatVersion': 2},
                            'TestConfigurations': [{'IsEnabled': True, 'TestTargets': targets}]}
        self.runfile.write_bytes(plistlib.dumps(self.description))

    def call(self, args, expected=0, **env):
        result = subprocess.run(args, env=dict(self.env, **env), cwd=ROOT, text=True, capture_output=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def pack(self):
        self.call([sys.executable, str(HELPER), 'pack', str(self.products), str(self.archive), 'device'])
        self.env['TEST_ARTIFACT_SHA256'] = hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def restore(self, expected=0, **env):
        dest = Path(tempfile.mkdtemp(dir=self.work))
        result = self.call([sys.executable, str(HELPER), 'restore', str(self.archive), str(dest), 'device'], expected, **env)
        return dest, result

    def calls(self):
        path = self.work / 'calls'
        return [json.loads(row) for row in path.read_text().splitlines()] if path.exists() else []

    def test_roundtrip_contains_only_products_preserves_sources_modes_and_links(self):
        (self.products / 'unrelated-config').write_text('not an artifact input')
        self.pack()
        receipt = json.loads(Path(str(self.archive) + '.json').read_text())
        self.assertEqual(receipt['sha256'], self.env['TEST_ARTIFACT_SHA256'])
        shutil.move(self.products.parent.parent, self.work / 'unavailable-producer')
        dest, _ = self.restore()
        link = dest / 'Debug-iphonesimulator/Intent.app/executable-link'
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), 'executable')
        self.assertEqual(link.stat().st_mode & 0o777, 0o755)
        self.assertEqual((dest / self.source.relative_to(self.products) / 'Info-visionOS.plist').read_bytes(), b'bundled source fixture')
        self.assertFalse((dest / 'unrelated-config').exists())

    def test_trusted_identity_toolchain_runtime_arch_and_checksum_fail_closed(self):
        self.pack()
        for changes, reason in [({'TEST_ARTIFACT_RUN': '124-1'}, 'mismatch'),
                                ({'TEST_ARTIFACT_REVISION': 'b' * 40}, 'checkout revision'),
                                ({'TEST_ARTIFACT_SHA256': ''}, 'trusted producer'),
                                ({'TEST_ARTIFACT_SHA256': '0' * 64}, 'checksum mismatch'),
                                ({'FAKE_XCODE': 'Xcode different'}, 'mismatch'),
                                ({'FAKE_ARCH': 'x86_64'}, 'arm64 host'),
                                ({'FAKE_BINARY_ARCH': 'x86_64'}, 'not arm64'),
                                ({'FAKE_RUNTIME': 'different-build'}, 'mismatch')]:
            with self.subTest(changes=changes):
                _, result = self.restore(1, **changes)
                self.assertIn(reason, result.stderr)

    def test_producer_rejects_unportable_products_and_launch_secrets(self):
        for change, reason in [('source', 'TestSourceInputs'), ('environment', 'test environment'),
                               ('path', 'test host path'), ('package', 'package frameworks'),
                               ('link', 'symlink'), ('mode', 'executable mode')]:
            with self.subTest(change=change):
                description = copy.deepcopy(self.description)
                if change == 'source': (self.source / 'Info-visionOS.plist').rename(self.work / 'source-input')
                if change == 'environment': description['TestConfigurations'][0]['TestTargets'][0]['EnvironmentVariables'] = {'UNEXPECTED_VALUE': 'fixture'}
                if change == 'path': description['TestConfigurations'][0]['TestTargets'][0]['TestHostPath'] = '/old/host.app'
                package = self.products / 'Debug-iphonesimulator/PackageFrameworks/new.framework'
                if change == 'package': package.mkdir(parents=True)
                if change == 'link': self.link.unlink(); self.link.symlink_to('/outside')
                executable = self.link.parent / 'executable'
                if change == 'mode': executable.chmod(0o644)
                self.runfile.write_bytes(plistlib.dumps(description))
                result = self.call([sys.executable, str(HELPER), 'pack', str(self.products), str(self.archive), 'device'], 1)
                self.assertIn(reason, result.stderr)
                self.assertFalse(self.archive.exists())
                self.runfile.write_bytes(plistlib.dumps(self.description))
                if change == 'source': (self.work / 'source-input').rename(self.source / 'Info-visionOS.plist')
                if change == 'package': package.rmdir()
                if change == 'link': self.link.unlink(); self.link.symlink_to('executable')
                executable.chmod(0o755)

    def test_tampered_archive_members_rejected_even_with_matching_digest(self):
        self.pack()
        original = self.archive.read_bytes()
        for name, link, kind, reason in [('../escape', '', tarfile.REGTYPE, 'unsafe'),
                                       ('credentials', '', tarfile.REGTYPE, 'boundary'),
                                       ('Debug-iphonesimulator/Intent.app/.env', '', tarfile.REGTYPE, 'credential'),
                                       ('Debug-iphonesimulator/Intent.app/escape', '/outside', tarfile.SYMTYPE, 'symlink'),
                                       ('Debug-iphonesimulator/Intent.app/device', '', tarfile.FIFOTYPE, 'type'),
                                       ('manifest.json', '', tarfile.REGTYPE, 'duplicate')]:
            with self.subTest(name=name):
                with tarfile.open(fileobj=io.BytesIO(original), mode='r:gz') as source, tarfile.open(self.archive, 'w:gz') as sink:
                    for member in source.getmembers(): sink.addfile(member, source.extractfile(member) if member.isfile() else None)
                    member = tarfile.TarInfo(name); member.type = kind; member.linkname = link
                    sink.addfile(member, io.BytesIO())
                self.env['TEST_ARTIFACT_SHA256'] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
                _, result = self.restore(1)
                self.assertIn(reason, result.stderr)

    def test_missing_or_modified_download_rejected_before_tool_execution(self):
        self.pack()
        original = self.archive.read_bytes()
        self.archive.write_bytes(original + b'transport corruption')
        _, result = self.restore(1)
        self.assertIn('checksum mismatch', result.stderr)
        self.archive.rename(self.work / 'download-not-found')
        _, result = self.restore(1)
        self.assertIn('No such file', result.stderr)
        self.assertEqual(self.calls(), [])

    def test_wrapper_fresh_producer_and_relocated_unit_enumeration_run_retry(self):
        result = self.call(['bash', str(WRAPPER), 'build-test-artifact'], SPM_CLONE_DIR='shared-packages')
        self.assertNotIn('ci-phase', result.stderr)
        self.assertEqual(len(self.calls()), 1)  # Default-off: no producer enumeration.
        build = self.calls()[0]
        self.assertEqual(build[0], 'build-for-testing')
        self.assertIn('ARCHS=arm64', build)
        self.assertNotEqual(build[build.index('-derivedDataPath') + 1], str(self.products.parent.parent))
        self.env['TEST_ARTIFACT_SHA256'] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        shutil.move(self.products.parent.parent, self.work / 'unavailable-producer')
        report = self.work / 'selection.json'
        self.call(['bash', str(WRAPPER), 'test-without-building-unit'], ONLY_TESTING='IntentTests/FooTests',
                  TEST_SELECTION_REPORT=str(report), SPM_CLONE_DIR='must-not-be-used', FAKE_CRASH='1')
        calls = self.calls()[1:]
        self.assertEqual(len(calls), 3)
        runfiles = []
        for args in calls:
            self.assertEqual(args[0], 'test-without-building')
            self.assertIn('-skip-testing:IntentUITests', args)
            self.assertNotIn('-project', args); self.assertNotIn('-scheme', args)
            self.assertNotIn('-clonedSourcePackagesDirPath', args)
            self.assertIn('-disableAutomaticPackageResolution', args)
            runfiles.append(args[args.index('-xctestrun') + 1])
        self.assertEqual(len(set(runfiles)), 1)
        self.assertTrue(Path(runfiles[0]).is_file())
        self.assertIn('-enumerate-tests', calls[0])
        self.assertIn('-only-testing:IntentTests/FooTests', calls[2])
        proof = json.loads(report.read_text())
        self.assertEqual(proof['selectors'], ['IntentTests/FooTests'])
        self.assertEqual(proof['artifact_sha256'], self.env['TEST_ARTIFACT_SHA256'])

    def markers(self, result):
        self.assertNotIn('ci-phase', result.stdout)
        rows = [line for line in result.stderr.splitlines() if line.startswith('ci-phase')]
        for line in rows:
            self.assertRegex(line, r'^ci-phase phase=(artifact_context|artifact_products_validate|artifact_pack_total|'
                             r'artifact_restore_total|artifact_extract|producer_build|producer_discovery_probe_total|'
                             r'simulator_readiness|consumer_discovery|test_process|result_verification) '
                             r'outcome=(success|failure|cancelled) elapsed_seconds=[0-9]+\.[0-9]{6}$')
        return {line.split()[1].split('=')[1]: line.split()[2].split('=')[1] for line in rows}

    def test_artifact_timings_preserve_receipt_runfile_stdout_and_validation_failure(self):
        self.env['CI_PHASE_TIMING'] = '1'
        result = self.call([sys.executable, str(HELPER), 'pack', str(self.products), str(self.archive), 'device'])
        self.assertEqual(json.loads(result.stdout), json.loads(Path(str(self.archive) + '.json').read_text()))
        self.assertEqual(self.markers(result), dict.fromkeys(
            ('artifact_context', 'artifact_products_validate', 'artifact_pack_total'), 'success'))
        self.env['TEST_ARTIFACT_SHA256'] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        dest, result = self.restore()
        self.assertEqual(result.stdout, str(dest / 'Intent.xctestrun') + '\n')
        self.assertEqual(self.markers(result), dict.fromkeys(
            ('artifact_context', 'artifact_extract', 'artifact_products_validate', 'artifact_restore_total'), 'success'))
        _, result = self.restore(1, TEST_ARTIFACT_SHA256='0' * 64)
        self.assertEqual(self.markers(result), {'artifact_restore_total': 'failure'})

    def test_probe_is_separate_non_gating_and_never_replaces_consumer_discovery(self):
        for failure in ('0', '70', '143'):
            with self.subTest(failure=failure):
                archive = self.work / ('probe-' + failure + '.tar.gz')
                result = self.call(['bash', str(WRAPPER), 'build-test-artifact'], 143 if failure == '143' else 0,
                                   TEST_ARTIFACT_PATH=str(archive), PRODUCER_DISCOVERY_PROBE='1',
                                   FAKE_ENUMERATE_FAIL=failure, SPM_CLONE_DIR='must-not-reach-probe')
                self.assertEqual(self.markers(result), {'producer_discovery_probe_total':
                                 'success' if failure == '0' else 'cancelled' if failure == '143' else 'failure'})
                self.assertNotIn('private probe', result.stdout + result.stderr)
                build, probe = self.calls()[-2:]
                self.assertEqual(build[0], 'build-for-testing')
                self.assertEqual(probe[0], 'test-without-building')
                self.assertIn('-enumerate-tests', probe)
                self.assertIn('-disableAutomaticPackageResolution', probe)
                self.assertIn('-skipPackageUpdates', probe)
                self.assertNotIn('-project', probe); self.assertNotIn('-scheme', probe)
                self.assertNotIn('-clonedSourcePackagesDirPath', probe)
                fresh = Path(build[build.index('-derivedDataPath') + 1]) / 'Build/Products/Intent_generated.xctestrun'
                self.assertEqual(Path(probe[probe.index('-xctestrun') + 1]), fresh)
                self.assertFalse(list(self.work.glob('xcodebuild-probe.*')))
                before = archive.read_bytes(), Path(str(archive) + '.json').read_bytes()
                self.call(['bash', str(WRAPPER), 'test-without-building-unit'], TEST_ARTIFACT_PATH=str(archive),
                          TEST_ARTIFACT_SHA256=hashlib.sha256(before[0]).hexdigest(), ONLY_TESTING='IntentTests/FooTests')
                self.assertIn('-enumerate-tests', self.calls()[-2])
                self.assertNotIn('-enumerate-tests', self.calls()[-1])
                self.assertEqual(before, (archive.read_bytes(), Path(str(archive) + '.json').read_bytes()))

    def test_phase_timing_alone_never_enables_producer_discovery(self):
        result = self.call(['bash', str(WRAPPER), 'build-test-artifact'], CI_PHASE_TIMING='1')
        self.assertEqual(self.markers(result), dict.fromkeys(
            ('artifact_context', 'producer_build', 'artifact_products_validate', 'artifact_pack_total'), 'success'))
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.calls()[0][0], 'build-for-testing')
        self.assertTrue(self.archive.is_file())

    def test_probe_never_suppresses_build_or_pack_failures(self):
        for env, code, failed_phase in [({'FAKE_BUILD_FAIL': '1'}, 65, 'producer_build'),
                                        ({'FAKE_BINARY_ARCH': 'x86_64'}, 1, 'artifact_pack_total')]:
            with self.subTest(env=env):
                result = self.call(['bash', str(WRAPPER), 'build-test-artifact'], code,
                                   CI_PHASE_TIMING='1', PRODUCER_DISCOVERY_PROBE='1', **env)
                self.assertEqual(self.markers(result)[failed_phase], 'failure')
                self.assertNotIn('producer_discovery_probe_total', self.markers(result))
                self.assertFalse(self.archive.exists())
                self.assertTrue(all(args[0] == 'build-for-testing' for args in self.calls()))

    def test_probe_lock_timeout_is_non_gating_and_does_not_enumerate(self):
        lock = Path(self.env['SIM_LOCK_DIR']) / 'xcodebuild-sim-device.lock'
        lock.parent.mkdir()
        with lock.open('w') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.call(['bash', str(WRAPPER), 'build-test-artifact'], PRODUCER_DISCOVERY_PROBE='1', SIM_LOCK_TIMEOUT='0')
            self.assertEqual(self.markers(result), {'producer_discovery_probe_total': 'failure'})
            self.assertEqual(len(self.calls()), 1)
            self.assertTrue(self.archive.is_file())

    def test_probe_parent_cancellation_and_orphan_cleanup(self):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            with self.subTest(signal=sig):
                ready = self.work / ('ready-' + str(sig))
                archive = self.work / ('cancel-' + str(sig) + '.tar.gz')
                env = dict(self.env, PRODUCER_DISCOVERY_PROBE='1', SIM_LOCK_KILL_GRACE='0',
                           TEST_ARTIFACT_PATH=str(archive), FAKE_ENUMERATE_HOLD=str(ready))
                with subprocess.Popen(['bash', str(WRAPPER), 'build-test-artifact'], cwd=ROOT, env=env,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
                    deadline = time.monotonic() + 10
                    while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertTrue(ready.exists(), 'probe did not reach enumeration')
                    process.send_signal(sig)
                    # Bash defers TERM while its foreground pipeline is running, as
                    # on ordinary test runs. Let the stub finish to deliver the trap.
                    if sig == signal.SIGTERM:
                        os.kill(int(ready.read_text()), signal.SIGTERM)
                    stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 143 if sig == signal.SIGTERM else -signal.SIGKILL)
                if sig == signal.SIGTERM:
                    self.assertIn('outcome=cancelled', stderr)
                self.assertTrue(archive.is_file())
                lock = Path(self.env['SIM_LOCK_DIR']) / 'xcodebuild-sim-device.lock'
                with lock.open() as stream:
                    deadline = time.monotonic() + 5
                    while True:
                        try:
                            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                            break
                        except BlockingIOError:
                            self.assertLess(time.monotonic(), deadline, 'orphan retained simulator lock')
                            time.sleep(0.02)

    def test_wrapper_debug_artifacts_cannot_be_used_as_release_evidence(self):
        self.pack()
        for command in ('build-test-artifact', 'test-without-building', 'test-without-building-unit'):
            with self.subTest(command=command):
                archive = self.work / 'release-output.tar.gz' if command == 'build-test-artifact' else self.archive
                result = self.call(['bash', str(WRAPPER), command], 1, BUILD_CONFIGURATION='Release',
                                   TEST_ARTIFACT_PATH=str(archive), ONLY_TESTING='IntentTests/FooTests')
                self.assertIn('test artifacts support only Debug', result.stderr)
                self.assertEqual(self.calls(), [])
        self.assertFalse((self.work / 'release-output.tar.gz').exists())
        self.call(['bash', str(WRAPPER), 'test-without-building-unit'], BUILD_CONFIGURATION='Debug',
                  ONLY_TESTING='IntentTests/FooTests', SPM_CLONE_DIR='must-not-be-used')
        self.assertEqual(len(self.calls()), 2)
        for args in self.calls():
            self.assertEqual(args[args.index('-configuration') + 1], 'Debug')
            self.assertNotIn('-clonedSourcePackagesDirPath', args)
            self.assertNotIn('ENABLE_TESTABILITY=YES', args)

    def test_wrapper_invalid_artifact_never_enumerates_builds_or_tests(self):
        self.pack()
        self.call(['bash', str(WRAPPER), 'test-without-building'], 1, TEST_ARTIFACT_RUN='wrong')
        self.assertEqual(self.calls(), [])
        for command in ('test-ios', 'test-ios-unit', 'build-for-testing', 'resolve'):
            self.call(['bash', str(WRAPPER), command], 1)
        self.assertEqual(self.calls(), [])


if __name__ == '__main__':
    unittest.main()