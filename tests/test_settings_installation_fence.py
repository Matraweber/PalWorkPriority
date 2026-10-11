from pathlib import Path
from contextlib import nullcontext
import base64
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import settings_installation_fence as F


class Rehearsal(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)/'mod';self.root.mkdir()
        self.evidence=Path(self.temp.name)/'evidence';self.evidence.mkdir()
        self.data=self.root/'priorities.txt';self.data.write_bytes(b'original X settings')
        self.original=self.data.read_bytes();self.closed=True;self.calls=[]
        def verify(binding,expected_marker=None):
            self.assertEqual(binding,{'source':'bound'})
            F.B.require(self.data.read_bytes()==self.original,'source changed')
            marker=self.root/F.MARKER
            actual=marker.read_bytes() if marker.exists() else None
            F.B.require(actual==expected_marker,'marker differs')
            self.calls.append('verified-fenced' if expected_marker else 'verified-absent')
        self.cycle=F.MarkerCycle(self.root,{'source':'bound'},self.evidence,nullcontext,verify,self.is_closed)

    def is_closed(self):
        self.calls.append('process-check')
        return self.closed

    def test_marker_only_success_and_check_order(self):
        self.cycle.hook=self.calls.append
        result=self.cycle.run()
        self.assertTrue(result['marker_rehearsal_complete'])
        self.assertFalse(result['live_cutover_allowed']);self.assertFalse(result['settings_written'])
        self.assertEqual(self.data.read_bytes(),self.original)
        self.assertFalse((self.root/F.MARKER).exists())
        self.assertLess(self.calls.index('after-fence'),self.calls.index('verified-fenced'))
        self.assertEqual(self.calls[self.calls.index('after-fence')+1],'process-check')
        self.assertEqual(self.calls[self.calls.index('before-unfence')+1],'process-check')

    def test_evidence_cannot_live_inside_target(self):
        with self.assertRaisesRegex(ValueError,'outside the installation'):
            F.MarkerCycle(self.root,{},self.root,nullcontext,lambda *a,**k:None,lambda:True)

    @unittest.skipUnless(os.name=='nt','requires real Windows handles')
    def test_real_fixed_installation_lock_and_wrong_root(self):
        from settings_cutover_lock import LockError,NAME
        identity=F.B.identity(self.root.stat())
        with mock.patch.object(F,'MOD',self.root):
            with F.InstallationLock(self.root,identity):
                with self.assertRaises(LockError):F.InstallationLock(self.root,identity).acquire()
                with self.assertRaises(OSError):(self.root/NAME).unlink()
            self.assertTrue((self.root/NAME).exists())
            self.cycle.lock=lambda:F.InstallationLock(self.root,identity)
            self.assertTrue(self.cycle.run()['marker_rehearsal_complete'])
            with self.assertRaisesRegex(ValueError,'fixed installation'):
                F.InstallationLock(self.evidence,F.B.identity(self.evidence.stat())).acquire()

    def test_initial_game_or_unknown_status_refuses_before_intent(self):
        for status in (False,None,1):
            self.closed=status
            with self.assertRaises(ValueError):self.cycle.run()
            self.assertFalse((self.root/F.MARKER).exists())
            self.assertFalse((self.evidence/'intent.json').exists())

    def test_startup_race_keeps_fence_until_explicit_safe_recovery(self):
        def hook(label):
            if label=='before-fence':self.closed=False
        self.cycle.hook=hook
        with self.assertRaisesRegex(ValueError,'process'):self.cycle.run()
        marker=(self.root/F.MARKER).read_bytes()
        self.assertFalse((self.evidence/'fenced.json').exists())
        with self.assertRaises(ValueError):self.cycle.recover()
        self.assertEqual((self.root/F.MARKER).read_bytes(),marker)
        self.closed=True;self.cycle.hook=lambda _:None
        self.assertTrue(self.cycle.recover()['marker_rehearsal_complete'])
        self.assertEqual(self.data.read_bytes(),self.original)

    def test_process_starts_before_unfence_preserves_marker(self):
        def hook(label):
            if label=='before-unfence':self.closed=False
        self.cycle.hook=hook
        with self.assertRaisesRegex(ValueError,'process'):self.cycle.run()
        self.assertTrue((self.root/F.MARKER).exists())
        self.assertFalse((self.evidence/'complete.json').exists())

    def test_changed_settings_and_foreign_marker_preserved(self):
        def hook(label):
            if label=='after-verified':self.data.write_bytes(b'newer user edit')
        self.cycle.hook=hook
        with self.assertRaisesRegex(ValueError,'source changed'):self.cycle.run()
        self.assertEqual(self.data.read_bytes(),b'newer user edit')
        self.assertTrue((self.root/F.MARKER).exists())
        self.data.write_bytes(self.original)
        (self.root/F.MARKER).write_bytes(b'foreign fence')
        with self.assertRaises(ValueError):self.cycle.recover()
        self.assertEqual((self.root/F.MARKER).read_bytes(),b'foreign fence')

    def test_partial_marker_never_automatically_removed(self):
        write=F.B.write_new
        def fail(path,raw):
            if Path(path)==self.root/F.MARKER:
                Path(path).write_bytes(raw[:10]);raise OSError('partial marker')
            return write(path,raw)
        with mock.patch.object(F.B,'write_new',side_effect=fail):
            with self.assertRaises(OSError):self.cycle.run()
        before=(self.root/F.MARKER).read_bytes()
        with self.assertRaises(ValueError):self.cycle.recover()
        self.assertEqual((self.root/F.MARKER).read_bytes(),before)

    def test_marker_created_by_another_writer_is_not_replaced(self):
        def hook(label):
            if label=='before-fence':(self.root/F.MARKER).write_bytes(b'other transaction')
        self.cycle.hook=hook
        with self.assertRaises(FileExistsError):self.cycle.run()
        self.assertEqual((self.root/F.MARKER).read_bytes(),b'other transaction')
        with self.assertRaises(ValueError):self.cycle.recover()
        self.assertEqual((self.root/F.MARKER).read_bytes(),b'other transaction')

    def test_lost_completion_does_not_recreate_marker(self):
        def hook(label):
            if label=='after-unfence':raise OSError('completion not recorded')
        self.cycle.hook=hook
        with self.assertRaises(OSError):self.cycle.run()
        self.assertFalse((self.root/F.MARKER).exists())
        with self.assertRaises(ValueError):self.cycle.recover()
        self.assertFalse((self.root/F.MARKER).exists())

    def test_lock_refusal_happens_before_any_mutation(self):
        def unavailable():raise OSError('lock unavailable')
        self.cycle.lock=unavailable
        with self.assertRaises(OSError):self.cycle.run()
        self.assertEqual(list(self.evidence.iterdir()),[])
        self.assertFalse((self.root/F.MARKER).exists())

    def test_tampered_recovery_binding_refuses(self):
        def hook(label):
            if label=='after-fence':raise OSError('interrupted')
        self.cycle.hook=hook
        with self.assertRaises(OSError):self.cycle.run()
        path=self.evidence/'intent.json';obj=json.loads(path.read_text());obj['binding_sha256']='0'*64
        path.write_text(json.dumps(obj))
        with self.assertRaisesRegex(ValueError,'binding differs'):self.cycle.recover()
        self.assertTrue((self.root/F.MARKER).exists())


if __name__=='__main__':unittest.main()
