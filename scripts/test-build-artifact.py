#!/usr/bin/env python3
"""Private helper for xcodebuild.sh's same-run build/test handoff (stdlib only).

The workflow must transport PATH and PATH.json from the producer and supply the
receipt's sha256 via a trusted job output, NOT read the expected digest from the
download. RUN should include the Actions run ID and attempt; REVISION is the
checked-out commit (the PR merge revision, not necessarily the head SHA).
"""

import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
from ci_phase import phase

PRODUCTS = 'Debug-iphonesimulator'
APPS = ('Intent.app', 'IntentUITests-Runner.app')
RUNFILE = 'Intent.xctestrun'
MANIFEST = 'manifest.json'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    value = hashlib.sha256()
    with open(path, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def identity():
    run = os.environ.get('TEST_ARTIFACT_RUN', '')
    revision = os.environ.get('TEST_ARTIFACT_REVISION', '')
    require(re.fullmatch(r'[A-Za-z0-9_.-]{1,120}', run), 'TEST_ARTIFACT_RUN is required (run ID plus attempt)')
    require(re.fullmatch(r'[0-9a-f]{40}', revision), 'TEST_ARTIFACT_REVISION must be a full commit SHA')
    require(output('git', 'rev-parse', 'HEAD') == revision, 'checkout revision does not match TEST_ARTIFACT_REVISION')
    return {'run': run, 'revision': revision}


@phase('artifact_context')
def context(udid):
    require(output('uname', '-m') == 'arm64', 'shared test builds require an arm64 host')
    devices = json.loads(output('xcrun', 'simctl', 'list', 'devices', 'available', '-j'))['devices']
    matches = [runtime for runtime, rows in devices.items() for row in rows
               if row['udid'] == udid and row.get('isAvailable')]
    require(len(matches) == 1, 'selected simulator is unavailable or ambiguous')
    runtimes = json.loads(output('xcrun', 'simctl', 'list', 'runtimes', '-j'))['runtimes']
    matches = [row for row in runtimes if row['identifier'] == matches[0] and row.get('isAvailable')]
    require(len(matches) == 1 and '.iOS-' in matches[0]['identifier'], 'an available iOS runtime is required')
    runtime = {key: matches[0][key] for key in ('identifier', 'version', 'buildversion')}
    return dict(identity(), schema=1, architecture='arm64', xcode=output('xcodebuild', '-version'), runtime=runtime)


def safe_name(name):
    path = PurePosixPath(name)
    require(name and not path.is_absolute() and '..' not in path.parts and str(path) == name,
            'unsafe archive member path')
    return path


def allowed(name):
    path = safe_name(name)
    return name in (MANIFEST, RUNFILE, PRODUCTS) or any(
        path == PurePosixPath(PRODUCTS, app) or PurePosixPath(PRODUCTS, app) in path.parents for app in APPS)


def check_member(name, mode, link=''):
    require(allowed(name), 'archive contains a file outside the test product boundary')
    require(not mode & 0o7000, 'special permission bits are not allowed')
    parts = PurePosixPath(name).parts
    require(not any(p.startswith('.') or p.lower() in ('credentials', 'credentials.json', 'id_rsa', 'id_ed25519')
                    or p.lower().endswith(('.p12', '.p8', '.pem', '.key', '.mobileprovision')) for p in parts),
            'unexpected hidden or credential file in test products')
    if link:
        require(not PurePosixPath(link).is_absolute(), 'absolute symlink in test products')
        normalized = os.path.normpath(str(PurePosixPath(name).parent / link))
        require(allowed(normalized) and normalized.startswith(PRODUCTS + '/'), 'symlink escapes test products')


def validate_runfile(data):
    require(data.get('__xctestrun_metadata__', {}).get('FormatVersion') == 2, 'unsupported xctestrun format')
    configs = data.get('TestConfigurations', [])
    require(len(configs) == 1 and configs[0].get('IsEnabled'), 'expected one enabled test configuration')
    targets = configs[0]['TestTargets']
    require(sorted(t['BlueprintName'] for t in targets) == ['IntentTests', 'IntentUITests'], 'unexpected test targets')
    expected_env = {
        'APP_DISTRIBUTOR_ID_OVERRIDE': 'com.apple.AppStore', 'IDE_CHOSEN_LOGGING_METHOD': '1',
        'OS_ACTIVITY_DT_MODE': 'YES', 'SQLITE_ENABLE_THREAD_ASSERTIONS': '1', 'TERM': 'dumb',
        'PERFC_ENABLE_EXTENDED_DIAGNOSTIC_FORMAT': '1', 'PERFC_ENABLE_PROFILE_MODE': '1',
        'PERFC_RESET_INSERT_LIBRARIES': '1', 'PERFC_SUPPRESS_SYSTEM_REPORTS': '1',
        'DYLD_INSERT_LIBRARIES': '/usr/lib/libRPAC.dylib',
    }
    testing_keys = {'DYLD_FRAMEWORK_PATH', 'DYLD_LIBRARY_PATH', 'DYLD_INSERT_LIBRARIES',
                    '__XCODE_BUILT_PRODUCTS_DIR_PATHS', '__XPC_DYLD_FRAMEWORK_PATH', '__XPC_DYLD_LIBRARY_PATH'}
    testing_constants = {'XCInjectBundleInto': 'unused', 'XCODE_SCHEME_NAME': 'Intent',
                         'XCODE_TEST_PLAN_NAME': 'Intent', 'PERFC_SUPPRESS_SYSTEM_REPORTS': '1'}
    for target in targets:
        app = APPS[0 if target['BlueprintName'] == 'IntentTests' else 1]
        require(target.get('TestHostPath') == f'__TESTROOT__/{PRODUCTS}/{app}', 'nonportable test host path')
        require(target.get('TestBundlePath') == f"__TESTHOST__/PlugIns/{target['BlueprintName']}.xctest",
                'nonportable test bundle path')
        if app == APPS[1]:
            require(target.get('UITargetAppPath') == f'__TESTROOT__/{PRODUCTS}/{APPS[0]}', 'nonportable UI app path')
        for path in target.get('DependentProductPaths', []):
            require(path.startswith('__TESTROOT__/') and allowed(path.removeprefix('__TESTROOT__/')),
                    'dependency outside test products')
        for key in ('CommandLineArguments', 'UITargetAppCommandLineArguments'):
            require(not target.get(key), 'unexpected test launch arguments; do not package credentials')
        require(all(expected_env.get(k) == v for k, v in target.get('EnvironmentVariables', {}).items()),
                'unexpected test environment; do not package credentials')
        for environment in ('TestingEnvironmentVariables', 'UITargetAppEnvironmentVariables'):
            for key, value in target.get(environment, {}).items():
                if key in testing_constants:
                    require(value == testing_constants[key], 'unexpected testing environment value')
                elif key in expected_env and value == expected_env[key]:
                    continue
                else:
                    require(key in testing_keys and isinstance(value, str), 'unexpected testing environment key')
                    require(all(p.startswith(('__TESTROOT__/', '__TESTHOST__/', '__PLATFORMS__/', '__SIMRUNTIMEROOT__/'))
                                or p == '/usr/lib/libRPAC.dylib' for p in value.split(':')),
                            'nonportable testing environment path')


@phase('artifact_products_validate')
def validate_products(root, runfile=None):
    validate_runfile(plistlib.loads((runfile or root / RUNFILE).read_bytes()))
    for app, target in zip(APPS, ('IntentTests', 'IntentUITests')):
        app_root = root / PRODUCTS / app
        bundle = app_root / 'PlugIns' / (target + '.xctest')
        for product in (app_root, bundle):
            info = plistlib.loads((product / 'Info.plist').read_bytes())
            executable = product / info['CFBundleExecutable']
            require(executable.is_file() and os.access(executable, os.X_OK), 'missing executable or executable mode')
            require(output('xcrun', 'lipo', '-archs', str(executable)) == 'arm64', 'test executable is not arm64 only')
        if target == 'IntentTests':
            source = bundle / 'TestSourceInputs'
            require(all((source / path).exists() for path in ('Intent', 'IntentTests', 'Info-visionOS.plist')),
                    'test bundle is missing TestSourceInputs')


@phase('artifact_pack_total')
def pack(products, archive, udid):
    metadata = context(udid)
    require(not archive.exists() and not Path(str(archive) + '.json').exists(), 'artifact output already exists')
    runfiles = list(products.glob('*.xctestrun'))
    require(len(runfiles) == 1, 'expected exactly one fresh xctestrun')
    runfile = plistlib.loads(runfiles[0].read_bytes())
    validate_runfile(runfile)
    require(not list((products / PRODUCTS / 'PackageFrameworks').glob('*')), 'new package frameworks need an explicit packaging review')
    entries = [(runfiles[0], RUNFILE)]
    for app in APPS:
        root = products / PRODUCTS / app
        require(root.is_dir() and not root.is_symlink(), 'missing test host app')
        entries.append((root, f'{PRODUCTS}/{app}'))
        entries.extend((p, str(p.relative_to(products))) for p in sorted(root.rglob('*')))
    for path, name in entries:
        mode = path.lstat().st_mode
        require(stat.S_ISREG(mode) or stat.S_ISDIR(mode) or stat.S_ISLNK(mode), 'unsupported test product file type')
        check_member(name, stat.S_IMODE(mode), os.readlink(path) if path.is_symlink() else '')
        require(path.resolve().is_relative_to(products.resolve()), 'symlink leaves products directory')
    validate_products(products, runfiles[0])
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, 'x:gz', dereference=False) as tar:
        raw = json.dumps(metadata, sort_keys=True).encode()
        member = tarfile.TarInfo(MANIFEST)
        member.size, member.mode = len(raw), 0o644
        tar.addfile(member, io.BytesIO(raw))
        for path, name in entries:
            member = tar.gettarinfo(str(path), name)
            member.uid = member.gid = 0
            member.uname = member.gname = ''
            with open(path, 'rb') if member.isfile() else io.BytesIO() as stream:
                tar.addfile(member, stream if member.isfile() else None)
    receipt = dict(metadata, sha256=digest(archive), bytes=archive.stat().st_size)
    Path(str(archive) + '.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, sort_keys=True))


@phase('artifact_restore_total')
def restore(archive, destination, udid):
    expected = os.environ.get('TEST_ARTIFACT_SHA256', '')
    require(re.fullmatch(r'[0-9a-f]{64}', expected), 'TEST_ARTIFACT_SHA256 must come from the trusted producer output')
    require(digest(archive) == expected, 'artifact checksum mismatch')
    metadata = context(udid)
    require(destination.is_dir() and not any(destination.iterdir()), 'restore directory must be empty')
    with tarfile.open(archive, 'r:gz') as tar:
        members = tar.getmembers()
        names = {m.name for m in members}
        require(len(names) == len(members), 'duplicate archive member')
        require({MANIFEST, RUNFILE}.issubset(names), 'artifact metadata or xctestrun missing')
        for member in members:
            require(member.isfile() or member.isdir() or member.issym(), 'unsupported archive member type')
            check_member(member.name, member.mode, member.linkname if member.issym() else '')
            require(not member.issym() or member.linkname, 'empty archive symlink')
        links = {m.name for m in members if m.issym()}
        require(not any(str(parent) in links for name in names for parent in PurePosixPath(name).parents),
                'archive member nested under a symlink')
        require(all(tar.getmember(name).isfile() for name in (MANIFEST, RUNFILE)),
                'manifest and xctestrun must be regular files')
        require(json.load(tar.extractfile(MANIFEST)) == metadata, 'artifact producer or toolchain/runtime mismatch')
        # No extractall: reject links/devices/traversals first and preserve only ordinary modes.
        with phase('artifact_extract'):
            for member in members:
                path = destination / member.name
                path.parent.mkdir(parents=True, exist_ok=True)
                if member.isdir():
                    path.mkdir(exist_ok=True)
                elif member.issym():
                    path.symlink_to(member.linkname)
                else:
                    with tar.extractfile(member) as source, path.open('xb') as sink:
                        shutil.copyfileobj(source, sink)
                if not member.issym():
                    path.chmod(member.mode)
    validate_products(destination)
    print(destination / RUNFILE)


if __name__ == '__main__':
    try:
        command, first, second, udid = sys.argv[1:]
        if command == 'pack':
            pack(Path(first), Path(second), udid)
        elif command == 'restore':
            restore(Path(first), Path(second), udid)
        else:
            raise ValueError('unknown artifact operation')
    except (ValueError, OSError, KeyError, TypeError, tarfile.TarError, subprocess.CalledProcessError) as error:
        sys.exit('error: test build artifact: ' + str(error))