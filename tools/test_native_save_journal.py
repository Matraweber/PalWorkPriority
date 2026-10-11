"""Build/test isolated journal; creates disposable fixtures and evidence only."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
FILES = ['native/save_core/record.hpp', 'native/save_core/record.cpp', 'native/save_core/record_cli.cpp',
         'native/save_core/journal.hpp', 'native/save_core/journal.cpp', 'native/save_core/journal_cli.cpp',
         'tools/build_save_journal.ps1', 'tests/test_native_save_journal.py', 'tools/test_native_save_journal.py']


def fingerprints():
    return {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in FILES}


def main():
    out = ROOT / 'test-results' / ('save-native-journal-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
    out.mkdir(parents=True)
    before = fingerprints()
    receipt = {'passed': False, 'game_test': False, 'production_installed': False,
               'sources_before': before, 'evidence': str(out), 'power_loss_test': False}
    try:
        p = subprocess.run(['powershell', '-NoProfile', '-File', str(ROOT / 'tools/build_save_journal.ps1'),
                            '-OutputDirectory', str(out)], cwd=ROOT, capture_output=True, timeout=120)
        (out / 'build.log').write_bytes(p.stdout + p.stderr)
        if p.returncode:
            raise RuntimeError('build failed; see build.log')
        receipt['binaries'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in out.glob('*.exe')}
        os.environ['PWP_NATIVE_JOURNAL_EXE'] = str(out / 'journal-test.exe')
        suite = unittest.defaultTestLoader.discover(str(ROOT / 'tests'), 'test_native_save_journal.py')
        with (out / 'tests.log').open('w', encoding='utf-8') as stream:
            result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
        after = fingerprints()
        receipt.update(tests=result.testsRun, failures=len(result.failures), errors=len(result.errors),
                       skipped=len(result.skipped), sources_stable=before == after, sources_after=after)
        receipt['passed'] = result.wasSuccessful() and result.testsRun >= 32 and not result.skipped and before == after
    except Exception as error:
        receipt['error'] = str(error)
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
    print(json.dumps({k: v for k, v in receipt.items() if k not in ('sources_before', 'sources_after')}, indent=2))
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
