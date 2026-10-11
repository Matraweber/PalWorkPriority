"""Run all offline Python unittest suites without native executable opt-ins."""
from pathlib import Path
import os
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def main():
    environment = os.environ.copy()
    # Native tests remain discoverable and report skips; running their compiled
    # helpers belongs to the separate, explicit native-test entrypoints.
    for name in (
        'PWP_NATIVE_INIT_EXE',
        'PWP_NATIVE_JOURNAL_EXE',
        'PWP_NATIVE_OWNER_DLL',
        'PWP_NATIVE_READER_EXE',
        'PWP_NATIVE_RECORD_EXE',
    ):
        environment.pop(name, None)
    return subprocess.run(
        [sys.executable, '-B', '-m', 'unittest', 'discover',
         '-s', str(ROOT / 'tests'), '-t', str(ROOT), '-p', 'test_*.py', '-v'],
        cwd=ROOT, env=environment,
    ).returncode


if __name__ == '__main__':
    raise SystemExit(main())
