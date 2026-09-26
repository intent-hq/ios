#!/usr/bin/env bash
# Shared by the strict gate, explicit setup, and real-runtime smoke test.
EXPECTED_SWIFTLINT_VERSION=0.65.1
SWIFTLINT_SWIFT_VERSION=6.3.2
SWIFTLINT_INSTALL_DIR="${INTENT_SWIFTLINT_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/intent/swiftlint}"

swiftlint_error() {
  echo "error: $*" >&2
  return 1
}

swiftlint_find() {
  if SWIFTLINT_PATH=$(command -v swiftlint); then
    return 0
  fi
  if [ "$(uname -s)" = Linux ] && [ -x "$SWIFTLINT_INSTALL_DIR/bin/swiftlint" ]; then
    SWIFTLINT_PATH="$SWIFTLINT_INSTALL_DIR/bin/swiftlint"
    return 0
  fi
  swiftlint_error "SwiftLint $EXPECTED_SWIFTLINT_VERSION is required, but swiftlint was not found on PATH; on Linux run scripts/setup-swiftlint.sh"
}

swiftlint_version_check() {
  local actual
  if ! actual=$("$SWIFTLINT_PATH" version); then
    swiftlint_error "unable to run '$SWIFTLINT_PATH version'"
    return 1
  fi
  if [ "$actual" != "$EXPECTED_SWIFTLINT_VERSION" ]; then
    swiftlint_error "SwiftLint $EXPECTED_SWIFTLINT_VERSION is required; found $actual at $SWIFTLINT_PATH"
    return 1
  fi
}

swiftlint_linux_preflight() {
  [ "$(uname -s)" = Linux ] || return 0
  if ! command -v python3 >/dev/null; then
    swiftlint_error "Linux SwiftLint preflight needs python3; run sudo apt-get install -y python3, then scripts/setup-swiftlint.sh"
    return 1
  fi
  local managed_lib="$SWIFTLINT_INSTALL_DIR/swiftly/toolchains/$SWIFTLINT_SWIFT_VERSION/usr/lib"
  if [ "${LINUX_SOURCEKIT_LIB_PATH+x}" = x ]; then
    if [ ! -f "$LINUX_SOURCEKIT_LIB_PATH/libsourcekitdInProc.so" ]; then
      swiftlint_error "LINUX_SOURCEKIT_LIB_PATH='$LINUX_SOURCEKIT_LIB_PATH' does not contain libsourcekitdInProc.so; correct it or run: unset LINUX_SOURCEKIT_LIB_PATH; scripts/setup-swiftlint.sh"
      return 1
    fi
  elif [ -f "$managed_lib/libsourcekitdInProc.so" ]; then
    export LINUX_SOURCEKIT_LIB_PATH="$managed_lib"
  fi
  # A version check cannot load SourceKit. Exercise actual lint in a child so
  # missing symbols / SIGILL become an actionable failure without a core dump.
  python3 - "$SWIFTLINT_PATH" "$REPO_ROOT/.swiftlint.yml" <<'PY'
import os
import resource
import subprocess
import sys

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
runtime = os.environ.get("LINUX_SOURCEKIT_LIB_PATH")
commands = []
if runtime is not None:
    # SourceKitten may fall back to a system library even when an explicit
    # override is broken. Validate that selection itself in a separate child.
    commands.append([sys.executable, "-c",
                     "import ctypes, sys; lib = ctypes.CDLL(sys.argv[1]); "
                     "lib.sourcekitd_initialize; lib.sourcekitd_send_request_sync",
                     os.path.join(runtime, "libsourcekitdInProc.so")])
commands.append([sys.argv[1], "lint", "--config", sys.argv[2], "--strict", "--no-cache",
                 "--use-stdin", "--quiet"])
try:
    for command in commands:
        result = subprocess.run(command, input='_ = ["one", "two"]\n', text=True,
                                capture_output=True, timeout=30)
        if result.returncode != 0:
            break
    else:
        sys.exit(0)
    detail = (result.stderr or result.stdout).strip()[:2000]
    detail = f"probe exit {result.returncode}: {detail}"
except (OSError, subprocess.TimeoutExpired) as error:
    detail = str(error)
print(f"error: SourceKit runtime is missing or unusable ({runtime or 'default search paths'}).\n{detail}\n"
      "Run scripts/setup-swiftlint.sh; if LINUX_SOURCEKIT_LIB_PATH is set, correct it "
      "or unset it first. No repository lint was run.", file=sys.stderr)
sys.exit(1)
PY
}
