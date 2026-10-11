"""Build/run disposable reader tests; never loads UE4SS or touches game paths."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import ctypes
from ctypes import wintypes
import struct
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
FILES = ['native/save_core/record.hpp', 'native/save_core/record.cpp',
         'native/save_core/record_reader.hpp', 'native/save_core/record_reader.cpp',
         'native/save_core/reader_cli.cpp', 'tools/build_save_reader.ps1',
         'tests/test_native_save_reader.py', 'tools/test_native_save_reader.py']


def fingerprints():
    return {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in FILES}


class RetainedBytes(unittest.TestCase):
    """Real file fixtures; compare the complete returned envelope independently."""
    storage, guild = 'a'*32, 'b'*32
    scope = 'PWP-SCOPE-1:' + storage + ':' + guild + ':priorities'

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='pwp-reader-bytes-')
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.target = self.root / f'pwp-record-v1-{self.storage}-{self.guild}-priorities-A.record'

    def wire(self, payload=b'\x00\xff\n', scope=None):
        scope = (scope or self.scope).encode()
        body = b'PWPJNL1\n' + struct.pack('<HII', len(scope), 7, len(payload)) + scope + payload
        return body + hashlib.sha256(body).digest()

    def read(self, root=None):
        result = subprocess.run([os.environ['PWP_NATIVE_READER_EXE'], str(root or self.root),
                                 self.storage, self.guild, 'priorities', 'A', '--encoded'],
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        state, error, generation, present, raw = result.stdout.split(b'\n', 4)
        self.assertIn(present, (b'0', b'1'))
        if present == b'0':
            self.assertEqual(raw, b'')
        if state in (b'missing', b'unreadable'):
            self.assertEqual(present, b'0')
        return state.decode(), int(error), int(generation), raw if present == b'1' else None

    def retained(self, raw, state, generation=0):
        self.target.write_bytes(raw)
        self.assertEqual(self.read(), (state, 0, generation, raw))
        self.assertEqual(self.target.read_bytes(), raw)
        self.assertEqual(list(self.root.iterdir()), [self.target])

    def test_valid_binary_and_max_payload(self):
        for payload in (b'', b'\x00\xff\n', bytes(range(256))*1024):
            with self.subTest(size=len(payload)):
                self.retained(self.wire(payload), 'valid', 7)

    def test_corrupt_complete_truncated_and_empty(self):
        good = self.wire()
        for raw in (b'', good[:-1], good[:-1] + bytes([good[-1] ^ 1])):
            with self.subTest(size=len(raw)):
                self.retained(raw, 'corrupt')

    def test_foreign_retains_exact_envelope(self):
        self.retained(self.wire(scope=self.scope.replace('a'*32, 'c'*32)), 'foreign')

    def test_unsupported_bounded_retained_oversized_unavailable(self):
        for raw in (b'UNKNOWN!', b'x'*262450):
            with self.subTest(size=len(raw)):
                self.retained(raw, 'unsupported')
        self.target.write_bytes(b'x'*262451)
        self.assertEqual(self.read(), ('unsupported', 0, 0, None))
        self.assertEqual(self.target.stat().st_size, 262451)

    def test_missing_leaf_vs_unavailable_root(self):
        self.assertEqual(self.read(), ('missing', 2, 0, None))
        result = self.read(self.root / 'absent')
        self.assertEqual((result[0], result[2], result[3]), ('unreadable', 0, None))
        self.assertIn(result[1], (2, 3))
        self.assertEqual(list(self.root.iterdir()), [])

    def test_directory_unavailable_without_bytes(self):
        self.target.mkdir()
        result = self.read()
        self.assertEqual((result[0], result[2], result[3]), ('unreadable', 0, None))

    def test_exclusive_denial_never_retains_preimage(self):
        raw = self.wire()
        self.target.write_bytes(raw)
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                      wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        kernel.CreateFileW.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle.restype = wintypes.BOOL
        handle = kernel.CreateFileW(str(self.target), 0x80000000, 0, None, 3, 0x80, None)
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value)
        try:
            self.assertEqual(self.read(), ('unreadable', 32, 0, None))
        finally:
            self.assertTrue(kernel.CloseHandle(handle))
        self.assertEqual(self.read(), ('valid', 0, 7, raw))


def main():
    out = ROOT / 'test-results' / ('save-native-reader-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
    out.mkdir(parents=True)
    before = fingerprints()
    receipt = {'passed': False, 'game_test': False, 'production_installed': False,
               'sources_before': before, 'evidence': str(out)}
    try:
        build = subprocess.run(['powershell', '-NoProfile', '-File', str(ROOT / 'tools/build_save_reader.ps1'),
                                '-OutputDirectory', str(out)], cwd=ROOT, capture_output=True, timeout=120)
        (out / 'build.log').write_bytes(build.stdout + build.stderr)
        if build.returncode:
            raise RuntimeError('build failed; see build.log')
        exe = out / 'reader-test.exe'
        receipt['executable_sha256'] = hashlib.sha256(exe.read_bytes()).hexdigest()
        os.environ['PWP_NATIVE_READER_EXE'] = str(exe)
        suite = unittest.defaultTestLoader.discover(str(ROOT / 'tests'), 'test_native_save_reader.py')
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(RetainedBytes))
        with (out / 'tests.log').open('w', encoding='utf-8') as stream:
            result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
        after = fingerprints()
        receipt.update(tests=result.testsRun, failures=len(result.failures), errors=len(result.errors),
                       skipped=len(result.skipped), sources_stable=before == after, sources_after=after)
        receipt['passed'] = result.wasSuccessful() and result.testsRun >= 21 and not result.skipped and before == after
    except Exception as error:
        receipt['error'] = str(error)
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
    print(json.dumps({k: v for k, v in receipt.items() if not k.startswith('sources_')}, indent=2))
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
