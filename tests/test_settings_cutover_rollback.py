"""Disposable-only rollback faults; no game paths, process queries or journals written."""
from pathlib import Path
import json
import subprocess
import sys
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import settings_cutover_fixture as C
try: from tests import test_settings_export_bundle as Fixtures
except ImportError: import test_settings_export_bundle as Fixtures


class Rollback(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source=Fixtures.Bundle();cls.source.setUp()
        cls.addClassCleanup(cls.source.doCleanups)
        cls.source.prepare();cls.source_bytes=cls.source.originals()

    def fixture(self,complete=True,bundle=None):
        f=C.Fixture(bundle or self.source.destination);self.addCleanup(f.close)
        if complete:f.resume()
        return f

    def snapshot(self,f):
        return {n:f.read(n) for n in (*C.B.NAMES,*C.TRIAL,C.MARKER)}

    def restored(self,f):
        p=f._plan()
        for n,raw in p['original'].items():self.assertEqual(f.read(n),C.decoded(raw),n)
        self.assertIsNone(f.read(C.MARKER))
        self.assertEqual((f.root/C.ROLLBACK_INTENT).read_bytes(),f._intent_bytes())
        before=self.snapshot(f)
        for action in (f.resume,f.state):
            with self.assertRaisesRegex(ValueError,'rollback direction'):action()
            self.assertEqual(self.snapshot(f),before)
        self.assertEqual(self.source.originals(),self.source_bytes)

    def stop_at(self,f,boundary,action):
        def stop(label):
            if label==boundary:raise OSError('injected interruption')
        f.hook=stop
        with self.assertRaisesRegex(OSError,'injected'):action()
        f.hook=lambda _:None

    def test_exact_restore_idempotence_and_explicit_direction(self):
        f=self.fixture()
        with self.assertRaisesRegex(ValueError,'intent missing'):f.resume_rollback()
        result=f.rollback();self.assertTrue(result['complete']);self.assertEqual(result['direction'],'rollback')
        for field in ('live_cutover_allowed','replacement_allowed','ownership_verified','deletion_coverage_verified'):
            self.assertIs(result[field],False)
        self.restored(f)
        before=self.snapshot(f)
        self.assertEqual(f.resume_rollback(),result);self.assertEqual(f.rollback(),result)
        self.assertEqual(before,self.snapshot(f))

    def test_admission_requires_exact_completed_state(self):
        for mode in ('pristine','partial','newer','deleted','trial','foreign_fence'):
            with self.subTest(mode=mode):
                f=self.fixture(complete=mode not in ('pristine','partial'))
                if mode=='partial':self.stop_at(f,'after-replace:caps.txt',f.resume)
                elif mode=='newer':(f.target/'priorities.txt').write_bytes(C.envelope(Fixtures.P+b'mine|1|1\n',100))
                elif mode=='deleted':(f.target/'caps.txt').unlink()
                elif mode=='trial':(f.target/C.TRIAL[0]).write_bytes(b'new launcher')
                elif mode=='foreign_fence':(f.target/C.MARKER).write_bytes(b'foreign')
                before=self.snapshot(f)
                with self.assertRaises(ValueError):f.rollback()
                self.assertEqual(before,self.snapshot(f));self.assertFalse((f.root/C.ROLLBACK_INTENT).exists())

    def test_every_hook_boundary_recovers_from_disk(self):
        f=self.fixture();labels=[];f.hook=labels.append;f.rollback();self.restored(f)
        self.assertEqual(len(labels),38)
        for label in labels:
            with self.subTest(boundary=label):
                trial=self.fixture();self.stop_at(trial,label,trial.rollback)
                if (trial.root/C.ROLLBACK_INTENT).exists():
                    before=self.snapshot(trial)
                    with self.assertRaisesRegex(ValueError,'rollback direction'):trial.resume()
                    self.assertEqual(before,self.snapshot(trial))
                trial.rollback();self.restored(trial)

    def test_missing_originals_and_present_recovery_variants(self):
        source=Fixtures.Bundle();source.setUp();self.addCleanup(source.doCleanups)
        for base in ('priorities.txt','caps.txt'):
            raw=(source.source/base).read_bytes()
            for suffix in ('.tmp','.pending','.bak'):(source.source/(base+suffix)).write_bytes(raw)
        for n in C.TRIAL:(source.source/n).unlink()
        source.prepare();before=source.originals()
        f=self.fixture(bundle=source.destination);f.rollback();self.restored(f)
        self.assertEqual(source.originals(),before)
        for n in C.B.NAMES:self.assertIsNotNone(f.read(n))
        for n in C.TRIAL:self.assertIsNone(f.read(n))

    def test_unknown_edit_at_mutation_boundaries_preserved(self):
        boundaries=('rollback:before-intent-replace','rollback:before-replace:'+C.MARKER,
                    'rollback:before-replace:caps.txt','rollback:before-delete:caps.txt.bak',
                    'rollback:before-replace:'+C.TRIAL[0],'rollback:before-unfence')
        for boundary in boundaries:
            f=self.fixture();newer=C.envelope(Fixtures.P+b'mine|1|2\n',123)
            captured=[]
            def edit(label):
                if label==boundary:
                    (f.target/'priorities.txt.pending').write_bytes(newer)
                    captured.append(self.snapshot(f))
            f.hook=edit
            with self.assertRaisesRegex(ValueError,'unexpected file bytes'):f.rollback()
            self.assertEqual(len(captured),1,boundary)
            self.assertEqual(self.snapshot(f),captured[0],boundary)

    def test_trial_restore_and_unfence_require_full_originals(self):
        for boundary in ('rollback:before-replace:'+C.TRIAL[0],'rollback:before-unfence'):
            f=self.fixture()
            def edit(label):
                if label==boundary:(f.target/'caps.txt').write_bytes(C.decoded(f.plan['desired']['caps.txt']))
            f.hook=edit
            with self.assertRaisesRegex(ValueError,'legacy changed|before unfencing'):f.rollback()
            self.assertEqual(f.read(C.MARKER),f._rollback_marker())
            if 'before-replace' in boundary:self.assertIsNone(f.read(C.TRIAL[0]))

    def test_partial_stages_and_uncertain_replace_resume(self):
        for stage_name in ('.rollback-intent-stage','.rollback-stage'):
            for after_full_write in (False,True):
                f=self.fixture();write=C.B.write_new
                def fail(path,raw):
                    if Path(path).name==stage_name:
                        if after_full_write:write(path,raw)
                        else:Path(path).write_bytes(raw[:9])
                        raise OSError('partial stage')
                    return write(path,raw)
                with mock.patch.object(C.B,'write_new',side_effect=fail):
                    with self.assertRaisesRegex(OSError,'partial stage'):f.rollback()
                f.rollback();self.restored(f)
        for final in (C.ROLLBACK_INTENT,C.MARKER,'caps.txt',C.TRIAL[0]):
            for after in (False,True):
                f=self.fixture();replace=C.os.replace
                def fail(a,b):
                    if Path(b)==(f.root/C.ROLLBACK_INTENT if final==C.ROLLBACK_INTENT else f.target/final):
                        if after:replace(a,b)
                        raise OSError('uncertain replace')
                    return replace(a,b)
                with mock.patch.object(C.os,'replace',side_effect=fail):
                    with self.assertRaisesRegex(OSError,'uncertain replace'):f.rollback()
                f.rollback();self.restored(f)

    def test_unlink_errors_before_and_after_deletion(self):
        for name in ('caps.txt.bak',C.MARKER):
            for after in (False,True):
                f=self.fixture();unlink=Path.unlink
                def fail(path,*args,**kwargs):
                    if path==f.target/name:
                        if after:unlink(path,*args,**kwargs)
                        raise OSError('uncertain deletion')
                    return unlink(path,*args,**kwargs)
                with mock.patch.object(Path,'unlink',new=fail):
                    with self.assertRaisesRegex(OSError,'uncertain deletion'):f.rollback()
                f.rollback();self.restored(f)

    def test_lost_or_foreign_fence_intent_plan_refuses(self):
        for loss in ('fence','foreign_fence','intent','foreign_intent','plan'):
            f=self.fixture();self.stop_at(f,'rollback:after-replace:caps.txt',f.rollback)
            if loss=='fence':(f.target/C.MARKER).unlink()
            elif loss=='foreign_fence':(f.target/C.MARKER).write_bytes(f.marker)
            elif loss=='intent':(f.root/C.ROLLBACK_INTENT).unlink()
            elif loss=='foreign_intent':(f.root/C.ROLLBACK_INTENT).write_bytes(b'{}')
            else:(f.root/'plan.json').write_bytes(b'{}')
            before=self.snapshot(f)
            with self.assertRaises(ValueError):f.resume_rollback()
            self.assertEqual(before,self.snapshot(f))

    def test_unknown_new_edits_after_rollback_preserved(self):
        f=self.fixture();f.rollback()
        for n in ('priorities.txt',C.TRIAL[1]):
            (f.target/n).write_bytes(b'new edit after rollback')
        before=self.snapshot(f)
        for action in (f.resume,f.resume_rollback,f.rollback):
            with self.assertRaises(ValueError):action()
            self.assertEqual(before,self.snapshot(f))

    def test_root_identity_and_target_gates(self):
        f=self.fixture();old=f.root_id;f.root_id={**old,'inode':old['inode']+1}
        with self.assertRaisesRegex(ValueError,'root changed'):f.rollback()
        f.root_id=old;target=f.target;f.target=f.root
        with self.assertRaisesRegex(ValueError,'target differs'):f.rollback()
        f.target=target

    def test_fresh_process_explicit_rollback_and_stale_forward(self):
        code=r'''
import json,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import settings_cutover_fixture as C
f=object.__new__(C.Fixture)
f.root=Path(sys.argv[2]);f.target=f.root/'mod';f.root_id=json.loads(sys.argv[3]);f.plan_hash=sys.argv[4]
f.marker=('PWP-CUTOVER-FIXTURE-1\n'+f.plan_hash+'\n').encode();f.hook=lambda _:None
try:f.resume()
except ValueError:pass
else:raise AssertionError('stale forward admitted')
print(json.dumps(f.resume_rollback()))
'''
        for boundary in ('rollback:after-intent-replace','rollback:after-delete:caps.txt.bak',
                         'rollback:after-replace:'+C.TRIAL[0],'rollback:after-unfence'):
            f=self.fixture();self.stop_at(f,boundary,f.rollback)
            result=subprocess.run([sys.executable,'-B','-c',code,str(ROOT/'tools'),str(f.root),
                                   json.dumps(f.root_id),f.plan_hash],capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(result.stdout),f._rollback_result());self.restored(f)


if __name__=='__main__':unittest.main()
