"""Real Win32 handles and disposable child processes; no game/runtime actions."""
from pathlib import Path
import ctypes
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import settings_cutover_lock as L
import settings_cutover_fixture as C
try: from tests import test_settings_export_bundle as Fixtures
except ImportError: import test_settings_export_bundle as Fixtures

CHILD=r'''
import json,os,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import settings_cutover_fixture as C
f=object.__new__(C.Fixture)
f.root=Path(sys.argv[2]);f.target=f.root/'mod';f.root_id=json.loads(sys.argv[3]);f.plan_hash=sys.argv[4]
f.marker=('PWP-CUTOVER-FIXTURE-1\n'+f.plan_hash+'\n').encode()
f.hook=lambda label:None
if sys.argv[5]=='crash':
    def stop(label):
        if label==sys.argv[7]:os._exit(23)
    f.hook=stop
    getattr(f,sys.argv[6])()
    raise AssertionError('crash hook not reached')
from settings_cutover_lock import LockError
try:getattr(f,sys.argv[5])()
except LockError:print('LOCK_REFUSED')
else:raise AssertionError('competing driver admitted')
'''


@unittest.skipUnless(os.name=='nt','requires real Windows sharing semantics')
class WindowsLock(unittest.TestCase):
    def root(self):
        root=Path(tempfile.mkdtemp(prefix='pwp-cutover-fixture-'))
        identity=C.B.identity(root.stat())
        def cleanup():
            C.B.checked_path(root,directory=True)
            self.assertEqual(root.resolve().parent,Path(tempfile.gettempdir()).resolve())
            self.assertEqual(root.stat().st_ino,identity['inode'])
            shutil.rmtree(root)
        self.addCleanup(cleanup)
        return root,identity

    def fixture(self):
        source=Fixtures.Bundle();source.setUp();self.addCleanup(source.doCleanups);source.prepare()
        f=C.Fixture(source.destination);self.addCleanup(f.close);return f

    def child(self,f,*args):
        return subprocess.run([sys.executable,'-B','-c',CHILD,str(ROOT/'tools'),str(f.root),
                               json.dumps(f.root_id),f.plan_hash,*args],capture_output=True,text=True,timeout=30)

    def snapshot(self,f):return {n:f.read(n) for n in (*C.B.NAMES,*C.TRIAL,C.MARKER)}

    def test_real_exclusion_root_pin_noninherit_and_permanent_artifact(self):
        root,identity=self.root();renamed=root.with_name(root.name+'-moved')
        with L.TransactionLock(root,identity) as held:
            for handle in (*held._pins,held._lock_handle):
                flags=L.W.DWORD()
                self.assertTrue(held._k.GetHandleInformation(handle,ctypes.byref(flags)))
                self.assertEqual(flags.value&1,0)
            with self.assertRaises(L.LockError):L.TransactionLock(root,identity).acquire()
            with self.assertRaises(OSError):root.rename(renamed)
            with self.assertRaises(OSError):(root/L.NAME).unlink()
            with self.assertRaises(OSError):(root/L.NAME).write_bytes(b'cannot overwrite lock')
        self.assertTrue((root/L.NAME).is_file())
        inode=(root/L.NAME).stat().st_ino
        with L.TransactionLock(root,identity):pass
        self.assertEqual((root/L.NAME).stat().st_ino,inode)
        self.assertEqual((root/L.NAME).read_bytes(),b'')
        root.rename(renamed);renamed.rename(root)
        held.release() # idempotent, no duplicate CloseHandle
        with self.assertRaises(L.LockError):held.acquire()

    def test_directory_pins_block_root_and_parent_without_relying_on_lock_file(self):
        # Only owned disposable directories are rename targets, never system Temp.
        with tempfile.TemporaryDirectory() as container:
            parent=Path(container)/'owned-parent';parent.mkdir()
            root=parent/'pwp-cutover-fixture-pin';root.mkdir()
            identity=C.B.identity(root.stat())
            held=L.TransactionLock(root,identity)
            real_open=held._open
            def inspect_before_file(path,*args):
                if path==root/L.NAME:
                    self.assertFalse(path.exists())
                    for target in (root,parent):
                        with self.assertRaises(OSError):target.rename(target.with_name(target.name+'-moved'))
                return real_open(path,*args)
            with mock.patch.object(L.tempfile,'gettempdir',return_value=str(parent)):
                with mock.patch.object(held,'_open',side_effect=inspect_before_file):
                    with held:
                        for target in (root,parent):
                            with self.assertRaises(OSError):target.rename(target.with_name(target.name+'-moved'))
            moved=parent.with_name('released-parent');parent.rename(moved);moved.rename(parent)

    def test_reject_directory_hardlink_and_wrong_root_identity(self):
        root,identity=self.root();(root/L.NAME).mkdir()
        with self.assertRaises(ValueError):L.TransactionLock(root,identity).acquire()
        (root/L.NAME).rmdir()
        outside=root/'other';outside.write_bytes(b'preserve')
        os.link(outside,root/L.NAME)
        with self.assertRaisesRegex(ValueError,'hard-linked'):L.TransactionLock(root,identity).acquire()
        self.assertEqual(outside.read_bytes(),b'preserve');(root/L.NAME).unlink()
        with self.assertRaisesRegex(ValueError,'identity'):L.TransactionLock(root,{**identity,'inode':0}).acquire()
        self.assertFalse((root/L.NAME).exists())

    def test_reparse_lock_rejected_without_following(self):
        root,identity=self.root();other=root/'destination';other.mkdir()
        # Unprivileged directory junction, not a symlink requiring elevation.
        result=subprocess.run(['cmd','/c','mklink','/J',str(root/L.NAME),str(other)],
                              capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        try:
            with self.assertRaisesRegex(ValueError,'redirected'):L.TransactionLock(root,identity).acquire()
        finally:(root/L.NAME).rmdir() # removes only the test junction
        self.assertTrue(other.is_dir())

    def test_three_driver_wrappers_refuse_before_mutation(self):
        f=self.fixture();before=self.snapshot(f)
        with L.TransactionLock(f.root,f.root_id):
            for action in ('resume','rollback','resume_rollback'):
                result=self.child(f,action)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(result.stdout.strip(),'LOCK_REFUSED')
                self.assertEqual(before,self.snapshot(f))
            self.assertFalse((f.root/C.ROLLBACK_INTENT).exists())
            self.assertFalse((f.target/'.cutover-stage').exists())
        # Rollback delegates to a private helper under one acquisition, not two.
        f.resume();f.rollback();self.assertTrue(f.resume_rollback()['complete'])
        with self.assertRaisesRegex(ValueError,'rollback direction'):f.resume()

    def test_hook_exception_and_reentry_release(self):
        f=self.fixture();entered=[]
        def hook(label):
            if label=='before-stage:'+C.MARKER:
                with self.assertRaises(L.LockError):f.resume()
                entered.append(label);raise OSError('injected hook')
        f.hook=hook
        with self.assertRaisesRegex(OSError,'injected hook'):f.resume()
        self.assertEqual(len(entered),1)
        with L.TransactionLock(f.root,f.root_id):pass
        f.hook=lambda _:None;self.assertTrue(f.resume()['complete'])

    def test_process_exit_releases_lock_preserves_forward_and_rollback_recovery(self):
        f=self.fixture()
        for action,boundary,recover in (
                ('resume','after-replace:caps.txt',f.resume),
                ('rollback','rollback:after-replace:caps.txt',f.resume_rollback)):
            result=self.child(f,'crash',action,boundary)
            self.assertEqual(result.returncode,23,result.stderr)
            self.assertIsNotNone(f.read(C.MARKER))
            self.assertTrue((f.root/L.NAME).exists())
            self.assertTrue(recover()['complete'])
        for n,raw in f._plan()['original'].items():self.assertEqual(f.read(n),C.decoded(raw))

    def test_release_failure_poisoned_until_process_exit(self):
        # Inject CloseHandle failure in a child: uncertain handles are intentionally
        # retained there; process exit is the only cleanup, never blind retries.
        root,identity=self.root()
        code=r'''
import json,sys
sys.path.insert(0,sys.argv[1])
import settings_cutover_lock as L
lock=L.TransactionLock(sys.argv[2],json.loads(sys.argv[3])).acquire()
lock._close=lambda handle:False
for action in (lock.release,lock.release,lambda:L.TransactionLock(sys.argv[2],json.loads(sys.argv[3])).acquire()):
    try:action()
    except L.LockError:pass
    else:raise AssertionError('uncertain release accepted')
assert lock._root_handle is not None and lock._lock_handle is not None
print('POISONED')
'''
        result=subprocess.run([sys.executable,'-B','-c',code,str(ROOT/'tools'),str(root),json.dumps(identity)],
                              capture_output=True,text=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stdout.strip(),'POISONED')
        with L.TransactionLock(root,identity):pass


if __name__=='__main__':unittest.main()
