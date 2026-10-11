"""Real owner+journal integration in disposable directories; never installs."""
from pathlib import Path
import hashlib
import json
import os
import struct
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
SCOPE = 'PWP-SCOPE-1:' + 32*'1' + ':' + 32*'2' + ':priorities'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def hashes():
    names = ['operation.hpp', 'operation.cpp', 'operation_test.cpp', 'operation_test_hooks.hpp',
             'operation_test_hooks.cpp', 'owner.hpp', 'owner.cpp', 'journal.hpp', 'journal.cpp',
             'record.hpp', 'record.cpp']
    paths = [ROOT/'native/save_core'/name for name in names]
    paths += [Path(__file__).resolve(), ROOT/'tools/build_save_operation.ps1']
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def decode(raw):
    # Explicit checks remain effective even when imported by optimized Python.
    require(len(raw) >= 50 and raw[:8] == b'PWPJNL1\n', 'bad record magic/length')
    size, gen, length = struct.unpack('<HII', raw[8:18])
    require(size <= 256 and length <= 262144 and 0 < gen < 2147483647, 'bad record bounds')
    require(len(raw) == 18+size+length+32, 'bad encoded length')
    require(hashlib.sha256(raw[:-32]).digest() == raw[-32:], 'SHA256 mismatch')
    require(raw[18:18+size].decode() == SCOPE, 'scope mismatch')
    return gen, raw[18+size:-32].decode()


def readback(root, expected):
    records = {}
    stem = 'pwp-record-v1-' + 32*'1' + '-' + 32*'2' + '-priorities-'
    for f in sorted(Path(root).glob('pwp-record-v1-*.record')):
        require(f.name in (stem+'A.record', stem+'B.record'), 'unexpected record path')
        records[f.name[len(stem)]] = decode(f.read_bytes())
    require(records == expected, f'whole record/slot mismatch: {records!r}')
    return records


def optimize_rejection(out):
    results = []
    for label, flags, extra in [('python-O', ['-O'], {}), ('PYTHONOPTIMIZE', [], {'PYTHONOPTIMIZE': '1'})]:
        p = subprocess.run([sys.executable, '-B', *flags, str(Path(__file__).resolve())],
                           env={**os.environ, **extra}, cwd=out, capture_output=True, timeout=15)
        (out/(label+'.log')).write_bytes(p.stdout+p.stderr)
        require(p.returncode == 2 and b'optimized Python is unsupported' in p.stderr,
                f'{label} failed to refuse optimized execution')
        results.append(label)
    return results


def main():
    # Must precede directory creation, compilation, or fixture work. Subprocess
    # regression invokes this exact script with -O and PYTHONOPTIMIZE=1.
    if not __debug__:
        print('optimized Python is unsupported for operation acceptance', file=sys.stderr)
        return 2
    out = ROOT/'test-results'/('native-operation-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
    out.mkdir(parents=True)
    receipt = {'passed': False, 'installed': False, 'game_test': False, 'sources_before': hashes()}
    try:
        receipt['optimized_execution_rejected'] = optimize_rejection(out)
        p = subprocess.run(['powershell', '-NoProfile', '-File', str(ROOT/'tools/build_save_operation.ps1'),
                            '-OutputDirectory', str(out)], capture_output=True, timeout=120, cwd=ROOT)
        (out/'build.log').write_bytes(p.stdout+p.stderr)
        require(p.returncode == 0, 'build failed')
        receipt['binaries'] = {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in out.glob('*.exe')}
        cases = [
            ('hook-free', 'operation-test.exe', [], {'A': (1, 'one'), 'B': (2, 'two')}),
            ('counted-journal', 'operation-fault-test.exe', [], {'A': (1, 'one'), 'B': (2, 'two')}),
            ('after-publish-uncertainty', 'operation-fault-test.exe', ['uncertain'], {'A': (1, 'uncertain-published')}),
            ('operation-exception', 'operation-fault-test.exe', ['exception'], {'A': (1, 'uncertain-published')}),
            ('cleanup-warning', 'operation-fault-test.exe', ['cleanup-warning'], {'A': (3, 'three'), 'B': (4, 'four')}),
            ('cleanup-close-uncertain', 'operation-fault-test.exe', ['cleanup-close-uncertain'], {'A': (3, 'three'), 'B': (2, 'two')}),
        ]
        receipt['cases'] = []
        for label, binary, flags, expected in cases:
            with tempfile.TemporaryDirectory(prefix='pwp-operation-') as root:
                p = subprocess.run([str(out/binary), root, *flags], capture_output=True, timeout=30)
                (out/(label+'.log')).write_bytes(p.stdout+p.stderr)
                require(p.returncode == 0, f'{label} failed: {p.stderr.decode(errors="replace")}')
                require(b'PASS' in p.stdout, f'{label} has no completion evidence')
                checked = readback(root, expected)
                backups = list(Path(root).glob('pwp-journal-backup-*'))
                if label == 'cleanup-warning':
                    require(len(backups) == 1 and decode(backups[0].read_bytes()) == (1, 'one'),
                            'warning backup was not preserved across later successful cleanup')
                if label == 'cleanup-close-uncertain':
                    require(not backups, 'test close completed but backup remained')
                # A digest-only corruption must fail the independent verifier.
                sample = next(Path(root).glob('pwp-record-v1-*.record')).read_bytes()
                corrupt = sample[:-1] + bytes([sample[-1] ^ 1])
                try:
                    decode(corrupt)
                except RuntimeError as error:
                    require(str(error) == 'SHA256 mismatch', 'unexpected corruption rejection')
                else:
                    raise RuntimeError('corrupt digest accepted')
                receipt['cases'].append({'name': label, 'passed': True, 'independent_readback': checked,
                                         'corrupt_digest_rejected': True})
        receipt['sources_after'] = hashes()
        receipt['sources_stable'] = receipt['sources_before'] == receipt['sources_after']
        require(receipt['sources_stable'], 'source changed during testing')
        receipt['passed'] = True
    except Exception as error:
        receipt['error'] = str(error)
    (out/'receipt.json').write_text(json.dumps(receipt, indent=2))
    print(json.dumps({'passed': receipt['passed'], 'evidence': str(out),
                      'cases': receipt.get('cases'), 'optimized_execution_rejected': receipt.get('optimized_execution_rejected'),
                      'sources_stable': receipt.get('sources_stable'), 'error': receipt.get('error')}, indent=2))
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
