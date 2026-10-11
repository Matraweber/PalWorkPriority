"""Read-handle pins for an explicit reviewed Windows inventory; no filesystem writes.

InventoryPins(files, directories) accepts caller-reconstructed absolute paths,
never a binding/manifest to follow. Files use binding entries containing identity
(device/inode/size) and sha256; directories contain device/inode. Extra recorded
metadata is not authority and timestamps are not compared by this guard.

Existing listed files cannot be opened for write/delete while all handles are
held. New child files are NOT excluded: recheck inventory under the guard.
This is not an ownership, activation, or live cutover grant. No CLI or discovery.
"""
import ctypes
import hashlib
import os
from pathlib import Path
import re
import settings_cutover_lock as L
import settings_migration_backup as B

MAX_FILES=8192
MAX_DIRECTORIES=4096
MAX_FILE_BYTES=64*1024*1024
MAX_TOTAL_BYTES=512*1024*1024
_poisoned=False
_quarantined=[]


class InventoryPins:
    # Reuse only checked Win32 open/info/close primitives, not the writable
    # transaction lock's acquisition, paths, lock artifact or lifetime policy.
    _open=L.TransactionLock._open
    _info=L.TransactionLock._info
    _close=L.TransactionLock._close

    def __init__(self,files,directories):
        B.require(type(files) is dict and 0<len(files)<=MAX_FILES,'bounded file inventory required')
        B.require(type(directories) is dict and 0<len(directories)<=MAX_DIRECTORIES,'bounded directory inventory required')
        self._files={};self._directories={};seen=set();total=0
        for inventory,target,is_file in ((directories,self._directories,False),(files,self._files,True)):
            for raw,entry in inventory.items():
                B.require(isinstance(raw,(str,Path)),'explicit absolute path required')
                path=Path(raw)
                B.require(path.is_absolute() and path==Path(os.path.abspath(path)),'canonical absolute path required')
                key=os.path.normcase(str(path))
                B.require(key not in seen,'duplicate/overlapping inventory path');seen.add(key)
                B.require(type(entry) is dict,'plain inventory record required')
                identity=entry.get('identity') if is_file else entry
                B.require(type(identity) is dict and all(type(identity.get(k)) is int and identity[k]>0
                          for k in ('device','inode')),'valid inventory identity required')
                expected={k:identity[k] for k in ('device','inode')}
                if is_file:
                    size=identity.get('size');sha=entry.get('sha256')
                    B.require(entry.get('state','present')=='present' and type(size) is int and 0<=size<=MAX_FILE_BYTES,
                              'existing bounded file required')
                    B.require(type(sha) is str and re.fullmatch('[0-9a-f]{64}',sha),'canonical SHA256 required')
                    total+=size;B.require(total<=MAX_TOTAL_BYTES,'inventory bytes exceed bound')
                    expected.update(size=size,sha256=sha)
                target[path]=expected
        # Each file parent is explicitly identity-bound, not just discovered.
        dir_keys={os.path.normcase(str(p)) for p in self._directories}
        B.require(all(os.path.normcase(str(p.parent)) in dir_keys for p in self._files),
                  'file parent directory identity required')
        self._chain=set(self._directories)
        for path in self._directories:
            B.require(len(path.parts)<=64,'directory depth exceeds bound')
            self._chain.update(path.parents)
        B.require(len(self._chain)<=MAX_DIRECTORIES,'directory pin count exceeds bound')
        self._handles=[];self._used=False;self._uncertain=False
        self._k=L._kernel()
        self._k.ReadFile.argtypes=[L.W.HANDLE,L.W.LPVOID,L.W.DWORD,ctypes.POINTER(L.W.DWORD),L.W.LPVOID]
        self._k.ReadFile.restype=L.W.BOOL

    @staticmethod
    def _matches(info,wanted,is_file):
        B.require(info.volume==wanted['device'] and ((info.index_high<<32)|info.index_low)==wanted['inode'],
                  'opened inventory identity differs')
        if is_file:B.require(((info.size_high<<32)|info.size_low)==wanted['size'],'inventory file size differs')

    def _hash(self,handle,expected):
        digest=hashlib.sha256();size=0;buffer=ctypes.create_string_buffer(1024*1024)
        while True:
            count=L.W.DWORD()
            if not self._k.ReadFile(handle,buffer,len(buffer),ctypes.byref(count),None):
                raise L.LockError('inventory handle read failed')
            if count.value==0:break
            size+=count.value
            B.require(size<=expected['size'],'inventory file grew')
            digest.update(buffer.raw[:count.value])
        B.require(size==expected['size'] and digest.hexdigest()==expected['sha256'],'inventory file hash differs')

    def acquire(self):
        if self._used or _poisoned:raise L.LockError('inventory guard unavailable or poisoned')
        self._used=True
        try:
            for path in sorted(self._chain,key=lambda p:(len(p.parts),os.path.normcase(str(p)))):
                B.checked_path(path,directory=True)
                handle=self._open(path,0x81,3,3,0x02000000|0x00200000)
                self._handles.append(handle)
                info=self._info(handle,True)
                if path in self._directories:self._matches(info,self._directories[path],False)
            for path,expected in sorted(self._files.items(),key=lambda item:os.path.normcase(str(item[0]))):
                B.checked_path(path)
                handle=self._open(path,0x80000000,1,3,0x00200000|0x80) # READ / SHARE_READ / OPEN_EXISTING
                self._handles.append(handle)
                self._matches(self._info(handle,False),expected,True)
                self._hash(handle,expected)
                self._matches(self._info(handle,False),expected,True)
            return self
        except BaseException:
            self.release()
            raise

    def release(self):
        global _poisoned
        if self._uncertain:raise L.LockReleaseError('uncertain inventory release; process exit required')
        # Files first, then leaf directories and ancestors. Stop at the first
        # uncertain close and retain all remaining handles without retry/GC.
        while self._handles:
            handle=self._handles[-1]
            try:closed=self._close(handle)
            except BaseException:closed=False
            if not closed:
                self._uncertain=True;_poisoned=True;_quarantined.append(self)
                raise L.LockReleaseError('inventory release failed; process exit required')
            self._handles.pop()

    def __enter__(self):return self.acquire()
    def __exit__(self,*exc):self.release();return False
