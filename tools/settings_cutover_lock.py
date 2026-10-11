"""Windows OS lock for cooperating disposable-fixture transaction drivers.

No lock-file deletion, stale-PID stealing, inheritance or non-Windows fallback.
Share-zero excludes other participating drivers; it does NOT stop arbitrary
writers to other files. Game startup fences/stopped-process orchestration remain
separate requirements. Root pinning prevents directory rename while held.

Win32 semantics: https://learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-createfilew
"""
import ctypes
from ctypes import wintypes as W
import os
from pathlib import Path
import tempfile
import settings_migration_backup as B

NAME='.settings-cutover.lock'
_poisoned=set()
_quarantined=[]  # Retain uncertain handles until process exit; never blind-retry.


class LockError(OSError):pass
class LockReleaseError(LockError):pass


class FileInfo(ctypes.Structure):
    _fields_=[('attributes',W.DWORD),('created',W.FILETIME),('accessed',W.FILETIME),
              ('written',W.FILETIME),('volume',W.DWORD),('size_high',W.DWORD),
              ('size_low',W.DWORD),('links',W.DWORD),('index_high',W.DWORD),('index_low',W.DWORD)]


def _kernel():
    if os.name!='nt':raise LockError('Windows transaction lock required')
    k=ctypes.WinDLL('kernel32',use_last_error=True)
    k.CreateFileW.argtypes=[W.LPCWSTR,W.DWORD,W.DWORD,W.LPVOID,W.DWORD,W.DWORD,W.HANDLE]
    k.CreateFileW.restype=W.HANDLE
    k.GetFileInformationByHandle.argtypes=[W.HANDLE,ctypes.POINTER(FileInfo)]
    k.GetFileInformationByHandle.restype=W.BOOL
    k.GetFileType.argtypes=[W.HANDLE];k.GetFileType.restype=W.DWORD
    k.GetHandleInformation.argtypes=[W.HANDLE,ctypes.POINTER(W.DWORD)]
    k.GetHandleInformation.restype=W.BOOL
    k.CloseHandle.argtypes=[W.HANDLE];k.CloseHandle.restype=W.BOOL
    return k


class TransactionLock:
    def __init__(self,root,root_id):
        self.root=Path(root)
        self.identity=(root_id['device'],root_id['inode'])
        self._root_handle=self._lock_handle=None
        self._pins=[]
        self._used=self._uncertain=False
        self._k=_kernel()

    def _check_root(self):
        B.checked_path(self.root,directory=True)
        B.require(self.root.resolve().parent==Path(tempfile.gettempdir()).resolve()
                  and self.root.name.startswith('pwp-cutover-fixture-'),'lock requires owned disposable root')
        s=self.root.stat()
        B.require((s.st_dev,s.st_ino)==self.identity,'lock root identity changed')

    def _open(self,path,access,share,creation,flags):
        # NULL security attributes => non-inheritable handle; verify below too.
        handle=self._k.CreateFileW(str(path),access,share,None,creation,flags,None)
        if handle==ctypes.c_void_p(-1).value:
            raise LockError(ctypes.get_last_error(),'transaction lock unavailable')
        return handle

    def _info(self,handle,directory):
        info=FileInfo();flags=W.DWORD()
        if not self._k.GetFileInformationByHandle(handle,ctypes.byref(info)):
            raise LockError('cannot inspect transaction handle')
        if not self._k.GetHandleInformation(handle,ctypes.byref(flags)):
            raise LockError('cannot inspect handle inheritance')
        B.require(self._k.GetFileType(handle)==1 and not info.attributes&0x400
                  and bool(info.attributes&0x10)==directory,'unexpected lock handle type/reparse')
        B.require(not flags.value&1,'inheritable transaction handle')
        if not directory:B.require(info.links==1,'hard-linked lock file refused')
        return info

    def acquire(self):
        if self._used or self.identity in _poisoned:raise LockError('transaction lock unavailable or poisoned')
        self._used=True
        self._check_root()
        try:
            # Match native/save_core/root_capability.cpp: metadata-only access
            # does not enforce delete sharing. Pin ancestors first as well, so
            # renaming a parent cannot redirect a later path-based operation.
            chain=[*reversed(self.root.parents),self.root]
            B.require(len(chain)<=64,'too many root ancestors')
            for path in chain:
                handle=self._open(path,0x81,3,3,0x02000000|0x00200000)
                self._pins.append(handle)
                info=self._info(handle,True)
            self._root_handle=handle
            self._check_root()
            # Bind the opened directory object to the checked NTFS file identity.
            B.require((info.volume,(info.index_high<<32)|info.index_low)==self.identity,
                      'opened root identity differs')
            path=self.root/NAME;B.checked_path(path)
            # GENERIC_READ|WRITE, share0, OPEN_ALWAYS (never truncate), OPEN_REPARSE_POINT.
            self._lock_handle=self._open(path,0xC0000000,0,4,0x00200000|0x80)
            self._info(self._lock_handle,False)
            self._check_root()
            return self
        except BaseException:
            self.release()
            raise

    def _close(self,handle):
        return bool(self._k.CloseHandle(handle))

    def release(self):
        if self._uncertain:raise LockReleaseError('uncertain release; process exit required')
        # All mutations have ended. Release the lock before directory pins;
        # failure to release it retains every pin until process exit.
        handles=([self._lock_handle] if self._lock_handle is not None else [])+list(reversed(self._pins))
        for handle in handles:
            try:closed=self._close(handle)
            except BaseException:closed=False
            if not closed:
                self._uncertain=True;_poisoned.add(self.identity);_quarantined.append(self)
                raise LockReleaseError('transaction handle release failed; process exit required')
            if handle==self._lock_handle:self._lock_handle=None
            else:
                self._pins.pop()
                if handle==self._root_handle:self._root_handle=None

    def __enter__(self):return self.acquire()
    def __exit__(self,*exc):self.release();return False
