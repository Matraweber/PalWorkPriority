"""Disposable OS evidence, NOT a UE4SS provider or game-runtime acceptance.

Only TemporaryDirectory paths are touched. Child processes model a writer that
does not participate in the Lua/native registry. No game commands or DLL loads
into the game. kernel32 is used only by this standalone Python test process.
"""
import ctypes
from ctypes import wintypes
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(os.name == 'nt', 'Windows filesystem semantics')
class InitializationBoundary(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pwp-init-boundary-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.k = ctypes.WinDLL('kernel32', use_last_error=True)
        self.k.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                     wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        self.k.CreateFileW.restype = wintypes.HANDLE
        self.k.CloseHandle.argtypes = [wintypes.HANDLE]
        self.k.CloseHandle.restype = wintypes.BOOL
        self.k.SetFileAttributesW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD]
        self.k.SetFileAttributesW.restype = wintypes.BOOL

    def open(self, path, access=0x80000000, share=7, creation=3, flags=0x80):
        handle = self.k.CreateFileW(str(path), access, share, None, creation, flags, None)
        if handle == ctypes.c_void_p(-1).value:
            return None, ctypes.get_last_error()  # capture before any other native call
        return handle, 0

    def close(self, handle):
        self.assertTrue(self.k.CloseHandle(handle))

    def failure(self, path, **options):
        handle, error = self.open(path, **options)
        if handle is not None:
            self.close(handle)
        self.assertIsNone(handle)
        return error

    def outsider(self, path):
        subprocess.run([sys.executable, '-c',
                        'from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b"external winner")',
                        str(path)], check=True, timeout=10, capture_output=True)

    def test_absent_leaf_and_absent_parent_have_different_native_errors(self):
        self.assertEqual(self.failure(self.root / 'absent.sav'), 2)
        self.assertEqual(self.failure(self.root / 'absent-parent' / 'slot.sav'), 3)

    def test_empty_existing_file_is_present_and_not_exclusively_creatable(self):
        path = self.root / 'empty.sav'
        path.write_bytes(b'')
        handle, error = self.open(path)
        self.assertEqual(error, 0)
        self.close(handle)
        self.assertEqual(self.failure(path, access=0x40000000, creation=1), 80)
        self.assertEqual(path.read_bytes(), b'')

    def test_sharing_denial_is_not_missing(self):
        path = self.root / 'locked.sav'
        path.write_bytes(b'keep')
        handle, error = self.open(path, share=0)
        self.assertEqual(error, 0)
        try:
            self.assertEqual(self.failure(path), 32)
        finally:
            self.close(handle)
        self.assertEqual(path.read_bytes(), b'keep')

    def test_write_access_denial_is_not_missing(self):
        # Attribute-based denial, not an ACL-denied read test.
        path = self.root / 'readonly.sav'
        path.write_bytes(b'keep')
        self.assertTrue(self.k.SetFileAttributesW(str(path), 1))
        try:
            self.assertEqual(self.failure(path, access=0x40000000), 5)
        finally:
            self.assertTrue(self.k.SetFileAttributesW(str(path), 0x80))
        self.assertEqual(path.read_bytes(), b'keep')

    def test_exclusive_create_rejects_external_writer_after_absence_check(self):
        path = self.root / 'slot.sav'
        self.assertEqual(self.failure(path), 2)
        self.outsider(path)  # deterministic check/use race, different process
        self.assertEqual(self.failure(path, access=0x40000000, share=0, creation=1), 80)
        self.assertEqual(path.read_bytes(), b'external winner')

    def test_create_always_overwrites_external_writer_after_absence_check(self):
        path = self.root / 'slot.sav'
        self.assertEqual(self.failure(path), 2)
        self.outsider(path)
        # Same creation disposition as the inspected Engine OpenWrite default.
        handle, error = self.open(path, access=0x40000000, share=0, creation=2)
        self.assertEqual(error, 0)
        self.close(handle)
        self.assertEqual(path.read_bytes(), b'')

    def test_directory_handle_and_exclusive_a_do_not_reserve_absent_b(self):
        # No delete sharing on the root and no sharing on A still cannot lock
        # the absent B namespace. A per-slot primitive is not an A/B transaction.
        directory, error = self.open(self.root, share=3, flags=0x02000000)
        self.assertEqual(error, 0)
        try:
            self.assertEqual(self.failure(self.root / 'B.sav'), 2)
            a, error = self.open(self.root / 'A.sav', access=0x40000000, share=0, creation=1)
            self.assertEqual(error, 0)
            try:
                self.outsider(self.root / 'B.sav')
                self.assertEqual((self.root / 'B.sav').read_bytes(), b'external winner')
            finally:
                self.close(a)
        finally:
            self.close(directory)


if __name__ == '__main__':
    unittest.main()
