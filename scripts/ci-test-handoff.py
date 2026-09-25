#!/usr/bin/env python3
"""Hosted producer outputs and exact consumer platform selection (no builds).

Only configure/publish run on the producer. Consumer expectations come from job
outputs, never from the downloaded receipt. Runtime smoke credentials are not read.
CI_PHASE_TIMING=1 adds content-free stderr timings; platform_select_total includes
toolchain_select. Workflow outputs and environment-file contracts are unchanged.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from ci_phase import phase


def require(ok, message):
    if not ok:
        raise ValueError(message)


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def emit(file, values):
    with open(os.environ[file], 'a') as stream:
        for key, value in values.items():
            value = str(value)
            require('\n' not in value and '\r' not in value, 'multiline workflow output')
            stream.write(f'{key}={value}\n')


def sha(path):
    value = hashlib.sha256()
    with open(path, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def checkout():
    revision = output('git', 'rev-parse', 'HEAD')
    require(re.fullmatch('[0-9a-f]{40}', revision), 'invalid checkout revision')
    return revision


@phase('toolchain_select')
def select_xcode(expected=None):
    require(output('uname', '-m') == 'arm64', 'host must be arm64')
    bundles = output('find', '-L', '/Applications', '-maxdepth', '1', '-name', 'Xcode*.app').splitlines()
    candidates = [str(Path(p) / 'Contents/Developer') for p in bundles]
    candidates.append(output('xcode-select', '-p'))
    matches = []
    for path in sorted(set(candidates)):
        # A matching bundle name can be a manager app, not Xcode (ios#484).
        tool = Path(path) / 'usr/bin/xcodebuild'
        if not tool.is_file() or not os.access(tool, os.X_OK):
            continue
        result = subprocess.run(['xcodebuild', '-version'], text=True, capture_output=True,
                                env=dict(os.environ, DEVELOPER_DIR=path), check=False)
        version = result.stdout.strip()
        if result.returncode or not re.fullmatch(r'Xcode [0-9.]+\nBuild version [A-Za-z0-9]+', version):
            continue
        if expected is None or version == expected:
            matches.append((tuple(map(int, version.splitlines()[0].split()[1].split('.'))), path, version))
    require(matches, 'no usable compatible Xcode version/build is installed; no fallback')
    _, path, version = max(matches)
    os.environ['DEVELOPER_DIR'] = path
    return path, version


@phase('platform_select_total')
def select_platform(expected=None):
    developer, version = select_xcode(expected['xcode'] if expected else None)
    devices = json.loads(output('xcrun', 'simctl', 'list', 'devices', 'available', '-j'))['devices']
    runtimes = json.loads(output('xcrun', 'simctl', 'list', 'runtimes', '-j'))['runtimes']
    if expected:
        runtime = expected['runtime']
        matches = [d for d in devices.get(runtime['identifier'], [])
                   if d.get('isAvailable') and d['name'] == expected['device']]
        require(matches, 'producer simulator device/runtime is unavailable; no fallback')
        udid = sorted(d['udid'] for d in matches)[0]
    else:
        udid = output('scripts/xcodebuild.sh', 'pick-simulator')
    matches = [(r, d) for r in runtimes if r.get('isAvailable') for d in devices.get(r['identifier'], [])
               if d.get('isAvailable') and d['udid'] == udid]
    require(len(matches) == 1, 'simulator runtime is missing or ambiguous')
    runtime, device = matches[0]
    context = {'xcode': version, 'runtime': {k: runtime[k] for k in ('identifier', 'version', 'buildversion')},
               'device': device['name']}
    require('.iOS-' in runtime['identifier'], 'iOS runtime required')
    require(expected is None or context == expected, 'producer runtime version/build mismatch; no fallback')
    emit('GITHUB_ENV', {'DEVELOPER_DIR': developer, 'SIM_UDID': udid})
    return context


def configure():
    count = os.environ['UI_TEST_SHARD_COUNT']
    require(re.fullmatch('[1-9][0-9]*', count) and int(count) <= 256, 'invalid matrix shard count')
    run_id, attempt = os.environ['GITHUB_RUN_ID'], os.environ['GITHUB_RUN_ATTEMPT']
    require(all(re.fullmatch('[1-9][0-9]*', s) for s in (run_id, attempt)), 'invalid Actions run identity')
    run = f'{run_id}-{attempt}'
    emit('GITHUB_OUTPUT', {'run': run, 'revision': checkout(), 'artifact': f'ios-test-build-{run}',
                           'count': count, 'matrix': json.dumps(list(range(1, int(count) + 1))),
                           'context': json.dumps(select_platform(), sort_keys=True)})


def consume():
    require(checkout() == os.environ['TEST_ARTIFACT_REVISION'], 'checkout differs from producer revision')
    run = os.environ['TEST_ARTIFACT_RUN']
    match = re.fullmatch(r'([1-9][0-9]*)-([1-9][0-9]*)', run)
    require(match and match[1] == os.environ['GITHUB_RUN_ID']
            and int(match[2]) <= int(os.environ['GITHUB_RUN_ATTEMPT']), 'foreign or future producer run')
    require(re.fullmatch('[0-9a-f]{64}', os.environ['TEST_ARTIFACT_SHA256']), 'missing trusted artifact digest')
    select_platform(json.loads(os.environ['TEST_BUILD_CONTEXT']))


def publish():
    archive = Path(os.environ['TEST_ARTIFACT_PATH'])
    receipt = json.loads(Path(str(archive) + '.json').read_text())
    context = json.loads(os.environ['TEST_BUILD_CONTEXT'])
    require(receipt['schema'] == 1 and receipt['architecture'] == 'arm64', 'invalid producer receipt')
    require(receipt['run'] == os.environ['TEST_ARTIFACT_RUN']
            and receipt['revision'] == checkout() == os.environ['TEST_ARTIFACT_REVISION'], 'producer identity mismatch')
    require(all(receipt[k] == context[k] for k in ('xcode', 'runtime')), 'producer context changed during build')
    digest = sha(archive)
    require(receipt['sha256'] == digest and receipt['bytes'] == archive.stat().st_size, 'producer archive changed')
    echo = archive.parent / 'tcecho'
    shutil.copyfile('TailcatKit/build/tcecho', echo)
    emit('GITHUB_OUTPUT', {'sha256': digest, 'echo_sha256': sha(echo)})


def verify_echo():
    path = Path(os.environ['TEST_ARTIFACT_PATH']).parent / 'tcecho'
    expected = os.environ['TEST_ECHO_SHA256']
    require(re.fullmatch('[0-9a-f]{64}', expected) and sha(path) == expected, 'smoke helper checksum mismatch')
    path.chmod(0o755)


def download_reports():
    run_id = os.environ['GITHUB_RUN_ID']
    require(re.fullmatch('[1-9][0-9]*', run_id), 'invalid run ID')
    kind = os.environ['REPORT_KIND']
    require(kind in ('unit', 'all'), 'invalid report kind')
    pages = json.loads(output('gh', 'api', '--paginate', '--slurp',
                              f'repos/{os.environ["GITHUB_REPOSITORY"]}/actions/runs/{run_id}/artifacts?per_page=100'))
    pattern = rf'ios-selection-{run_id}-[1-9][0-9]*-(unit|shard-[1-9][0-9]*)'
    names = [a['name'] for p in pages for a in p['artifacts']
             if not a['expired'] and re.fullmatch(pattern, a['name'])
             and (kind == 'all' or a['name'].endswith('-unit'))]
    require(names and len(names) == len(set(names)), 'missing or duplicate report artifacts')
    for name in names:
        subprocess.run(['gh', 'run', 'download', run_id, '--name', name,
                        '--dir', str(Path('selection-evidence') / name)], check=True)


if __name__ == '__main__':
    try:
        command, = sys.argv[1:]
        {'configure': configure, 'consume': consume, 'publish': publish,
         'verify-echo': verify_echo, 'download-reports': download_reports}[command]()
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        sys.exit('CI test handoff failed: ' + str(error))