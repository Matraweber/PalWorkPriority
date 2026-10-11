import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import prepare_dedicated_clock_fixture as M


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        root=Path(self.temp.name);self.server=root/'server';self.source=self.server/'old'
        self.fixture=root/'evidence';self.backup=self.server/'backup'
        for rel,name in M.TARGETS[:3]:
            path=self.server/rel;path.mkdir(parents=True);(path/'original').write_bytes(name.encode())
        (self.server/'Pal/Binaries/Win64').mkdir(parents=True)
        saved=self.source/'Saved/Config/WindowsServer';saved.mkdir(parents=True)
        (saved/'PalWorldSettings.ini').write_text('[/Script/Pal.PalGameWorldSettings]\nOptionSettings=(RESTAPIEnabled=True,RESTAPIPort=18212,AdminPassword="test")\n')
        runtime=self.source/'manual-ue4ss';runtime.mkdir()
        for name in ('UE4SS.dll','UE4SS-settings.ini','MemberVariableLayout.ini'):(runtime/name).write_bytes(b'test')
        (runtime/'Mods').mkdir();(runtime/'Mods/unwanted').write_bytes(b'not staged')
        (self.source/'manual-dwmapi.dll').write_bytes(b'proxy')
        import hashlib
        for key,value in [('SERVER',self.server),('FIXTURE',self.fixture),('BACKUP',self.backup),('SOURCE',self.source)]:
            p=patch.object(M,key,value);p.start();self.addCleanup(p.stop)
        p=patch.object(M,'EXPECTED_PROXY',hashlib.sha256(b'proxy').hexdigest());p.start();self.addCleanup(p.stop)
        p=patch.object(M.installer,'EXPECTED_RUNTIME',hashlib.sha256(b'test').hexdigest());p.start();self.addCleanup(p.stop)
        p=patch.object(M.installer,'stopped');self.stopped=p.start();self.addCleanup(p.stop)

    def test_prepare_restore_repeat_preserves_originals(self):
        originals={rel:M.fingerprint(self.server/rel) for rel,_ in M.TARGETS[:3]}
        self.assertTrue(M.prepare()['prepared'])
        self.assertEqual(list((self.server/'Mods').iterdir()),[])
        self.assertEqual(list((self.server/'Pal/Binaries/Win64/ue4ss/Mods').iterdir()),[])
        self.assertTrue(M.restore()['original_hashes_match'])
        self.assertTrue(M.restore()['original_hashes_match'])
        for rel,_ in M.TARGETS[:3]:self.assertEqual(M.fingerprint(self.server/rel),originals[rel])
        self.assertFalse((self.server/'Pal/Binaries/Win64/ue4ss').exists())

    def test_restore_after_each_move_interruption(self):
        original=Path.rename;calls=0
        def interrupted(path,target):
            nonlocal calls
            result=original(path,target);calls+=1
            if calls==3:raise OSError('injected after completed move')
            return result
        with patch.object(Path,'rename',interrupted):
            with self.assertRaises(OSError):M.prepare()
        self.assertTrue(M.restore()['restored'])
        for rel,name in M.TARGETS[:3]:self.assertEqual((self.server/rel/'original').read_bytes(),name.encode())

    def test_restore_itself_resumes(self):
        M.prepare();original=Path.rename;calls=0
        def interrupted(path,target):
            nonlocal calls
            result=original(path,target);calls+=1
            if calls==1:raise OSError('injected restore interruption')
            return result
        with patch.object(Path,'rename',interrupted):
            with self.assertRaises(OSError):M.restore()
        self.assertTrue(M.restore()['restored'])

    def test_changed_original_backup_refused(self):
        M.prepare();(self.backup/'Saved/original').write_bytes(b'changed')
        with self.assertRaises(RuntimeError):M.restore()

    def test_running_or_wrong_runtime_refused_before_moves(self):
        self.stopped.side_effect=RuntimeError('running')
        with self.assertRaises(RuntimeError):M.prepare()
        self.assertFalse(self.backup.exists())
        self.stopped.side_effect=None
        (self.source/'manual-ue4ss/UE4SS.dll').write_bytes(b'wrong')
        with self.assertRaises(RuntimeError):M.prepare()
        self.assertFalse(self.backup.exists())


if __name__=='__main__':unittest.main()
