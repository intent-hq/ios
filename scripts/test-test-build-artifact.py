#!/usr/bin/env python3
"""Executable archive boundary and wrapper handoff tests; no Xcode required."""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'scripts/test-build-artifact.py'
WRAPPER = ROOT / 'scripts/xcodebuild.sh'
APPS = ('Intent.app', 'IntentUITests-Runner.app')
STUB = '''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
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
            dest = pathlib.Path(a[a.index('-derivedDataPath') + 1]) / 'Build/Products'
            shutil.copytree(os.environ['PRODUCT_FIXTURE'], dest)
        elif '-enumerate-tests' in a:
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
                    'GITHUB_STEP_SUMMARY', 'TEST_SELECTION_REPORT', 'TEST_ARTIFACT_SHA256'):
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
        self.call(['bash', str(WRAPPER), 'build-test-artifact'], SPM_CLONE_DIR='shared-packages')
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