"""Actual Windows Lua 5.4 IO classifications, using disposable files only.

These tests do not establish an Engine SaveGame slot's physical destination.
"""
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'.test-deps'))
from lupa.lua54 import LuaRuntime


@unittest.skipUnless(os.name=='nt','Windows runtime error behavior')
class LuaFileErrors(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.read=self.lua.eval('''function(path)
            local f,e,c=io.open(path,'rb')
            if not f then return false,c end
            local value,err=f:read(1)
            local closed=f:close()
            return closed==true and err==nil, value
        end''')

    def test_empty_file_is_present_and_missing_parent_is_not_distinguished(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);empty=root/'empty.sav';empty.write_bytes(b'')
            self.assertEqual(self.read(str(empty)),(True,None))
            self.assertEqual(self.read(str(root/'missing.sav')),(False,2))
            # This is why errno2 alone must not initialize empty settings.
            self.assertEqual(self.read(str(root/'missing-parent'/'slot.sav')),(False,2))

    def test_sharing_denied_is_not_absence(self):
        import ctypes
        from ctypes import wintypes
        kernel=ctypes.WinDLL('kernel32',use_last_error=True)
        kernel.CreateFileW.argtypes=[wintypes.LPCWSTR,wintypes.DWORD,wintypes.DWORD,
                                    wintypes.LPVOID,wintypes.DWORD,wintypes.DWORD,wintypes.HANDLE]
        kernel.CreateFileW.restype=wintypes.HANDLE
        kernel.CloseHandle.argtypes=[wintypes.HANDLE]
        kernel.CloseHandle.restype=wintypes.BOOL
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'locked.sav';path.write_bytes(b'previous data')
            handle=kernel.CreateFileW(str(path),0x80000000,0,None,3,0x80,None)
            self.assertNotEqual(handle,ctypes.c_void_p(-1).value)
            try:
                opened,code=self.read(str(path))
                self.assertFalse(opened)
                self.assertNotEqual(code,2,'sharing error must not be absence')
            finally:
                self.assertTrue(kernel.CloseHandle(handle))
            self.assertEqual(self.read(str(path)),(True,'p'))
            self.assertEqual(path.read_bytes(),b'previous data')


if __name__=='__main__': unittest.main()
