from pathlib import Path
import ctypes
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
import settings_staged_reservation as M
B=M.B

@unittest.skipUnless(os.name=='nt','real Win32 required')
class Staged(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='pwp-cutover-fixture-');self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.mod=self.root/'mod';self.mod.mkdir();(self.mod/'async-trial').mkdir()
        self.marker=self.mod/'.settings-cutover';self.marker.write_bytes(b'fenced\n')
        self.identity=B.identity(self.root.stat());self.path=self.mod/'caps.txt'
    def new(self):return M.StagedReservation(self.root,self.identity,'caps.txt','a'*64,b'fenced\n')
    def test_identity_same_handle_receipt_precedes_publication(self):
        s=self.new()
        with s:
            handle=s._handle
            self.assertFalse(self.path.exists());self.assertTrue(s.stage_path.exists())
            with self.assertRaises(ValueError):s.publish()
            with self.assertRaises(ValueError):s.overwrite(b'early')
            record=s.prepare_receipt()
            self.assertEqual(json.loads(s.receipt_path.read_bytes()),record)
            self.assertEqual(record['identity']['inode'],s.stage_path.stat().st_ino)
            with self.assertRaises(OSError):s.stage_path.read_bytes() # existing DELETE access, ordinary reader lacks shareDELETE
            s.publish();self.assertEqual(s._handle,handle)
            self.assertFalse(s.stage_path.exists());self.assertEqual(self.path.stat().st_ino,record['identity']['inode'])
            self.assertEqual(s.read(),b'')
            with self.assertRaises(OSError):self.path.read_bytes()
            s.overwrite(b'payload');self.assertEqual(s.read(),b'payload')
            with self.assertRaises(OSError):self.marker.unlink()
        self.assertEqual(self.path.read_bytes(),b'payload');self.assertTrue(self.marker.exists())
    def test_competing_destination_winner_never_replaced(self):
        with self.new() as s:
            s.prepare_receipt();self.path.write_bytes(b'winner')
            with self.assertRaises(M.L.LockError):s.publish()
            self.assertEqual(self.path.read_bytes(),b'winner');self.assertTrue(s.stage_path.exists())
            self.assertFalse(s.published)
            with self.assertRaises(ValueError):s.publish()
        self.assertEqual(self.path.read_bytes(),b'winner')
    def test_receipt_failures_never_publish(self):
        for stage in ('write','flush','readback'):
            with self.subTest(stage=stage):
                s=self.new()
                with s:
                    if stage=='write':patch=mock.patch.object(s._k,'WriteFile',return_value=False)
                    elif stage=='flush':
                        original=s._k.FlushFileBuffers
                        patch=mock.patch.object(s._k,'FlushFileBuffers',side_effect=lambda h:False if h==s._receipt_handle else original(h))
                    else:
                        original=s._read
                        patch=mock.patch.object(s,'_read',side_effect=lambda h,n:b'bad' if h==s._receipt_handle else original(h,n))
                    with patch,self.assertRaises((M.L.LockError,ValueError)):s.prepare_receipt()
                    with self.assertRaises(ValueError):s.publish()
                    self.assertFalse(self.path.exists());self.assertTrue(s.stage_path.exists());self.assertTrue(self.marker.exists())
                s.receipt_path.unlink() # disposable test resets between independent fault cases
    def test_receipt_collision_preserved_and_no_reuse(self):
        s=self.new();s.receipt_path.write_bytes(b'existing evidence')
        with s:
            with self.assertRaises(M.L.LockError):s.prepare_receipt()
            with self.assertRaises(ValueError):s.publish()
        self.assertEqual(s.receipt_path.read_bytes(),b'existing evidence');self.assertFalse(self.path.exists())
        with self.assertRaises(M.L.LockError):s.acquire()
    def test_wrong_root_marker_path_and_redirects(self):
        bad=dict(self.identity);bad['inode']+=1
        with self.assertRaises(ValueError):M.StagedReservation(self.root,bad,'caps.txt','a'*64,b'fenced\n').acquire()
        with self.assertRaises(ValueError):M.StagedReservation(self.root,self.identity,'../caps.txt','a'*64,b'fenced\n')
        with self.assertRaises(ValueError):M.StagedReservation(self.root.parent,self.identity,'caps.txt','a'*64,b'fenced\n')
        s=self.new();self.marker.write_bytes(b'wrong')
        with self.assertRaises(ValueError):s.acquire()
        self.assertFalse(s.stage_path.exists())
        self.marker.write_bytes(b'fenced\n');os.link(self.marker,self.mod/'marker-hardlink')
        with self.assertRaises(ValueError):self.new().acquire()
        (self.mod/'marker-hardlink').unlink()
        trial=self.mod/'async-trial';trial.rmdir();target=self.root/'other';target.mkdir()
        r=subprocess.run(['cmd','/c','mklink','/J',str(trial),str(target)],capture_output=True)
        self.assertEqual(r.returncode,0,r.stderr)
        try:
            with self.assertRaises(ValueError):M.StagedReservation(self.root,self.identity,'async-trial/launch.lua','a'*64,b'fenced\n').acquire()
        finally:trial.rmdir()
    def test_stage_hardlink_rejected_before_receipt(self):
        with self.new() as s:
            # If filesystem permits link creation while handle held, inspection must reject it.
            link=self.root/'stage-link'
            try:os.link(s.stage_path,link)
            except OSError:return
            with self.assertRaises(ValueError):s.prepare_receipt()
            self.assertFalse(self.path.exists())
    def test_abrupt_exit_before_and_after_publish(self):
        code=r'''
from pathlib import Path
import os,sys
sys.path.insert(0,sys.argv[1])
import settings_staged_reservation as M
root=Path(sys.argv[2]);s=M.StagedReservation(root,M.B.identity(root.stat()),'caps.txt','a'*64,b'fenced\n')
s.acquire()
if sys.argv[3]=='scratch':os._exit(0)
s.prepare_receipt()
if sys.argv[3]=='after':s.publish()
os._exit(0)
'''
        for phase in ('scratch','before','after'):
            with self.subTest(phase=phase):
                r=subprocess.run([sys.executable,'-B','-c',code,str(ROOT/'tools'),str(self.root),phase],capture_output=True,text=True,timeout=20)
                self.assertEqual(r.returncode,0,r.stderr)
                if phase=='scratch':
                    self.assertFalse(self.path.exists())
                    self.assertFalse((self.root/'staged-caps.txt.json').exists())
                    stages=list(self.root.glob('.settings-reservation-*.stage'))
                    self.assertEqual(len(stages),1);self.assertEqual(stages[0].read_bytes(),b'')
                    stages[0].unlink()
                    continue
                receipt=self.root/'staged-caps.txt.json';record=json.loads(receipt.read_bytes())
                stage=self.root/record['stage_basename'];current=stage if phase=='before' else self.path
                self.assertEqual(record['plan_sha256'],'a'*64)
                self.assertEqual(record['root_identity'],{k:self.identity[k] for k in ('device','inode')})
                self.assertEqual(record['identity']['inode'],current.stat().st_ino)
                self.assertEqual(current.read_bytes(),b'')
                self.assertEqual(self.path.exists(),phase=='after');self.assertEqual(stage.exists(),phase=='before')
                self.assertEqual(self.marker.read_bytes(),b'fenced\n')
                current.unlink();receipt.unlink() # independent disposable crash case
    def test_child_mutations_refused_after_rename(self):
        code=r'''
from pathlib import Path
import os,sys
p=Path(sys.argv[1]);other=p.parent/'other';other.write_bytes(b'other')
for op in (lambda:p.write_bytes(b'edit'),lambda:p.unlink(),lambda:os.replace(other,p)):
    try:op()
    except OSError:pass
    else:raise AssertionError('competing writer admitted')
'''
        with self.new() as s:
            s.prepare_receipt();s.publish()
            r=subprocess.run([sys.executable,'-B','-c',code,str(self.path)],capture_output=True,text=True,timeout=20)
            self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(s.read(),b'')


    def prepared(self):
        s=self.new()
        with s:s.prepare_receipt()
        return s
    def recovered(self):return M.RecoveredReservation(self.root,self.identity,'caps.txt','a'*64,b'fenced\n')
    def test_recovered_readonly_receipt_pins_and_same_handle_publish(self):
        import settings_inventory_pins as P
        s=self.prepared();record=json.loads(s.receipt_path.read_bytes())
        before=s.receipt_path.read_bytes()
        with P.InventoryPins({s.receipt_path:B.read_exact(s.receipt_path)},{self.root:self.identity}):
            with self.recovered() as r:
                h=r._handle;self.assertEqual(r.read(),b'');self.assertFalse(r.scratch_created)
                self.assertEqual(r.receipt()['publication_record'],record)
                r.publish();self.assertEqual(r._handle,h);r.overwrite(b'candidate')
                self.assertEqual(r.read(),b'candidate')
        self.assertEqual(s.receipt_path.read_bytes(),before)
        self.assertEqual(self.path.stat().st_ino,record['identity']['inode'])
        self.assertEqual(self.path.read_bytes(),b'candidate')
    def test_recovered_schema_scope_rejects_mutants_and_duplicate_json(self):
        import copy
        s=self.prepared();raw=s.receipt_path.read_bytes();record=json.loads(raw)
        changes=[('contract','wrong'),('root_name','other'),('plan_sha256','b'*64),('name','priorities.txt'),
                 ('nonce','0'*32),('stage_basename','../outside'),('initial_sha256','b'*64),
                 ('marker_sha256','b'*64),('activation_allowed',True),('ownership_granted',0),
                 ('root_identity',{'device':True,'inode':self.identity['inode']}),
                 ('identity',dict(record['identity'],size=False)),('extra',False)]
        for key,value in changes:
            mutated=copy.deepcopy(record);mutated[key]=value
            s.receipt_path.write_bytes((json.dumps(mutated,sort_keys=True,separators=(',',':'))+'\n').encode())
            with self.subTest(field=key),self.assertRaises(ValueError):self.recovered().acquire()
            self.assertFalse(self.path.exists());self.assertTrue(s.stage_path.exists())
        for bad in (raw[:-2],raw.replace(b'{',b'{"name":"caps.txt",',1),raw+b' '):
            s.receipt_path.write_bytes(bad)
            with self.assertRaises(ValueError):self.recovered().acquire()
        s.receipt_path.write_bytes(raw)
    def test_recovered_foreign_empty_object_and_nonempty_refused(self):
        s=self.prepared();held=self.root/'preserved-stage';s.stage_path.rename(held);s.stage_path.write_bytes(b'')
        with self.assertRaises(ValueError):self.recovered().acquire()
        self.assertEqual(s.stage_path.read_bytes(),b'');self.assertFalse(self.path.exists())
        s.stage_path.unlink();held.rename(s.stage_path);s.stage_path.write_bytes(b'partial')
        with self.assertRaises(ValueError):self.recovered().acquire()
        self.assertEqual(s.stage_path.read_bytes(),b'partial')
    def test_recovered_hardlinks_and_competing_publication(self):
        s=self.prepared();link=self.root/'linked-receipt';os.link(s.receipt_path,link)
        with self.assertRaises(ValueError):self.recovered().acquire()
        link.unlink();os.link(s.stage_path,link)
        with self.assertRaises(ValueError):self.recovered().acquire()
        link.unlink()
        with self.recovered() as r:
            self.path.write_bytes(b'winner')
            with self.assertRaises(M.L.LockError):r.publish()
            self.assertTrue(s.stage_path.exists())
        self.assertEqual(self.path.read_bytes(),b'winner')
    def test_fresh_process_recovers_prepared_stage(self):
        s=self.prepared();record=json.loads(s.receipt_path.read_bytes())
        code=r'''
from pathlib import Path
import sys
sys.path.insert(0,sys.argv[1])
import settings_staged_reservation as M
root=Path(sys.argv[2])
with M.RecoveredReservation(root,M.B.identity(root.stat()),'caps.txt','a'*64,b'fenced\n') as r:
    r.publish();r.overwrite(b'recovered candidate')
'''
        r=subprocess.run([sys.executable,'-B','-c',code,str(ROOT/'tools'),str(self.root)],capture_output=True,text=True,timeout=20)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(self.path.stat().st_ino,record['identity']['inode'])
        self.assertEqual(self.path.read_bytes(),b'recovered candidate');self.assertTrue(self.marker.exists())
    def test_rename_succeeds_then_raises_keeps_receipt_bound_object(self):
        s=self.prepared();record=json.loads(s.receipt_path.read_bytes())
        with self.recovered() as r:
            original=r._rename
            def uncertain():original();raise OSError('after actual rename')
            with mock.patch.object(r,'_rename',side_effect=uncertain),self.assertRaises(OSError):r.publish()
            self.assertFalse(r.published);self.assertTrue(r.receipt()['failed'])
            self.assertFalse(s.stage_path.exists());self.assertEqual(self.path.stat().st_ino,record['identity']['inode'])
        self.assertEqual(self.path.read_bytes(),b'')
        with self.assertRaises(ValueError):self.recovered().acquire() # use explicit published assessment, not retry

if __name__=='__main__':unittest.main()
