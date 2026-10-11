"""Real file exclusion composed with actual binding and marker lifecycle."""
from pathlib import Path
from contextlib import ExitStack
import os
import sys
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import settings_installation_fence as F
import settings_installation_binding as I
from tests import test_settings_installation_binding as BindingFixture


@unittest.skipUnless(os.name=='nt','requires real Win32 sharing')
class InstalledPins(unittest.TestCase):
    def setUp(self):
        fixture=BindingFixture.Binding();fixture.setUp();self.addCleanup(fixture.doCleanups)
        self.fixture=fixture;self.root=fixture.paths.mod
        self.evidence=fixture.f.root/'pin-evidence';self.evidence.mkdir()
        self.binding=fixture.capture()
        stack=ExitStack();self.addCleanup(stack.close)
        stack.enter_context(mock.patch.object(F,'MOD',self.root))
        stack.enter_context(mock.patch.object(I,'MOD',self.root))
        stack.enter_context(mock.patch.object(I,'RUNTIME',fixture.paths.runtime.parent))
        stack.enter_context(mock.patch.object(I,'recheck',side_effect=fixture.check))
        stack.enter_context(mock.patch.object(F.B,'game_closed',return_value=True))
        self.cycle=F.installation_cycle(self.binding,self.evidence)

    def test_existing_code_runtime_and_settings_writes_denied_until_release(self):
        paths=[self.root/'Scripts/main.lua',self.root/'Scripts/helper.lua',
               self.root/'priorities.txt',self.fixture.paths.runtime]
        originals={p:p.read_bytes() for p in paths}
        seen=[]
        def hook(label):
            if label!='after-verified':return
            for path in paths:
                # Disposable fixtures only. Real installation probe must never
                # truncate/write/delete even if an exclusion bug is present.
                with self.assertRaises(OSError):path.write_bytes(b'competing edit')
                with self.assertRaises(OSError):path.unlink()
                self.assertEqual(path.read_bytes(),originals[path])
            seen.append(label)
        self.cycle.hook=hook
        result=self.cycle.run()
        self.assertEqual(seen,['after-verified'])
        self.assertTrue(result['marker_rehearsal_complete'])
        self.assertFalse(result['arbitrary_writers_excluded'])
        self.assertFalse(result['live_cutover_allowed'])
        self.assertFalse((self.root/F.MARKER).exists())
        for path in paths:
            self.assertEqual(path.read_bytes(),originals[path])
            path.write_bytes(originals[path]) # No leaked handle after success.

    def test_new_child_is_detected_and_fence_retained_until_explicit_recovery(self):
        added=self.root/'Scripts/unreviewed.lua'
        def hook(label):
            if label=='after-verified':added.write_bytes(b'new deployment child')
        self.cycle.hook=hook
        with self.assertRaisesRegex(ValueError,'protected file tree differs'):
            self.cycle.run()
        marker=(self.root/F.MARKER).read_bytes()
        self.assertEqual(added.read_bytes(),b'new deployment child')
        self.assertFalse((self.evidence/'complete.json').exists())
        with self.assertRaisesRegex(ValueError,'protected file tree differs'):
            self.cycle.recover()
        self.assertEqual((self.root/F.MARKER).read_bytes(),marker)
        added.unlink() # Test owns this disposable child; real drift is preserved.
        self.cycle.hook=lambda _:None
        self.assertTrue(self.cycle.recover()['marker_rehearsal_complete'])
        self.assertFalse((self.root/F.MARKER).exists())


if __name__=='__main__':unittest.main()
