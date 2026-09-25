"""Best-effort, content-free CI_PHASE_TIMING=1 diagnostics (stderr only).

Names ending in _total are composite spans; never add them to their children.
Missing markers (clock/output failure or an uncatchable kill) are not success.
The CLI transports only monotonic timestamps, fixed names and exit statuses.
"""

from contextlib import contextmanager
import math
import os
import sys
import time


PHASES = frozenset({
    'platform_select_total', 'toolchain_select', 'artifact_context',
    'artifact_pack_total', 'artifact_restore_total', 'artifact_extract',
    'artifact_products_validate', 'producer_build', 'producer_discovery_probe_total',
    'simulator_readiness', 'consumer_discovery', 'test_process', 'result_verification',
})


def start():
    try:
        return time.monotonic()
    except Exception:
        return None


def finish(name, started, outcome, stream=None):
    try:
        if name not in PHASES or outcome not in ('success', 'failure', 'cancelled') or started is None:
            return
        elapsed = time.monotonic() - float(started)
        if not math.isfinite(elapsed) or elapsed < 0:
            return
        marker = f'ci-phase phase={name} outcome={outcome} elapsed_seconds={elapsed:.6f}\n'
        # No buffered write: a broken diagnostic pipe must not survive in a
        # Python stream and turn interpreter shutdown into exit 120.
        os.write((stream or sys.stderr).fileno(), marker.encode('ascii'))
    except Exception:
        pass  # Optional clock/output failures must never replace the operation's result.


@contextmanager
def phase(name):
    started = start() if os.environ.get('CI_PHASE_TIMING') == '1' else None
    outcome = 'failure'
    try:
        yield
        outcome = 'success'
    except KeyboardInterrupt:
        outcome = 'cancelled'
        raise
    finally:
        finish(name, started, outcome)


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['start']:
            value = start()
            if value is not None:
                print(value)
        elif len(sys.argv) == 5 and sys.argv[1] == 'finish':
            status = int(sys.argv[4])
            finish(sys.argv[2], sys.argv[3], 'success' if status == 0 else
                   'cancelled' if status >= 128 else 'failure', stream=sys.stdout)
    except Exception:
        pass