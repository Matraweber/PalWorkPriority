from pathlib import Path
import copy
import ctypes
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
import settings_destination_lease as M
B=M.B

@unittest.skipUnless(os.name=='nt','Win32 required')
class Lease(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='pwp-cutover-fixture-');self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.mod=self.root/'mod';self.mod.mkdir();(self.mod/'async-trial').mkdir()
        self.marker=self.mod/M.MARKER;self.marker.write_bytes(b'fenced exact\n')
        self.path=self.mod/'caps.txt';self.path.write_bytes(b'original long bytes')
        self.ident=B.identity(self.root.stat());self.expected=B.read_exact(self.path)
    def lease(self,name='caps.txt',expected=None):
        return M.DestinationLease(self.root,self.ident,name,self.expected if expected is None else expected,b'fenced exact\n')
    def test_same_handle_shorter_write_and_empty(self):
        with self.lease() as lease:
            h=lease._handle
            self.assertEqual(lease.read(),b'original long bytes')
            result=lease.overwrite(b'new');self.assertEqual(lease._handle,h)
            self.assertEqual(lease.read(),b'new');self.assertTrue(result['verified']['file_flush_requested'])
            self.assertFalse(result['created']);self.assertFalse(result['ownership_granted'])
            lease.overwrite(b'');self.assertEqual(lease.read(),b'')
            for op in (lambda:self.marker.unlink(),lambda:self.marker.write_bytes(b'bad'),
                       lambda:self.root.rename(self.root.with_name(self.root.name+'-moved'))):
                with self.assertRaises(OSError):op()
        self.assertEqual(self.path.read_bytes(),b'');self.assertEqual(self.marker.read_bytes(),b'fenced exact\n')
        with self.assertRaises(M.L.LockError):lease.acquire()
    def test_reservation_blocks_child_and_discloses_identity(self):
        path=self.mod/'priorities.txt';other=self.mod/'other';other.write_bytes(b'other')
        code='''
from pathlib import Path
import os,sys
p=Path(sys.argv[1]);other=Path(sys.argv[2])
for op in (lambda:p.write_bytes(b'child'),lambda:p.unlink(),lambda:os.replace(other,p),lambda:p.open('xb')):
    try:op()
    except OSError:pass
    else:raise AssertionError('competing mutation admitted')
'''
        with self.lease('priorities.txt',{'state':'missing'}) as lease:
            r=lease.receipt();self.assertTrue(r['created']);self.assertEqual(r['identity']['inode'],path.stat().st_ino)
            self.assertEqual(lease.read(),b'')
            result=subprocess.run([sys.executable,'-B','-c',code,str(path),str(other)],capture_output=True,text=True,timeout=20)
            self.assertEqual(result.returncode,0,result.stderr)
            lease.overwrite(b'candidate');self.assertEqual(lease.read(),b'candidate')
        self.assertEqual(path.read_bytes(),b'candidate')
    def test_competing_creator_wins_preserved(self):
        path=self.mod/'priorities.txt';lease=self.lease('priorities.txt',{'state':'missing'})
        original=lease._open
        def open_race(p,*args):
            if p==path:path.write_bytes(b'competing creator')
            return original(p,*args)
        with mock.patch.object(lease,'_open',side_effect=open_race),self.assertRaises(M.L.LockError):lease.acquire()
        self.assertFalse(lease.created);self.assertEqual(path.read_bytes(),b'competing creator')
    def test_preexisting_writer_refused(self):
        k=M.L._kernel();h=k.CreateFileW(str(self.path),0x40000000,7,None,3,0x80,None)
        self.assertNotEqual(h,ctypes.c_void_p(-1).value)
        try:
            with self.assertRaises(M.L.LockError):self.lease().acquire()
        finally:self.assertTrue(k.CloseHandle(h))
        self.assertEqual(self.path.read_bytes(),b'original long bytes')
    def test_snapshot_root_marker_and_path_refusals(self):
        for field in ('device','inode','size','sha256'):
            expected=copy.deepcopy(self.expected)
            if field=='sha256':expected[field]='0'*64
            else:expected['identity'][field]+=1
            with self.subTest(field=field),self.assertRaises(ValueError):self.lease(expected=expected).acquire()
        ident=dict(self.ident);ident['inode']+=1
        with self.assertRaises(ValueError):M.DestinationLease(self.root,ident,'caps.txt',self.expected,b'fenced exact\n').acquire()
        for name in ('../caps.txt','Scripts/main.lua','.settings-cutover','async-trial/../caps.txt'):
            with self.assertRaises(ValueError):self.lease(name)
        self.marker.write_bytes(b'wrong')
        with self.assertRaises(ValueError):self.lease('priorities.txt',{'state':'missing'}).acquire()
        self.assertFalse((self.mod/'priorities.txt').exists())
        self.marker.unlink()
        with self.assertRaises(OSError):self.lease().acquire()
        self.assertEqual(self.path.read_bytes(),b'original long bytes')
    def test_hardlink_and_reparse_refused(self):
        link=self.mod/'link';os.link(self.path,link)
        with self.assertRaises(ValueError):self.lease().acquire()
        link.unlink()
        target=self.root/'target';target.mkdir()
        trial=self.mod/'async-trial';trial.rmdir()
        result=subprocess.run(['cmd','/c','mklink','/J',str(trial),str(target)],capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        try:
            with self.assertRaises(ValueError):self.lease('async-trial/launch.lua',{'state':'missing'}).acquire()
            self.assertFalse((target/'launch.lua').exists())
        finally:trial.rmdir()
    def test_write_and_flush_failure_leave_fence_partial_and_no_retry(self):
        for fn in ('WriteFile','FlushFileBuffers'):
            with self.subTest(fn=fn):
                path=self.mod/'priorities.txt'
                if path.exists():path.unlink()
                with self.lease('priorities.txt',{'state':'missing'}) as lease:
                    with mock.patch.object(lease._k,fn,return_value=False),self.assertRaises(M.L.LockError):lease.overwrite(b'candidate')
                    self.assertTrue(lease.receipt()['failed']);self.assertIsNone(lease.receipt()['verified'])
                    with self.assertRaises(ValueError):lease.overwrite(b'retry')
                    self.assertEqual(lease.read(),b'' if fn=='WriteFile' else b'candidate')
                self.assertTrue(path.exists());self.assertEqual(self.marker.read_bytes(),b'fenced exact\n')
    def test_multiple_markers_compatible_and_partial_write_loop(self):
        with self.lease() as first,self.lease('priorities.txt',{'state':'missing'}) as second:
            original=first._k.WriteFile;calls=[]
            def partial(handle,buf,count,written,overlapped):
                calls.append(count);return original(handle,buf,min(count,2),written,overlapped)
            with mock.patch.object(first._k,'WriteFile',side_effect=partial):first.overwrite(b'abcdef')
            self.assertGreater(len(calls),1);self.assertEqual(first.read(),b'abcdef');second.overwrite(b'next')
    def test_failed_post_create_discloses_reservation(self):
        lease=self.lease('priorities.txt',{'state':'missing'});original=lease._info
        def info(h,directory):
            if h==lease._handle:raise ValueError('injected inspect failure')
            return original(h,directory)
        with mock.patch.object(lease,'_info',side_effect=info),self.assertRaises(ValueError):lease.acquire()
        self.assertTrue(lease.created);self.assertTrue(lease.receipt()['failed']);self.assertIsNone(lease.receipt()['identity'])
        self.assertEqual((self.mod/'priorities.txt').read_bytes(),b'');self.assertTrue(self.marker.exists())


    # Additional failure boundaries use the actual same-handle write path.
    def test_truncate_readback_and_partial_failure(self):
        for stage in ('truncate','readback','partial'):
            with self.subTest(stage=stage):
                self.path.write_bytes(b'original long bytes');self.expected=B.read_exact(self.path)
                with self.lease() as lease:
                    if stage=='truncate':patch=mock.patch.object(lease._k,'SetEndOfFile',return_value=False)
                    elif stage=='readback':patch=mock.patch.object(lease,'_read',return_value=b'wrong readback')
                    else:
                        original=lease._k.WriteFile;calls=[]
                        def fail_after_partial(h,buf,count,written,overlapped):
                            calls.append(1)
                            if len(calls)>1:return False
                            return original(h,buf,2,written,overlapped)
                        patch=mock.patch.object(lease._k,'WriteFile',side_effect=fail_after_partial)
                    with patch,self.assertRaises((M.L.LockError,ValueError)):lease.overwrite(b'changed bytes')
                    self.assertTrue(lease.receipt()['failed']);self.assertIsNone(lease.receipt()['verified'])
                    with self.assertRaises(ValueError):lease.overwrite(b'retry')
                self.assertTrue(self.marker.exists())
                self.assertNotEqual(self.path.read_bytes(),b'original long bytes')
        self.expected=B.read_exact(self.path)
        with self.lease() as lease:
            data=b'longer'*20000;lease.overwrite(data);self.assertEqual(lease.read(),data)


    def test_uncertain_release_retains_own_directory_and_marker_pins(self):
        code=r'''
    from pathlib import Path
    import sys
    sys.path.insert(0,sys.argv[1])
    import settings_destination_lease as M
    root=Path(sys.argv[2]);p=root/'mod'/'caps.txt'
    lease=M.DestinationLease(root,M.B.identity(root.stat()),'caps.txt',M.B.read_exact(p),b'fenced exact\n').acquire()
    lease._close=lambda h:False
    try:lease.release()
    except M.L.LockReleaseError:pass
    else:raise AssertionError('uncertain release accepted')
    for op in (lambda:root.rename(root.with_name(root.name+'-moved')),lambda:(root/'mod'/M.MARKER).unlink(),lambda:p.write_bytes(b'new')):
        try:op()
        except OSError:pass
        else:raise AssertionError('pins lost')
    try:lease.acquire()
    except M.L.LockError:pass
    else:raise AssertionError('reuse accepted')
    '''
        result=subprocess.run([sys.executable,'-B','-c',textwrap.dedent(code),str(ROOT/'tools'),str(self.root)],capture_output=True,text=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stderr)
        with self.lease() as lease:self.assertEqual(lease.read(),b'original long bytes')

if __name__=='__main__':unittest.main()
