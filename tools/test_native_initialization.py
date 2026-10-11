"""Build and verify experimental native publication; never touches game paths."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'test-results' / 'save-native-initialization-20261004'


def fingerprints():
    files = list((ROOT / 'native/save_core').glob('*')) + [Path(__file__).resolve(),
        ROOT / 'tools/build_save_initialization.ps1', ROOT / 'tests/test_native_save_initialization.py']
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in files if p.is_file()}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    before = fingerprints()
    receipt = {'started_utc': datetime.now(timezone.utc).isoformat(), 'production_installed': False,
               'game_test': False, 'sources_before': before, 'passed': False}
    try:
        for label, flags in [('no-hooks', ['-CoreOnly']), ('test', [])]:
            p = subprocess.run(['powershell', '-NoProfile', '-File',
                str(ROOT / 'tools/build_save_initialization.ps1'), '-OutputDirectory', str(OUT), *flags],
                cwd=ROOT, capture_output=True, timeout=120)
            (OUT / (label + '-build.log')).write_bytes(p.stdout + p.stderr)
            if p.returncode:
                raise RuntimeError(label + ' build failed')
        exe = OUT / 'initialization-test.exe'
        os.environ['PWP_NATIVE_INIT_EXE'] = str(exe)
        receipt['executable_sha256'] = hashlib.sha256(exe.read_bytes()).hexdigest()
        suite = unittest.defaultTestLoader.discover(str(ROOT / 'tests'), 'test_native_save_initialization.py')
        with (OUT / 'tests.log').open('w', encoding='utf-8') as stream:
            result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
        receipt.update(tests=result.testsRun, failures=len(result.failures), errors=len(result.errors),
                       skipped=len(result.skipped))
        after = fingerprints()
        receipt.update(sources_after=after, sources_stable=before == after)
        receipt['passed'] = result.wasSuccessful() and result.testsRun >= 16 and not result.skipped and before == after
    except Exception as error:
        receipt['error'] = str(error)
    receipt['finished_utc'] = datetime.now(timezone.utc).isoformat()
    (OUT / 'receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
    print(json.dumps({k: v for k, v in receipt.items() if not k.startswith('sources_')}, indent=2))
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
