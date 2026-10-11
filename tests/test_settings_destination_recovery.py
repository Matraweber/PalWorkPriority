from pathlib import Path
import json
import os
import subprocess
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
import settings_destination_recovery as R
from tests import test_settings_export_bundle as Sources

CHILD=r'''
from pathlib import Path
import json,os,sys
sys.path.insert(0,sys.argv[1])
import settings_destination_recovery as R
f=R.C.Fixture.__new__(R.C.Fixture);f.root=Path(sys.argv[2]);f.target=f.root/'mod'
f.root_id=json.loads(sys.argv[3]);f.plan_hash=sys.argv[4]
f.marker=('PWP-CUTOVER-FIXTURE-1\n'+f.plan_hash+'\n').encode()
f.plan=json.loads((f.root/'plan.json').read_text())
def hook(label):
    if label==sys.argv[5]:os._exit(74)
if sys.argv[5]=='recover':print(json.dumps(R.resume(f)))
else:R.F.run(f,hook,staged=True)
'''


@unittest.skipUnless(os.name=='nt','real Windows handles required')
class Recovery(unittest.TestCase):
    def setUp(self):
        self.source=Sources.Bundle();self.source.setUp();self.addCleanup(self.source.doCleanups)
        self.source.prepare();self.before=self.source.originals()

    def fixture(self):
        f=R.C.Fixture(self.source.destination);self.addCleanup(f.close);return f

    def child(self,f,boundary):
        return subprocess.run([sys.executable,'-B','-c',CHILD,str(ROOT/'tools'),str(f.root),
            json.dumps(f.root_id),f.plan_hash,boundary],capture_output=True,text=True,timeout=30)

    def interrupted(self,boundary):
        f=self.fixture();p=self.child(f,boundary)
        self.assertEqual(p.returncode,74,p.stderr);return f

    def state(self,f):return {n:f.read(n) for n in (*R.B.NAMES,*R.C.TRIAL,R.C.MARKER)}

    def complete(self,f):
        for n in R.B.NAMES:self.assertEqual(f.read(n),R.C.decoded(f.plan['desired'][n]))
        for n in R.C.TRIAL:self.assertEqual(f.read(n),R.C.decoded(f.plan['original'][n]))
        self.assertEqual(f.read(R.C.MARKER),f.marker)
        self.assertEqual(self.source.originals(),self.before)

    def test_receipt_precedes_publish_and_fresh_process_recovers_missing_post_receipt(self):
        f=self.interrupted('after-publish:priorities.txt.tmp')
        self.assertFalse((f.root/'reserved-priorities.txt.tmp.json').exists())
        record=json.loads((f.root/'staged-priorities.txt.tmp.json').read_text())
        self.assertEqual(record['identity']['inode'],(f.target/'priorities.txt.tmp').stat().st_ino)
        self.assertFalse((f.root/record['stage_basename']).exists())
        p=self.child(f,'recover');self.assertEqual(p.returncode,0,p.stderr)
        self.assertTrue(json.loads(p.stdout)['candidate_copies_verified']);self.complete(f)
        self.assertTrue(R.resume(f)['candidate_copies_verified']);self.complete(f)

    def test_orphan_scratch_before_receipt_never_owns_destination(self):
        f=self.interrupted('after-scratch:priorities.txt.tmp')
        orphans=list(f.root.glob('.settings-reservation-*.stage'));self.assertEqual(len(orphans),1)
        self.assertIsNone(f.read('priorities.txt.tmp'))
        self.assertFalse((f.root/'staged-priorities.txt.tmp.json').exists())
        self.assertTrue(R.resume(f)['candidate_copies_verified']);self.complete(f)
        self.assertEqual(orphans[0].read_bytes(),b'') # Preserved, not adopted/deleted.

    def test_prepared_unpublished_stage_recovers_same_identity_in_fresh_process(self):
        f=self.interrupted('before-publish:priorities.txt.tmp')
        record=json.loads((f.root/'staged-priorities.txt.tmp.json').read_text())
        self.assertTrue((f.root/record['stage_basename']).exists())
        self.assertIsNone(f.read('priorities.txt.tmp'))
        child=self.child(f,'recover');self.assertEqual(child.returncode,0,child.stderr)
        self.complete(f)
        self.assertEqual((f.target/'priorities.txt.tmp').stat().st_ino,record['identity']['inode'])
        self.assertFalse((f.root/record['stage_basename']).exists())

    def test_prepared_stage_replacement_or_changed_bytes_are_preserved(self):
        for mode in ('replacement','changed'):
            with self.subTest(mode=mode):
                f=self.interrupted('before-publish:priorities.txt.tmp')
                record=json.loads((f.root/'staged-priorities.txt.tmp.json').read_text())
                stage=f.root/record['stage_basename']
                if mode=='replacement':
                    other=f.root/'foreign-stage';other.write_bytes(b'');os.replace(other,stage)
                else:stage.write_bytes(b'foreign edit')
                before=self.state(f);stage_before=stage.read_bytes()
                with self.assertRaises(ValueError):R.resume(f)
                self.assertEqual(before,self.state(f));self.assertEqual(stage.read_bytes(),stage_before)

    def test_replacement_with_identical_bytes_and_same_object_newer_edit_refused(self):
        for mode in ('replacement','newer'):
            with self.subTest(mode=mode):
                f=self.interrupted('after-publish:priorities.txt.tmp')
                if mode=='replacement':
                    other=f.root/'foreign';other.write_bytes(b'');os.replace(other,f.target/'priorities.txt.tmp')
                else:(f.target/'caps.txt').write_bytes(b'newer unrelated edit')
                before=self.state(f)
                with self.assertRaises(ValueError):R.resume(f)
                self.assertEqual(before,self.state(f))

    def test_receipt_scope_tamper_and_duplicate_fields_refused(self):
        for mode in ('plan','name','stage','duplicate'):
            with self.subTest(mode=mode):
                f=self.interrupted('after-publish:priorities.txt.tmp')
                path=f.root/'staged-priorities.txt.tmp.json';record=json.loads(path.read_text())
                if mode=='plan':record['plan_sha256']='0'*64
                elif mode=='name':record['name']='caps.txt'
                elif mode=='stage':record['stage_basename']='../../unrelated'
                if mode=='duplicate':path.write_text('{"nonce":"foreign",'+json.dumps(record)[1:])
                else:path.write_text(json.dumps(record))
                before=self.state(f)
                with self.assertRaises(ValueError):R.resume(f)
                self.assertEqual(before,self.state(f))

    def test_later_edit_during_recovery_admission_refuses_before_payload_writes(self):
        f=self.interrupted('after-publish:priorities.txt.tmp')
        def hook(label):
            if label=='recovery-validated':(f.target/'caps.txt').write_bytes(b'late newer edit')
        with self.assertRaises(ValueError):R.resume(f,hook)
        self.assertEqual(f.read('caps.txt'),b'late newer edit')
        self.assertEqual(f.read('priorities.txt'),R.C.decoded(f.plan['original']['priorities.txt']))
        self.assertEqual(f.read(R.C.MARKER),f.marker)

    def test_known_completed_payload_after_crash_is_recoverable(self):
        f=self.interrupted('after-write:priorities.txt')
        self.assertTrue(R.resume(f)['candidate_copies_verified']);self.complete(f)

    def test_plan_changed_before_snapshot_cannot_be_accepted_as_fresh_baseline(self):
        f=self.interrupted('after-publish:priorities.txt.tmp');before=self.state(f)
        def hook(label):
            if label=='recovery-before-metadata':
                path=f.root/'plan.json';path.write_bytes(path.read_bytes()+b' ')
        with self.assertRaisesRegex(ValueError,'plan changed'):R.resume(f,hook)
        self.assertEqual(before,self.state(f))

    def test_originally_absent_trial_appearing_before_write_or_completion_is_preserved(self):
        for boundary in ('before-recovery-write:priorities.txt','after-recovery-write:caps.txt.bak'):
            with self.subTest(boundary=boundary):
                source=Sources.Bundle();source.setUp();self.addCleanup(source.doCleanups)
                for name in R.C.TRIAL:(source.source/name).unlink()
                source.prepare();f=R.C.Fixture(source.destination);self.addCleanup(f.close)
                child=self.child(f,'after-publish:priorities.txt.tmp');self.assertEqual(child.returncode,74,child.stderr)
                def hook(label):
                    if label==boundary:(f.target/R.C.TRIAL[0]).write_bytes(b'new competing trial')
                with self.assertRaisesRegex(ValueError,'trial changed during recovery'):R.resume(f,hook)
                self.assertEqual(f.read(R.C.TRIAL[0]),b'new competing trial')
                self.assertEqual(f.read(R.C.MARKER),f.marker)
                self.assertEqual(list(f.root.glob('recovered-*.json')),[])
                if boundary.startswith('before-'):
                    self.assertEqual(f.read('priorities.txt'),R.C.decoded(f.plan['original']['priorities.txt']))


if __name__=='__main__':unittest.main()
