"""Real kernel-name arbitration across DLL copies and child processes, no game IO."""
import ctypes
import os
from pathlib import Path
import subprocess
import sys
import unittest
import uuid
import concurrent.futures
DLL=os.environ.get('PWP_NATIVE_OWNER_DLL')
def library(path):
    d=ctypes.CDLL(str(path))
    d.claim.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint]
    d.reserve.argtypes=[ctypes.c_uint,ctypes.c_uint]
    d.complete.argtypes=[ctypes.c_uint,ctypes.c_int]
    for k in ['peek','consume']:getattr(d,k).argtypes=[ctypes.c_uint]
    return d
@unittest.skipUnless(DLL and os.name=='nt','requires native owner test DLL')
class Owners(unittest.TestCase):
    def setUp(self):
        self.a=library(DLL);self.b=library(Path(DLL).with_name('owner-test-copy.dll'))
        self.a.drop();self.b.drop()
        self.scope=('PWP-SCOPE-1:'+uuid.uuid4().hex+':'+uuid.uuid4().hex+':priorities').encode()
    def tearDown(self):
        for d in [self.a,self.b]:d.retire();d.release();d.drop()
    def claim(self,d):return d.claim(self.scope,b'boot:1',1)
    def test_duplicate_dll_and_process(self):
        self.assertNotEqual(self.a._handle,self.b._handle)
        self.assertEqual(self.claim(self.a),1);self.assertEqual(self.claim(self.b),0)
        code="import ctypes,sys;d=ctypes.CDLL(sys.argv[1]);d.claim.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint];print(d.claim(sys.argv[2].encode(),b'other',1))"
        p=subprocess.run([sys.executable,'-c',code,DLL,self.scope.decode()],capture_output=True,text=True,timeout=10)
        self.assertEqual(p.returncode,0);self.assertEqual(p.stdout.strip(),'0')
        self.a.retire();self.assertEqual(self.a.release(),1);self.assertEqual(self.claim(self.b),1)
    def test_pending_retirement_retains_claim(self):
        self.assertEqual(self.claim(self.a),1);self.assertEqual(self.a.reserve(1,1),1)
        self.a.retire();self.assertEqual(self.a.reserve(2,1),0);self.assertEqual(self.a.release(),0)
        self.assertEqual(self.claim(self.b),0)
        self.assertEqual(self.a.complete(1,1),1);self.assertEqual(self.a.release(),0)
        self.assertEqual(self.a.consume(2),0);self.assertEqual(self.a.consume(1),1)
        self.assertEqual(self.a.consume(1),1);self.assertEqual(self.a.release(),1)
        self.assertEqual(self.claim(self.b),1)
    def test_uncertainty_never_releases(self):
        self.claim(self.a);self.a.reserve(1,1);self.a.complete(1,0);self.a.retire()
        self.assertEqual(self.a.consume(1),0);self.assertEqual(self.a.release(),0)
        self.assertEqual(self.a.complete(1,1),0);self.a.drop()
        self.assertEqual(self.claim(self.b),0)
    def test_dropped_pending_owner_still_excludes(self):
        self.claim(self.a);self.a.reserve(1,1);self.a.drop()
        self.assertEqual(self.claim(self.b),0)
    def test_binding_ticket_and_retained_completion(self):
        self.claim(self.a)
        self.assertEqual(self.a.reserve(1,2),0);self.assertEqual(self.a.reserve(0,1),0)
        self.assertEqual(self.a.reserve(1,1),1);self.assertEqual(self.a.reserve(2,1),0)
        self.assertEqual(self.a.complete(2,1),0);self.assertEqual(self.a.peek(1),0)
        self.assertEqual(self.a.complete(1,1),1);self.assertEqual(self.a.peek(1),1)
        self.assertEqual(self.a.peek(2),0);self.assertEqual(self.a.complete(1,1),0)
        self.a.consume(1);self.assertEqual(self.a.reserve(1,1),0)
        self.assertEqual(self.a.reserve(2,1),1);self.assertEqual(self.a.consume(1),1)
        self.assertEqual(self.a.reserve(3,1),0)
        self.a.complete(2,1);self.a.consume(2)
    def test_concurrent_admission(self):
        self.claim(self.a)
        with concurrent.futures.ThreadPoolExecutor(16) as pool:
            results=list(pool.map(lambda _:self.a.reserve(1,1),range(64)))
        self.assertEqual(sum(results),1);self.a.complete(1,1);self.a.consume(1)
    def test_invalid_binding(self):
        self.assertEqual(self.a.claim(b'bad',b'boot',1),0)
        self.assertEqual(self.a.claim(self.scope,b'',1),0)
        self.assertEqual(self.a.claim(self.scope,b'boot',0),0)
    def test_process_exit_releases_kernel_claim(self):
        code="import ctypes,sys;d=ctypes.CDLL(sys.argv[1]);d.claim.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint];print(d.claim(sys.argv[2].encode(),b'child',1),flush=True);sys.stdin.readline()"
        with subprocess.Popen([sys.executable,'-c',code,DLL,self.scope.decode()],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) as p:
            self.assertEqual(p.stdout.readline().strip(),'1')
            self.assertEqual(self.claim(self.a),0)
            p.communicate('\n',timeout=10)
            self.assertEqual(p.returncode,0)
        self.assertEqual(self.claim(self.a),1)
    def test_module_pin_survives_freelibrary(self):
        code="""
import ctypes,sys
d=ctypes.CDLL(sys.argv[1]);d.claim.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint]
if d.claim(sys.argv[3].encode(),b'pin',1)!=1:raise RuntimeError('claim')
if d.reserve(1,1)!=1:raise RuntimeError('reserve')
d.drop()
k=ctypes.WinDLL('kernel32',use_last_error=True);k.FreeLibrary.argtypes=[ctypes.c_void_p]
if not k.FreeLibrary(d._handle):raise RuntimeError('free')
k.GetModuleHandleW.argtypes=[ctypes.c_wchar_p];k.GetModuleHandleW.restype=ctypes.c_void_p
if not k.GetModuleHandleW(sys.argv[1]):raise RuntimeError('unloaded')
other=ctypes.CDLL(sys.argv[2]);other.claim.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint]
if other.claim(sys.argv[3].encode(),b'other',1)!=0:raise RuntimeError('lost lease')
print('PINNED')
"""
        r=subprocess.run([sys.executable,'-c',code,DLL,str(Path(DLL).with_name('owner-test-copy.dll')),self.scope.decode()],capture_output=True,text=True,timeout=10)
        self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(r.stdout.strip(),'PINNED')
if __name__=='__main__':unittest.main()
