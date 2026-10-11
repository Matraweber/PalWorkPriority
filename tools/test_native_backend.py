"""Actual native whole-journal integration with independent final byte checks."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import subprocess
import tempfile
from test_native_operation import require, readback

ROOT = Path(__file__).resolve().parents[1]


def main():
    out = ROOT/'test-results'/('native-backend-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
    out.mkdir(parents=True)
    paths = [p for p in (ROOT/'native/save_core').glob('*') if p.suffix in ('.cpp','.hpp')]
    paths += [Path(__file__).resolve(), ROOT/'tools/build_save_backend.ps1', ROOT/'tools/test_native_operation.py']
    hashes = lambda: {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    receipt = {'passed': False, 'installed': False, 'game_test': False, 'before': hashes()}
    try:
        p = subprocess.run(['powershell','-NoProfile','-File',str(ROOT/'tools/build_save_backend.ps1'),
                            '-OutputDirectory',str(out)],capture_output=True,timeout=120)
        (out/'build.log').write_bytes(p.stdout+p.stderr)
        require(p.returncode == 0, 'build failed')
        receipt['cases'] = []
        for binary, expected in [('backend-test.exe', {'A': (3,'recovered-four'),'B': (2,'three')}),
                                 ('backend-fault-test.exe', {'A': (1,'uncertain')})]:
            with tempfile.TemporaryDirectory(prefix='pwp-backend-') as temporary:
                p = subprocess.run([str(out/binary),temporary],capture_output=True,timeout=40)
                (out/(binary+'.log')).write_bytes(p.stdout+p.stderr)
                require(p.returncode == 0 and b'PASS native backend' in p.stdout, 'backend test failed: '+binary)
                readback(temporary, expected)
                require(not list(Path(temporary).glob('pwp-journal-*')), 'unexpected leftover journal artifact')
                receipt['cases'].append({'binary': binary, 'final_bytes_verified': True})
        receipt['after'] = hashes()
        require(receipt['before'] == receipt['after'], 'source changed during test')
        receipt['passed'] = True
    except Exception as error:
        receipt['error'] = str(error)
    (out/'receipt.json').write_text(json.dumps(receipt,indent=2))
    print(json.dumps({k:v for k,v in receipt.items() if k not in ('before','after')},indent=2))
    print(out)
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
