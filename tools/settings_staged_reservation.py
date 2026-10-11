"""Disposable staged missing reservations and explicit empty-scratch recovery.

A flushed receipt binds an empty scratch object's identity BEFORE its no-replace
rename to mod/name. Keep the same handle through publication and writes. Receipt
identity is not evidence that later payload bytes are owned or unmodified. File
flush/readback is checked; power-loss durability of directory metadata is unproved.
All artifacts/fences remain on failure. Paths are reconstructed from strict scalars.
Recovery trusts the caller-bound receipt provenance; it is not authentication against
a fabricated receipt. No arbitrary partial-payload or external-edit recovery grant.
"""
import ctypes
import hashlib
import json
import re
import uuid
import settings_destination_lease as D

B=D.B
L=D.L
CONTRACT='PWP-STAGED-RESERVATION-1'


class RenameInfo(ctypes.Structure):
    _fields_=[('ReplaceIfExists',L.W.BOOLEAN),('RootDirectory',L.W.HANDLE),
              ('FileNameLength',L.W.DWORD),('FileName',L.W.WCHAR*1)]


class StagedReservation(D.DestinationLease):
    def __init__(self,root,root_identity,name,plan_sha256,marker_bytes):
        super().__init__(root,root_identity,name,{'state':'missing'},marker_bytes)
        B.require(type(plan_sha256) is str and re.fullmatch('[0-9a-f]{64}',plan_sha256),'canonical plan hash required')
        self._plan=plan_sha256
        self.nonce=uuid.uuid4().hex
        stem='.settings-reservation-'+self.nonce
        self.stage_path=self.root/(stem+'.stage')
        self.receipt_path=self.root/('staged-'+name.replace('/','--')+'.json')
        self.scratch_created=False;self.published=False;self._prepared=False;self._receipt_handle=None
        self._record=None;self._receipt_bytes=None
        self._k.SetFileInformationByHandle.argtypes=[L.W.HANDLE,ctypes.c_int,L.W.LPVOID,L.W.DWORD]
        self._k.SetFileInformationByHandle.restype=L.W.BOOL

    def _pin_scope(self):
        chain=[*reversed(self.path.parent.parents),self.path.parent]
        B.require(len(chain)<=64,'ancestor bound')
        for path in chain:
            B.checked_path(path,directory=True)
            h=self._open(path,0x81,3,3,0x02000000|0x00200000);self._handles.append(h)
            info=self._info(h,True)
            if path==self.root:
                ident=self._identity(info)
                B.require((ident['device'],ident['inode'])==self.identity,'root identity changed')
        marker=self.root/'mod'/D.MARKER;B.checked_path(marker)
        h=self._open(marker,0x80000000,1,3,0x00200000|0x80);self._handles.append(h)
        self._info(h,False)
        B.require(self._read(h,65536)==self._marker_bytes,'fence differs')

    def acquire(self):
        if self._used or self.identity in D._poisoned:raise L.LockError('reservation unavailable or poisoned')
        self._used=True
        try:
            self._pin_scope()
            B.checked_path(self.path);B.require(not self.path.exists(),'destination already exists')
            B.checked_path(self.stage_path)
            h=self._open(self.stage_path,0xC0010000,1,1,0x00200000|0x80)
            self.scratch_created=True;self._handle=h;self._handles.append(h)
            self._opened_identity=self._identity(self._info(h,False))
            B.require(self._opened_identity['size']==0,'scratch not empty')
            self._active=True
            return self
        except BaseException:
            self._failed=True;self.release();raise

    def prepare(self):
        self.acquire()
        try:
            self.prepare_receipt()
            return self
        except BaseException:
            self.release();raise

    def _write_receipt(self,handle,raw):
        offset=0
        while offset<len(raw):
            chunk=raw[offset:];buf=ctypes.create_string_buffer(chunk);count=L.W.DWORD()
            if not self._k.WriteFile(handle,buf,len(chunk),ctypes.byref(count),None):raise L.LockError('receipt write failed')
            B.require(0<count.value<=len(chunk),'receipt write progress');offset+=count.value
        if not self._k.FlushFileBuffers(handle):raise L.LockError('receipt flush failed')
        B.require(self._read(handle,65536)==raw,'receipt readback differs')

    def prepare_receipt(self):
        B.require(self._active and not self._failed and not self._prepared and not self.published,'reservation not preparable')
        try:
            B.require(self._identity(self._info(self._handle,False))==self._opened_identity and
                      self._read(self._handle,B.MAX_BYTES)==b'','scratch changed')
            if not self._k.FlushFileBuffers(self._handle):raise L.LockError('scratch flush failed')
            record=dict(contract=CONTRACT,plan_sha256=self._plan,
                        root_name=self.root.name,root_identity=dict(device=self.identity[0],inode=self.identity[1]),
                        name=self.name,nonce=self.nonce,stage_basename=self.stage_path.name,
                        identity=self._opened_identity.copy(),
                        initial_sha256=hashlib.sha256(b'').hexdigest(),
                        marker_sha256=hashlib.sha256(self._marker_bytes).hexdigest(),
                        activation_allowed=False,ownership_granted=False)
            raw=(json.dumps(record,sort_keys=True,separators=(',',':'))+'\n').encode('ascii')
            B.checked_path(self.receipt_path)
            h=self._open(self.receipt_path,0xC0000000,1,1,0x00200000|0x80)
            self._receipt_handle=h;self._handles.append(h);self._info(h,False)
            self._write_receipt(h,raw)
            self._record=record;self._receipt_bytes=raw;self._prepared=True
            return json.loads(raw)
        except BaseException:
            self._failed=True;raise

    def _rename(self):
        encoded=str(self.path).encode('utf-16-le')
        size=ctypes.sizeof(RenameInfo)+len(encoded)
        buffer=ctypes.create_string_buffer(size)
        info=RenameInfo.from_buffer(buffer)
        info.ReplaceIfExists=0;info.RootDirectory=None;info.FileNameLength=len(encoded)
        ctypes.memmove(ctypes.addressof(buffer)+RenameInfo.FileName.offset,encoded,len(encoded))
        if not self._k.SetFileInformationByHandle(self._handle,3,buffer,size):
            raise L.LockError(ctypes.get_last_error(),'no-replace reservation publication failed')

    def publish(self):
        B.require(self._active and not self._failed and self._prepared and not self.published,'reservation not publishable')
        try:
            B.require(self._identity(self._info(self._handle,False))==self._opened_identity and
                      self._read(self._handle,B.MAX_BYTES)==b'','scratch changed before publication')
            self._info(self._receipt_handle,False)
            B.require(self._read(self._receipt_handle,65536)==self._receipt_bytes,'receipt changed before publication')
            self._rename()
            self.published=True;self.created=True
            B.require(self._identity(self._info(self._handle,False))==self._opened_identity,'published identity differs')
            return self.receipt()
        except BaseException:
            self._failed=True;raise

    def overwrite(self,data):
        B.require(self.published,'publish reservation before payload writes')
        return super().overwrite(data)

    def receipt(self):
        result=super().receipt()
        result.update(scratch_created=self.scratch_created,published=self.published,
                      receipt_prepared=self._prepared,stage=self.stage_path.name,
                      receipt_name=self.receipt_path.name,
                      publication_record=None if self._record is None else json.loads(self._receipt_bytes))
        return result


class RecoveredReservation(StagedReservation):
    """Reopen only a complete receipt-bound EMPTY unpublished stage.

    Same constructor as StagedReservation. acquire()/__enter__ validates and pins
    the existing receipt read-only, then opens its exact empty object. publish()
    remains explicit. Caller must bind receipt provenance/plan in its transaction;
    matching bytes or a self-consistent fabricated receipt alone grant nothing.
    """
    def _validated_record(self,raw):
        record=json.loads(raw)
        fields={'contract','root_name','root_identity','plan_sha256','name','nonce',
                'stage_basename','identity','initial_sha256','marker_sha256',
                'activation_allowed','ownership_granted'}
        B.require(type(record) is dict and set(record)==fields,'recovery receipt fields')
        B.require(raw==(json.dumps(record,sort_keys=True,separators=(',',':'))+'\n').encode('ascii'),
                  'canonical complete recovery receipt required')
        for field,expected in (('contract',CONTRACT),('root_name',self.root.name),
                               ('plan_sha256',self._plan),('name',self.name),
                               ('initial_sha256',hashlib.sha256(b'').hexdigest()),
                               ('marker_sha256',hashlib.sha256(self._marker_bytes).hexdigest())):
            B.require(type(record[field]) is str and record[field]==expected,'recovery receipt scope differs')
        B.require(record['activation_allowed'] is False and record['ownership_granted'] is False,'recovery grants refused')
        root=record['root_identity'];ident=record['identity'];nonce=record['nonce']
        B.require(type(root) is dict and set(root)=={'device','inode'} and
                  all(type(root[k]) is int and root[k]>0 for k in root) and
                  (root['device'],root['inode'])==self.identity,'recovery root identity differs')
        B.require(type(ident) is dict and set(ident)=={'device','inode','size'} and
                  all(type(ident[k]) is int and ident[k]>0 for k in ('device','inode')) and
                  type(ident['size']) is int and ident['size']==0,'recovery object identity invalid')
        B.require(type(nonce) is str and re.fullmatch('[0-9a-f]{32}',nonce) and nonce!='0'*32,'recovery nonce invalid')
        basename='.settings-reservation-'+nonce+'.stage'
        B.require(type(record['stage_basename']) is str and record['stage_basename']==basename,'recovery stage basename differs')
        return record,basename

    def acquire(self):
        if self._used or self.identity in D._poisoned:raise L.LockError('recovered reservation unavailable or poisoned')
        self._used=True
        try:
            self._pin_scope()
            B.checked_path(self.path);B.require(not self.path.exists(),'recovery destination already exists')
            B.checked_path(self.receipt_path)
            h=self._open(self.receipt_path,0x80000000,1,3,0x00200000|0x80)
            self._receipt_handle=h;self._handles.append(h);self._info(h,False)
            raw=self._read(h,65536);record,basename=self._validated_record(raw)
            self.nonce=record['nonce'];self.stage_path=self.root/basename
            B.checked_path(self.stage_path)
            h=self._open(self.stage_path,0xC0010000,1,3,0x00200000|0x80)
            self._handle=h;self._handles.append(h)
            ident=self._identity(self._info(h,False))
            B.require(ident==record['identity'] and self._read(h,B.MAX_BYTES)==b'',
                      'recovered scratch identity or bytes differ')
            self._opened_identity=ident.copy();self._record=record;self._receipt_bytes=raw
            self._prepared=True;self._active=True
            return self
        except BaseException:
            self._failed=True;self.release();raise

    def prepare(self):
        return self.acquire()
