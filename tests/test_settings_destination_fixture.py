from pathlib import Path
import json
import os
import subprocess
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
import settings_destination_fixture as M
from tests import test_settings_export_bundle as Sources


@unittest.skipUnless(os.name=='nt','real Windows handles required')
class DestinationExperiment(unittest.TestCase):
    def setUp(self):
        self.source=Sources.Bundle();self.source.setUp();self.addCleanup(self.source.doCleanups)
        self.source.prepare();self.before=self.source.originals()

    def fixture(self):
        f=M.C.Fixture(self.source.destination);self.addCleanup(f.close);return f

    def test_two_streams_reserved_before_writes_competitor_denied_and_fence_kept(self):
        f=self.fixture();stages=[]
        def hook(label):
            stages.append(label)
            if label=='all-reserved':
                for name in M.B.NAMES:
                    self.assertEqual(f.read(name),M.C.decoded(f.plan['original'][name]) or b'')
                code="""
from pathlib import Path
import sys
for s in sys.argv[1:]:
    p=Path(s)
    for act in (lambda:p.write_bytes(b'foreign'),lambda:p.unlink()):
        try:act()
        except OSError:pass
        else:raise AssertionError('competing mutation admitted')
print('16 competing mutations refused')
"""
                result=subprocess.run([sys.executable,'-B','-c',code,*[str(f.target/n) for n in M.B.NAMES]],
                                      capture_output=True,text=True,timeout=20)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertIn('16 competing mutations refused',result.stdout)
        result=M.run(f,hook)
        self.assertTrue(result['candidate_copies_verified']);self.assertEqual(result['reserved_missing'],6)
        self.assertFalse(result['live_cutover_allowed']);self.assertFalse(result['trial_retired'])
        self.assertLess(stages.index('all-reserved'),stages.index('before-write:priorities.txt'))
        self.assertEqual(f.read(M.C.MARKER),f.marker)
        for name in M.B.NAMES:self.assertEqual(f.read(name),M.C.decoded(f.plan['desired'][name]))
        for name in M.C.TRIAL:self.assertEqual(f.read(name),M.C.decoded(f.plan['original'][name]))
        # Exercise the real Lua decoder/recovery selection, without executing
        # the game entry point or removing the experiment's startup fence.
        sys.path.insert(0,str(ROOT/'.test-deps'))
        from lupa.lua54 import LuaRuntime
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.globals().ROOT=ROOT.as_posix();lua.globals().TARGET=f.target.as_posix()+'/'
        lua.execute("""
            package.path=ROOT..'/Scripts/?.lua;'
            local D,S,C=require('datafile'),require('store'),require('caps')
            local p,pm=D.read(TARGET..'priorities.txt',S.decode_snapshot)
            local c,cm=D.read(TARGET..'caps.txt',C.decode_snapshot)
            assert(p and c and pm.source==TARGET..'priorities.txt' and cm.source==TARGET..'caps.txt')
            local ps=S.serialize_snapshot(p.data,p.baseline)
            local cs=C.serialize_snapshot(c.data)
            assert(ps:find('mine|1|X',1,true) and ps:find('unrelated|2|X',1,true))
            assert(cs:find('|Mining|Stone|OFF',1,true) and cs:find('*|Mining|Wood|200',1,true))
        """)
        self.assertEqual(self.source.originals(),self.before)

    def test_foreign_creation_before_reservation_preserved_no_payload_write(self):
        f=self.fixture()
        def hook(label):
            if label=='before-reserve:caps.txt.pending':(f.target/'caps.txt.pending').write_bytes(b'foreign winner')
        with self.assertRaises(OSError):M.run(f,hook)
        self.assertEqual((f.target/'caps.txt.pending').read_bytes(),b'foreign winner')
        self.assertEqual(f.read('priorities.txt'),M.C.decoded(f.plan['original']['priorities.txt']))
        self.assertEqual(f.read('caps.txt'),M.C.decoded(f.plan['original']['caps.txt']))
        self.assertEqual(f.read(M.C.MARKER),f.marker)
        self.assertFalse((f.root/'destination-result.json').exists())

    def test_receipt_write_failure_keeps_reservation_and_originals(self):
        from unittest import mock
        f=self.fixture();write=M.B.write_new
        def fail(path,raw):
            if Path(path).name=='reserved-priorities.txt.tmp.json':raise OSError('receipt disk failure')
            return write(path,raw)
        with mock.patch.object(M.B,'write_new',side_effect=fail):
            with self.assertRaisesRegex(OSError,'receipt disk failure'):M.run(f)
        self.assertEqual(f.read('priorities.txt.tmp'),b'')
        self.assertEqual(f.read('priorities.txt'),M.C.decoded(f.plan['original']['priorities.txt']))
        self.assertEqual(f.read(M.C.MARKER),f.marker)
        with self.assertRaises(ValueError):M.run(f)

    def test_newer_edit_between_pristine_check_and_capture_never_becomes_baseline(self):
        f=self.fixture()
        def hook(label):
            if label=='after-pristine-check':(f.target/'priorities.txt').write_bytes(b'newer player edit')
        with self.assertRaisesRegex(ValueError,'snapshot differs from immutable original'):
            M.run(f,hook)
        self.assertEqual(f.read('priorities.txt'),b'newer player edit')
        self.assertEqual(f.read('caps.txt'),M.C.decoded(f.plan['original']['caps.txt']))
        self.assertIsNone(f.read(M.C.MARKER))
        self.assertFalse((f.root/M.INTENT).exists())
        for name in M.B.NAMES:
            if f.plan['original'][name] is None:self.assertIsNone(f.read(name))

    def test_fresh_process_exit_leaves_fence_and_refuses_blind_resume(self):
        code=r'''
from pathlib import Path
import json,os,sys
sys.path.insert(0,sys.argv[1])
import settings_destination_fixture as M
f=M.C.Fixture.__new__(M.C.Fixture)
f.root=Path(sys.argv[2]);f.root_id=json.loads(sys.argv[3]);f.target=f.root/'mod'
f.plan_hash=sys.argv[4];f.marker=('PWP-CUTOVER-FIXTURE-1\n'+f.plan_hash+'\n').encode()
f.plan=json.loads((f.root/'plan.json').read_text())
def hook(label):
    if label==sys.argv[5]:os._exit(73)
M.run(f,hook)
'''
        for boundary in ('all-reserved','after-write:priorities.txt'):
            with self.subTest(boundary=boundary):
                f=self.fixture()
                child=subprocess.run([sys.executable,'-B','-c',code,str(ROOT/'tools'),str(f.root),
                                      json.dumps(f.root_id),f.plan_hash,boundary],capture_output=True,text=True,timeout=20)
                self.assertEqual(child.returncode,73,child.stderr)
                self.assertEqual(f.read(M.C.MARKER),f.marker)
                prior={n:f.read(n) for n in (*M.B.NAMES,*M.C.TRIAL)}
                self.assertEqual(prior['priorities.txt'],M.C.decoded(f.plan['desired' if boundary.startswith('after-write') else 'original']['priorities.txt']))
                self.assertFalse((f.root/'destination-result.json').exists())
                with self.assertRaises(ValueError):M.run(f)
                self.assertEqual(prior,{n:f.read(n) for n in prior})
                self.assertEqual(self.source.originals(),self.before)


if __name__=='__main__':unittest.main()
