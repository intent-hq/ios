#!/usr/bin/env python3
"""Verify deterministic Depot selection without runner-inventory credentials."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RunnerSelectionTests(unittest.TestCase):
    def test_both_pools_select_depot_without_network_or_tokens(self):
        for pool in ['intent-ios', 'intent-ios-build']:
            for token in ['', 'fixture-secret']:
                with self.subTest(pool=pool, token=bool(token)), tempfile.TemporaryDirectory() as temp:
                    root = Path(temp)
                    curl = root / 'curl'
                    curl.write_text('#!/bin/sh\nexit 99\n')
                    curl.chmod(0o755)
                    env = {**os.environ, 'PATH': str(root) + ':' + os.environ['PATH'],
                           'GITHUB_OUTPUT': str(root / 'output'), 'RUNNER_STATUS_TOKEN': token,
                           'RUNNER_POOL_LABEL': pool}
                    result = subprocess.run(['bash', str(ROOT / '.github/scripts/select-macos-runner.sh')],
                                            env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual((root / 'output').read_text(), 'runs-on="depot-macos-15"\n')
                    self.assertNotIn('fixture-secret', result.stdout + result.stderr)

    def test_workflows_have_no_legacy_fallbacks_or_inventory_secret(self):
        for path in (ROOT / '.github/workflows').glob('*.yml'):
            with self.subTest(workflow=path.name):
                text = path.read_text()
                self.assertNotIn('RUNNER_STATUS_TOKEN', text)
                self.assertNotIn('\'"macos-15"\'', text)
                for line in text.splitlines():
                    if line.strip().startswith('runs-on:') and '${{' not in line:
                        self.assertIn('depot-', line)


if __name__ == '__main__':
    unittest.main()
