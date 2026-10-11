from pathlib import Path
import base64
import sys
import unittest
import tempfile
import shutil
import gc
import weakref
import subprocess
import json
from unittest import mock
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'));sys.path.insert(0,str(ROOT/'.test-deps'))
import settings_cutover_fixture as C
try: from tests import test_settings_export_bundle as Fixtures
except ImportError: import test_settings_export_bundle as Fixtures

class Cutover(unittest.TestCase):
    def setUp(self):
        self.source=Fixtures.Bundle();self.source.setUp();self.addCleanup(self.source.doCleanups)
        self.bundle=self.source.prepare();self.original=self.source.originals()
    def fixture(self):
        f=C.Fixture(self.source.destination);self.addCleanup(f.close);return f
    def validate_complete(self,f):
        self.assertIsNone(f.read(C.MARKER))
        for name in C.TRIAL:self.assertIsNone(f.read(name))
        for name,wanted in f.plan['desired'].items():self.assertEqual(f.read(name),C.decoded(wanted))
        from lupa.lua54 import LuaRuntime
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.globals().ROOT=ROOT.as_posix();lua.globals().TARGET=f.target.as_posix()+'/'
        lua.globals().WANTED_P=self.bundle['plan']['bodies']['priorities']
        lua.globals().WANTED_C=self.bundle['plan']['bodies']['limits']
        lua.execute("""
            package.path=ROOT..'/Scripts/?.lua;'
            local D,S,C=require('datafile'),require('store'),require('caps')
            local p,pm=D.read(TARGET..'priorities.txt',S.decode_snapshot)
            local c,cm=D.read(TARGET..'caps.txt',C.decode_snapshot)
            assert(p and c and pm.source==TARGET..'priorities.txt' and cm.source==TARGET..'caps.txt')
            assert(S.serialize_snapshot(p.data,p.baseline)==WANTED_P)
            assert(C.serialize_snapshot(c.data)==WANTED_C)
            assert(pm.generation>0 and cm.generation>0)
        """)
        self.assertEqual(self.source.originals(),self.original,'source installation copy changed')
    def test_complete_and_idempotent_recovery(self):
        f=self.fixture();self.assertFalse(f.resume()['live_cutover_allowed']);self.validate_complete(f)
        self.assertTrue(f.resume()['complete']);self.validate_complete(f)
    def test_resume_at_every_interruption_boundary(self):
        f=self.fixture();labels=[];f.hook=labels.append;f.resume();self.validate_complete(f)
        self.assertEqual(len(labels),42)
        for label in labels:
            with self.subTest(boundary=label):
                trial=self.fixture()
                def fail(at):
                    if at==label:raise OSError('simulated interruption')
                trial.hook=fail
                with self.assertRaisesRegex(OSError,'interruption'):trial.resume()
                # Without a marker, disk must be pristine or fully committed.
                if trial.read(C.MARKER) is None:
                    _,values=trial.state()
                    pristine=all(values[n]==C.decoded(v) for n,v in trial.plan['original'].items())
                    complete=all(values[n]==C.decoded(v) for n,v in trial.plan['desired'].items()) and all(values[n] is None for n in C.TRIAL)
                    self.assertTrue(pristine or complete)
                else:self.assertEqual(trial.read(C.MARKER),trial.marker)
                trial.hook=lambda _:None
                self.assertTrue(trial.resume()['complete']);self.validate_complete(trial)
    def test_partial_stage_write_never_becomes_active_data(self):
        for failed_write in (1,2,5,9):
            f=self.fixture();write=C.B.write_new;calls=0
            def partial(path,raw):
                nonlocal calls
                if Path(path).name=='.cutover-stage':
                    calls+=1
                    if calls==failed_write:
                        Path(path).write_bytes(raw[:13]);raise OSError('partial stage')
                return write(path,raw)
            with mock.patch.object(C.B,'write_new',side_effect=partial):
                with self.assertRaisesRegex(OSError,'partial stage'):f.resume()
            self.assertTrue(f.resume()['complete']);self.validate_complete(f)
    def test_replace_error_before_or_after_actual_replacement(self):
        for after in (False,True):
            f=self.fixture();replace=C.os.replace;calls=0
            def fail(a,b):
                nonlocal calls
                calls+=1
                if calls==4:
                    if after:replace(a,b)
                    raise OSError('replace uncertain')
                return replace(a,b)
            with mock.patch.object(C.os,'replace',side_effect=fail):
                with self.assertRaisesRegex(OSError,'uncertain'):f.resume()
            self.assertEqual(f.read(C.MARKER),f.marker)
            self.assertTrue(f.resume()['complete']);self.validate_complete(f)
    def test_unknown_bytes_or_lost_marker_refuse_without_overwrite(self):
        for loss in (False,True):
            f=self.fixture()
            def fail(at):
                if at=='after-replace:priorities.txt':raise OSError('interrupted')
            f.hook=fail
            with self.assertRaises(OSError):f.resume()
            f.hook=lambda _:None
            if loss:(f.target/C.MARKER).unlink()
            else:(f.target/'caps.txt').write_bytes(b'unknown competing edit')
            before={n:f.read(n) for n in f.plan['original']}
            with self.assertRaises(ValueError):f.resume()
            self.assertEqual(before,{n:f.read(n) for n in f.plan['original']})
    def test_change_just_before_unfence_keeps_marker(self):
        for name in ('priorities.txt',C.TRIAL[0]):
            f=self.fixture()
            def changed(at):
                if at=='before-unfence':(f.target/name).write_bytes(C.decoded(f.plan['original'][name]))
            f.hook=changed
            with self.assertRaisesRegex(ValueError,'before unfencing'):f.resume()
            self.assertEqual(f.read(C.MARKER),f.marker)
            f.hook=lambda _:None;f.resume();self.validate_complete(f)
    def test_refused_cleanup_has_no_destructive_gc_fallback(self):
        f=C.Fixture(self.source.destination)
        root=f.root;held=root.with_name(root.name+'-held')
        self.assertEqual(root.resolve().parent,Path(tempfile.gettempdir()).resolve())
        self.assertEqual(held.resolve().parent,Path(tempfile.gettempdir()).resolve())
        self.assertFalse(held.exists())
        root.rename(held);root.mkdir();sentinel=root/'replacement';sentinel.write_bytes(b'keep replacement')
        try:
            with self.assertRaisesRegex(ValueError,'root replaced'):f.close()
            ref=weakref.ref(f);del f;gc.collect()
            self.assertIsNone(ref())
            self.assertEqual(sentinel.read_bytes(),b'keep replacement')
            self.assertTrue(held.is_dir())
        finally:
            # Both paths are test-created siblings, verified again before cleanup.
            for path in (root,held):
                C.B.checked_path(path,directory=True)
                self.assertEqual(path.resolve().parent,Path(tempfile.gettempdir()).resolve())
                self.assertTrue(path.name.startswith('pwp-cutover-fixture-'))
                if path.exists():shutil.rmtree(path)
    def test_trial_retirement_rechecks_both_complete_streams(self):
        f=self.fixture()
        def changed(at):
            if at=='before-retire:'+C.TRIAL[0]:
                (f.target/'caps.txt').write_bytes(C.decoded(f.plan['original']['caps.txt']))
        f.hook=changed
        with self.assertRaisesRegex(ValueError,'before trial retirement'):f.resume()
        self.assertEqual(f.read(C.TRIAL[0]),C.decoded(f.plan['original'][C.TRIAL[0]]))
        self.assertEqual(f.read(C.MARKER),f.marker)
        f.hook=lambda _:None;f.resume();self.validate_complete(f)
    def test_fresh_process_recovery_uses_persisted_plan(self):
        code=r"""
import sys,json,tempfile
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import settings_cutover_fixture as C
f=object.__new__(C.Fixture)
f.root=Path(sys.argv[2]);f.target=f.root/'mod'
assert f.root.resolve().parent==Path(tempfile.gettempdir()).resolve()
assert f.root.name.startswith('pwp-cutover-fixture-')
f.root_id=json.loads(sys.argv[3]);f.plan_hash=sys.argv[4]
f.marker=('PWP-CUTOVER-FIXTURE-1\n'+f.plan_hash+'\n').encode()
f.hook=lambda label:None
print(json.dumps(f.resume()))
"""
        for boundary in ('after-replace:priorities.txt','after-replace:caps.txt.bak','after-retire:'+C.TRIAL[0]):
            with self.subTest(boundary=boundary):
                f=self.fixture()
                def fail(at):
                    if at==boundary:raise OSError('process boundary')
                f.hook=fail
                with self.assertRaises(OSError):f.resume()
                result=subprocess.run([sys.executable,'-c',code,str(ROOT/'tools'),str(f.root),
                                       json.dumps(f.root_id),f.plan_hash],capture_output=True,text=True,timeout=30)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(json.loads(result.stdout),{'complete':True,'live_cutover_allowed':False})
                self.validate_complete(f)

    def test_foreign_marker_and_plan_tampering_refuse(self):
        f=self.fixture();(f.target/C.MARKER).write_bytes(b'foreign')
        with self.assertRaisesRegex(ValueError,'foreign'):f.resume()
        f=self.fixture();(f.root/'plan.json').write_bytes(b'{}')
        with self.assertRaisesRegex(ValueError,'plan changed'):f.resume()

if __name__=='__main__':unittest.main()
