"""Real read-only native reader; only disposable test fixtures write files.

Namespace: pwp-record-v1-<storage32>-<guild32>-<stream>-<A|B>.record.
No sentinel missing/unreadable arguments: classifications come from Windows IO.
"""
import ctypes
from ctypes import wintypes
import hashlib
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

EXE = os.environ.get('PWP_NATIVE_READER_EXE')
STORAGE, GUILD = 'a' * 32, 'b' * 32
SCOPE = f'PWP-SCOPE-1:{STORAGE}:{GUILD}:priorities'


def wire(payload=b'binary\0\xff', scope=SCOPE, generation=7):
    body = b'PWPJNL1\n' + struct.pack('<HII', len(scope), generation, len(payload)) + scope.encode() + payload
    return body + hashlib.sha256(body).digest()


@unittest.skipUnless(os.name == 'nt' and EXE, 'requires explicitly built native reader')
class Reader(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='pwp-reader-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.k = ctypes.WinDLL('kernel32', use_last_error=True)
        self.k.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                      wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        self.k.CreateFileW.restype = wintypes.HANDLE
        self.k.CloseHandle.argtypes = [wintypes.HANDLE]
        self.k.CloseHandle.restype = wintypes.BOOL

    def target(self, slot='A', stream='priorities'):
        return self.root / f'pwp-record-v1-{STORAGE}-{GUILD}-{stream}-{slot}.record'

    def read(self, root=None, slot='A', storage=STORAGE, guild=GUILD, stream='priorities'):
        p = subprocess.run([EXE, str(root or self.root), storage, guild, stream, slot],
                           capture_output=True, timeout=10)
        self.assertEqual(p.returncode, 0, p.stderr)
        state, error, generation, payload = p.stdout.split(b'\n', 3)
        if state != b'valid':
            self.assertEqual((generation, payload), (b'0', b''))
        return state.decode(), int(error), int(generation), payload

    def test_missing_root_is_unreadable_not_created(self):
        root = self.root / 'absent'
        state, error, _, _ = self.read(root=root)
        self.assertEqual(state, 'unreadable')
        self.assertIn(error, (2, 3))
        self.assertFalse(root.exists())
        self.assertEqual(list(self.root.iterdir()), [])

    def test_missing_leaf_is_positive_missing(self):
        self.assertEqual(self.read(), ('missing', 2, 0, b''))
        self.assertEqual(self.read(slot='B'), ('missing', 2, 0, b''))
        self.assertEqual(list(self.root.iterdir()), [])

    def test_binary_maximum_payload_and_no_mutation(self):
        payload = bytes(range(256)) * 1024
        data = wire(payload)
        self.target().write_bytes(data)
        self.assertEqual(self.read(), ('valid', 0, 7, payload))
        self.assertEqual(self.target().read_bytes(), data)
        self.assertEqual(list(self.root.iterdir()), [self.target()])

    def test_empty_payload(self):
        self.target().write_bytes(wire(b''))
        self.assertEqual(self.read(), ('valid', 0, 7, b''))

    def test_slot_and_stream_isolation(self):
        scope = f'PWP-SCOPE-1:{STORAGE}:{GUILD}:limits'
        self.target('B', 'limits').write_bytes(wire(b'limits-B', scope))
        self.assertEqual(self.read(slot='B', stream='limits'), ('valid', 0, 7, b'limits-B'))
        self.assertEqual(self.read()[0], 'missing')
        self.assertEqual(self.read(slot='A', stream='limits')[0], 'missing')

    def test_oversize_is_unsupported(self):
        self.target().write_bytes(b'x' * 262451)
        self.assertEqual(self.read()[0], 'unsupported')

    def test_foreign_is_not_corruption(self):
        self.target().write_bytes(wire(scope=SCOPE.replace('a' * 32, 'c' * 32)))
        self.assertEqual(self.read()[0], 'foreign')

    def test_corrupt_truncated_unknown(self):
        for data, expected in [(b'', 'corrupt'), (wire()[:-1], 'corrupt'),
                               (wire()[:-1] + bytes([wire()[-1] ^ 1]), 'corrupt'),
                               (b'UNKNOWN!', 'unsupported')]:
            with self.subTest(expected=expected, size=len(data)):
                self.target().write_bytes(data)
                self.assertEqual(self.read()[0], expected)

    def test_directory_leaf_and_file_root_are_unreadable(self):
        self.target().mkdir()
        self.assertEqual(self.read()[0], 'unreadable')
        root = self.root / 'file-root'
        root.write_bytes(b'not a directory')
        self.assertEqual(self.read(root=root)[0], 'unreadable')

    def test_exclusive_sharing_denial(self):
        self.target().write_bytes(wire())
        handle = self.k.CreateFileW(str(self.target()), 0x80000000, 0, None, 3, 0x80, None)
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value)
        try:
            self.assertEqual(self.read()[:2], ('unreadable', 32))
        finally:
            self.assertTrue(self.k.CloseHandle(handle))
        self.assertEqual(self.read()[0], 'valid')

    def test_existing_writer_even_with_read_sharing_is_denied(self):
        self.target().write_bytes(wire())
        handle = self.k.CreateFileW(str(self.target()), 0x40000000, 7, None, 3, 0x80, None)
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value)
        try:
            self.assertEqual(self.read()[:2], ('unreadable', 32))
        finally:
            self.assertTrue(self.k.CloseHandle(handle))

    def test_invalid_scope_and_root_rejected(self):
        for fields in [dict(storage='0'*32), dict(guild='../escape'), dict(stream='other'),
                       dict(root=str(self.root)+'\\..\\escape'), dict(root=str(self.root)+'\\')]:
            with self.subTest(fields=fields):
                self.assertEqual(self.read(**fields)[0], 'unreadable')
        p = subprocess.run([EXE, str(self.root), STORAGE, GUILD, 'priorities', '../A'],
                           capture_output=True, timeout=10)
        self.assertEqual(p.returncode, 4)
        self.assertEqual(list(self.root.iterdir()), [])

    def junction(self, link, target):
        # mkdir/mklink creates fixtures only, no shell deletion or path discovery.
        p = subprocess.run(['cmd', '/d', '/c', 'mklink', '/J', str(link), str(target)],
                           capture_output=True, timeout=10)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.addCleanup(os.rmdir, link)
        self.assertTrue(link.lstat().st_file_attributes & 0x400)
        self.assertTrue(os.path.samefile(link, target))

    def test_reparse_root_and_ancestor_rejected(self):
        real = self.root / 'real'
        real.mkdir()
        (real / 'child').mkdir()
        link = self.root / 'alias'
        self.junction(link, real)
        self.assertEqual(self.read(root=link)[0], 'unreadable')
        self.assertEqual(self.read(root=link / 'child')[0], 'unreadable')

    def test_reparse_leaf_rejected(self):
        real = self.root / 'real'
        real.mkdir()
        self.junction(self.target(), real)
        self.assertEqual(self.read()[0], 'unreadable')
        self.assertEqual(list(real.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
