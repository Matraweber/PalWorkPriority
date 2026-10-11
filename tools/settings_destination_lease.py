"""Disposable-only same-handle destination writes. No live adapter or recovery grant.

Expected snapshot: {'state':'missing'} or B.read_exact-style present identity/hash.
CREATE_NEW changes absence immediately: created remains disclosed even on failure.
Persist receipt identity externally before relying on a reservation after process exit;
identical bytes alone never establish ownership. No deletion/restoration is attempted.
"""
import ctypes
import hashlib
import os
from pathlib import Path
import re
import tempfile
import settings_cutover_lock as L
import settings_migration_backup as B

NAMES=(*B.NAMES,'async-trial/launch.lua','async-trial/receipt.lua')
MARKER='.settings-cutover'
_poisoned=set()
_quarantined=[]


class DestinationLease:
    _open=L.TransactionLock._open
    _info=L.TransactionLock._info
    _close=L.TransactionLock._close

    def __init__(self,root,root_identity,name,expected,marker_bytes):
        self.root=Path(root)
        B.require(self.root.is_absolute() and self.root==Path(os.path.abspath(self.root)), 'absolute canonical root required')
        B.require(self.root.parent==Path(tempfile.gettempdir()) and self.root.name.startswith('pwp-cutover-fixture-'),
                  'owned disposable root required')
        B.require(type(root_identity) is dict and all(type(root_identity.get(k)) is int and root_identity[k]>0
                  for k in ('device','inode')), 'root identity required')
        self.identity=tuple(root_identity[k] for k in ('device','inode'))
        B.require(type(name) is str and name in NAMES,'unapproved destination')
        B.require(type(marker_bytes) is bytes and 0<len(marker_bytes)<=65536,'exact nonempty bounded fence required')
        self._marker_bytes=marker_bytes;self.name=name;self.path=self.root/'mod'/name
        B.require(type(expected) is dict,'snapshot required')
        self._missing=expected=={'state':'missing'}
        self._expected=None
        if not self._missing:
            i=expected.get('identity');sha=expected.get('sha256')
            B.require(expected.get('state')=='present' and type(i) is dict and
                      all(type(i.get(k)) is int and i[k]>0 for k in ('device','inode')) and
                      type(i.get('size')) is int and 0<=i['size']<=B.MAX_BYTES and
                      type(sha) is str and re.fullmatch('[0-9a-f]{64}',sha),'exact present snapshot required')
            self._expected={k:i[k] for k in ('device','inode','size')};self._expected['sha256']=sha
        self._handles=[];self._handle=None;self._used=False;self._active=False;self._failed=False
        self._uncertain=False;self.created=False;self._opened_identity=None;self._verified=None
        self._k=L._kernel();W=L.W
        for name,args in (
            ('SetFilePointerEx',[W.HANDLE,ctypes.c_longlong,ctypes.POINTER(ctypes.c_longlong),W.DWORD]),
            ('ReadFile',[W.HANDLE,W.LPVOID,W.DWORD,ctypes.POINTER(W.DWORD),W.LPVOID]),
            ('WriteFile',[W.HANDLE,W.LPCVOID,W.DWORD,ctypes.POINTER(W.DWORD),W.LPVOID]),
            ('SetEndOfFile',[W.HANDLE]),('FlushFileBuffers',[W.HANDLE])):
            fn=getattr(self._k,name);fn.argtypes=args;fn.restype=W.BOOL

    @staticmethod
    def _identity(info):
        return dict(device=info.volume,inode=(info.index_high<<32)|info.index_low,
                    size=(info.size_high<<32)|info.size_low)

    def _seek(self,handle):
        if not self._k.SetFilePointerEx(handle,0,None,0):raise L.LockError('destination seek failed')

    def _read(self,handle,limit):
        self._seek(handle);out=bytearray();buf=ctypes.create_string_buffer(65536)
        while True:
            count=L.W.DWORD()
            if not self._k.ReadFile(handle,buf,len(buf),ctypes.byref(count),None):raise L.LockError('destination read failed')
            if not count.value:break
            out.extend(buf.raw[:count.value]);B.require(len(out)<=limit,'destination exceeds bound')
        return bytes(out)

    def acquire(self):
        if self._used or self.identity in _poisoned:raise L.LockError('lease unavailable or poisoned')
        self._used=True
        try:
            chain=[*reversed(self.path.parent.parents),self.path.parent]
            B.require(len(chain)<=64,'ancestor bound')
            for path in chain:
                B.checked_path(path,directory=True)
                h=self._open(path,0x81,3,3,0x02000000|0x00200000);self._handles.append(h)
                info=self._info(h,True)
                if path==self.root:
                    ident=self._identity(info)
                    B.require((ident['device'],ident['inode'])==self.identity,'root identity changed')
            marker=self.root/'mod'/MARKER;B.checked_path(marker)
            h=self._open(marker,0x80000000,1,3,0x00200000|0x80);self._handles.append(h)
            self._info(h,False)
            B.require(self._read(h,65536)==self._marker_bytes,'fence differs')
            B.checked_path(self.path)
            h=self._open(self.path,0xC0000000,1,1 if self._missing else 3,0x00200000|0x80)
            self.created=self._missing;self._handle=h;self._handles.append(h)
            ident=self._identity(self._info(h,False));self._opened_identity=ident.copy()
            if self._missing:B.require(ident['size']==0,'new reservation not empty')
            else:
                B.require(all(ident[k]==self._expected[k] for k in ('device','inode','size')),'destination identity differs')
                B.require(hashlib.sha256(self._read(h,B.MAX_BYTES)).hexdigest()==self._expected['sha256'],
                          'destination bytes differ')
            self._active=True
            return self
        except BaseException:
            self._failed=True;self.release();raise

    def receipt(self):
        return dict(name=self.name,created=self.created,identity=None if self._opened_identity is None else self._opened_identity.copy(),
                    verified=None if self._verified is None else self._verified.copy(),failed=self._failed,
                    activation_allowed=False,ownership_granted=False)

    def read(self):
        B.require(self._active and not self._uncertain,'lease not active')
        return self._read(self._handle,B.MAX_BYTES)

    def overwrite(self,data):
        B.require(self._active and not self._failed and not self._uncertain,'lease not writable')
        B.require(type(data) is bytes and len(data)<=B.MAX_BYTES,'bounded bytes required')
        self._verified=None
        try:
            self._seek(self._handle);offset=0
            while offset<len(data):
                chunk=data[offset:offset+65536];buf=ctypes.create_string_buffer(chunk);count=L.W.DWORD()
                if not self._k.WriteFile(self._handle,buf,len(chunk),ctypes.byref(count),None):raise L.LockError('destination write failed')
                B.require(0<count.value<=len(chunk),'invalid write progress');offset+=count.value
            if not self._k.SetEndOfFile(self._handle):raise L.LockError('destination truncate failed')
            if not self._k.FlushFileBuffers(self._handle):raise L.LockError('destination flush failed')
            B.require(self._read(self._handle,B.MAX_BYTES)==data,'destination readback differs')
            info=self._identity(self._info(self._handle,False))
            B.require(all(info[k]==self._opened_identity[k] for k in ('device','inode')) and info['size']==len(data),
                      'destination identity changed')
            self._verified=dict(size=len(data),sha256=hashlib.sha256(data).hexdigest(),file_flush_requested=True)
            return self.receipt()
        except BaseException:
            self._failed=True;raise

    def release(self):
        self._active=False
        if self._uncertain:raise L.LockReleaseError('uncertain lease release; process exit required')
        while self._handles:
            h=self._handles[-1]
            try:closed=self._close(h)
            except BaseException:closed=False
            if not closed:
                self._uncertain=True;_poisoned.add(self.identity);_quarantined.append(self)
                raise L.LockReleaseError('lease release failed; process exit required')
            self._handles.pop()
        self._handle=None

    def __enter__(self):return self.acquire()
    def __exit__(self,*exc):self.release();return False
