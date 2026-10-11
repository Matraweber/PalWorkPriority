"""Real Windows file-sharing checks in disposable directories only."""
from pathlib import Path
import copy
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
import settings_inventory_pins as M
import settings_installation_binding as Binding


@unittest.skipUnless(os.name=='nt','real Win32 handles required')
class Pins(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.parent=Path(self.temp.name);self.root=self.parent/'owned';self.root.mkdir()
        self.sub=self.root/'Scripts';self.sub.mkdir()
        self.file=self.sub/'main.lua';self.file.write_bytes(b'original reviewed code')
        self.files={self.file:Binding._digest(self.file)}
        self.directories={p:Binding._directory(p) for p in (self.root,self.sub)}

    def test_readonly_recheck_and_no_writer_delete_replace(self):
        baseline=Binding._tree(self.root,None)
        replacement=self.root/'replacement';replacement.write_bytes(b'other')
        with M.InventoryPins(self.files,self.directories) as guard:
            for handle in guard._handles:
                flags=M.L.W.DWORD()
                self.assertTrue(guard._k.GetHandleInformation(handle,M.ctypes.byref(flags)))
                self.assertEqual(flags.value&1,0)
            self.assertEqual(Binding._digest(self.file),self.files[self.file])
            # Ignore this test's replacement input when comparing the tree.
            current=Binding._tree(self.root,None);current.pop('replacement')
            self.assertEqual(current,baseline)
            for action in (lambda:self.file.write_bytes(b'new'),lambda:self.file.unlink(),
                           lambda:self.file.rename(self.sub/'renamed.lua'),lambda:os.replace(replacement,self.file)):
                with self.assertRaises(OSError):action()
            for directory in (self.sub,self.root,self.parent):
                with self.assertRaises(OSError):directory.rename(directory.with_name(directory.name+'-moved'))
        self.file.write_bytes(b'after release');guard.release()
        with self.assertRaises(M.L.LockError):guard.acquire()

    def test_fresh_child_write_delete_and_replace_refused(self):
        code=r'''
from pathlib import Path
import os,sys
p=Path(sys.argv[1]);replacement=Path(sys.argv[2])
for action in (lambda:p.write_bytes(b'child edit'),lambda:p.unlink(),lambda:os.replace(replacement,p)):
    try:action()
    except OSError:pass
    else:raise AssertionError('child writer admitted')
print('REFUSED')
'''
        other=self.root/'other';other.write_bytes(b'other')
        with M.InventoryPins(self.files,self.directories):
            result=subprocess.run([sys.executable,'-B','-c',code,str(self.file),str(other)],
                                  capture_output=True,text=True,timeout=20)
            self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stdout.strip(),'REFUSED')
        self.assertEqual(self.file.read_bytes(),b'original reviewed code')

    def test_preexisting_writer_handle_conflicts_without_truncating(self):
        k=M.L._kernel()
        writer=k.CreateFileW(str(self.file),0x40000000,7,None,3,0x80,None)
        self.assertNotEqual(writer,M.ctypes.c_void_p(-1).value)
        try:
            with self.assertRaises(M.L.LockError):M.InventoryPins(self.files,self.directories).acquire()
        finally:self.assertTrue(k.CloseHandle(writer))
        with M.InventoryPins(self.files,self.directories):pass
        self.assertEqual(self.file.read_bytes(),b'original reviewed code')

    def test_identity_size_hash_and_input_mutation(self):
        for field in ('device','inode','size','sha256'):
            files=copy.deepcopy(self.files)
            if field=='sha256':files[self.file][field]='0'*64
            else:files[self.file]['identity'][field]+=1
            with self.subTest(field=field),self.assertRaises(ValueError):M.InventoryPins(files,self.directories).acquire()
            self.file.write_bytes(b'original reviewed code') # no leaked pin after failed acquire
        self.files={self.file:Binding._digest(self.file)}
        wrong=copy.deepcopy(self.directories);wrong[self.sub]['inode']+=1
        with self.assertRaisesRegex(ValueError,'identity'):M.InventoryPins(self.files,wrong).acquire()
        guard=M.InventoryPins(self.files,self.directories)
        self.files[self.file]['sha256']='0'*64;self.directories[self.sub]['inode']=1
        with guard:pass # constructor captures scalars, not mutable caller records

    def test_additions_are_allowed_but_detectable_by_recheck(self):
        baseline=Binding._tree(self.root,None)
        with M.InventoryPins(self.files,self.directories):
            (self.sub/'new.lua').write_bytes(b'new child is NOT excluded')
            self.assertNotEqual(Binding._tree(self.root,None),baseline)
            self.assertEqual(self.file.read_bytes(),b'original reviewed code')

    def test_hardlink_and_redirect_refused(self):
        alias=self.root/'alias';os.link(self.file,alias)
        with self.assertRaisesRegex(ValueError,'hard-linked'):M.InventoryPins(self.files,self.directories).acquire()
        alias.unlink()
        redirected=self.root/'junction'
        result=subprocess.run(['cmd','/c','mklink','/J',str(redirected),str(self.sub)],capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        try:
            dirs={self.root:self.directories[self.root],redirected:dict(self.directories[self.sub])}
            files={redirected/'main.lua':self.files[self.file]}
            with self.assertRaisesRegex(ValueError,'redirected'):M.InventoryPins(files,dirs).acquire()
        finally:redirected.rmdir()

    def test_partial_acquire_failure_and_context_error_release_all(self):
        other=self.sub/'second.lua';other.write_bytes(b'second')
        files={**self.files,other:Binding._digest(other)};files[other]['sha256']='0'*64
        with self.assertRaisesRegex(ValueError,'hash differs'):M.InventoryPins(files,self.directories).acquire()
        self.file.write_bytes(b'original reviewed code');other.unlink()
        self.files={self.file:Binding._digest(self.file)}
        with self.assertRaisesRegex(RuntimeError,'body failed'):
            with M.InventoryPins(self.files,self.directories):raise RuntimeError('body failed')
        self.file.unlink()

    def test_uncertain_file_release_retains_directories_until_process_exit(self):
        code=r'''
import json,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import settings_inventory_pins as M
files={Path(k):v for k,v in json.loads(sys.argv[2]).items()}
dirs={Path(k):v for k,v in json.loads(sys.argv[3]).items()}
guard=M.InventoryPins(files,dirs).acquire();count=len(guard._handles)
guard._close=lambda h:False
for action in (guard.release,guard.release,lambda:M.InventoryPins(files,dirs).acquire()):
    try:action()
    except M.L.LockError:pass
    else:raise AssertionError('uncertainty admitted')
assert len(guard._handles)==count
for p in dirs:
    try:p.rename(p.with_name(p.name+'-moved'))
    except OSError:pass
    else:raise AssertionError('directory pin lost')
print('RETAINED')
'''
        result=subprocess.run([sys.executable,'-B','-c',code,str(ROOT/'tools'),
                               json.dumps({str(k):v for k,v in self.files.items()}),
                               json.dumps({str(k):v for k,v in self.directories.items()})],
                              capture_output=True,text=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stdout.strip(),'RETAINED')
        # Child exit (no release retry) releases the actual OS handles.
        with M.InventoryPins(self.files,self.directories):pass
        self.file.write_bytes(b'after child exit')

    def test_bounds_missing_parent_and_malformed_inputs_before_open(self):
        with mock.patch.object(M.InventoryPins,'_open',side_effect=AssertionError('unexpected IO')):
            for files,dirs in (({},self.directories),(self.files,{}),
                               (self.files,{self.root:self.directories[self.root]}),
                               ({Path('relative.lua'):next(iter(self.files.values()))},self.directories)):
                with self.assertRaises(ValueError):M.InventoryPins(files,dirs)
            with mock.patch.object(M,'MAX_FILES',0):
                with self.assertRaises(ValueError):M.InventoryPins(self.files,self.directories)
            with mock.patch.object(M,'MAX_FILE_BYTES',1):
                with self.assertRaises(ValueError):M.InventoryPins(self.files,self.directories)
            with mock.patch.object(M,'MAX_TOTAL_BYTES',1):
                with self.assertRaises(ValueError):M.InventoryPins(self.files,self.directories)


if __name__=='__main__':unittest.main()
