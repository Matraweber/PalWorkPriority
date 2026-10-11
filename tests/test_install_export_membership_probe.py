import sys,unittest,tempfile,hashlib,json
from pathlib import Path
from unittest import mock
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
import install_export_membership_probe as I
from tests import test_settings_export_bundle as Fixtures

class Install(unittest.TestCase):
    def setUp(self):
        f=Fixtures.Bundle();f.setUp();self.addCleanup(f.doCleanups);self.f=f
        # Replace fixture's synthetic Pal with a native-format stable identity.
        self.key='A'*64
        for path in (f.source/'priorities.txt',):path.write_bytes(path.read_bytes().replace(b'mine',self.key.encode()))
        from tests.test_settings_journal_export import record,W,G
        for slot,gen in [('A',1),('B',2)]:
            (f.journals/f'pwp-record-v1-{W}-{G}-priorities-{slot}.record').write_bytes(record('priorities',b'# Pal Work Priority: palkey|worktype|priority (1 highest, 5 lowest, X disabled)\n'+self.key.encode()+b'|1|X\n',gen))
        # Unrelated old key must also be native for the lookup union.
        p=f.source/'priorities.txt';p.write_bytes(p.read_bytes().replace(b'unrelated',b'B'*64))
        f.claims[0]['pal']=self.key;f.prepare()
        self.runtime=f.root/'runtime';self.runtime.mkdir();(self.runtime/'UE4SS.dll').write_bytes(b'runtime')
        self.probe=f.root/'probe';self.evidence=f.root/'repo';(self.evidence/'test-results').mkdir(parents=True)
        # Root contains symlink-free copied sources only, preserving compile checks.
        import shutil
        shutil.copytree(ROOT/'Scripts',self.evidence/'Scripts')
        for source in (ROOT/'experiments').rglob('*.lua'):
            target=self.evidence/'experiments'/source.relative_to(ROOT/'experiments')
            target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
        (self.evidence/'.test-deps').mkdir()
        for name,value in [('RUNTIME',self.runtime),('PRODUCTION',f.source),('PROBE',self.probe),('ROOT',self.evidence),('RUNTIME_HASH',hashlib.sha256(b'runtime').hexdigest())]:
            self.enterContext(mock.patch.object(I,name,value))
        self.enterContext(mock.patch.object(I.B,'game_closed',return_value=True))
        self.enterContext(mock.patch.object(I.subprocess,'run',return_value=mock.Mock(returncode=0,stdout=b'test stub',stderr=b'')))
    def test_preflight_does_not_install(self):
        self.assertFalse(I.prepare(self.f.destination)['installed']);self.assertFalse(self.probe.exists())
    def test_install_arms_last_and_preserves_sources(self):
        before=self.f.originals();r=I.prepare(self.f.destination,True)
        self.assertTrue(r['installed']);self.assertEqual(before,self.f.originals())
        self.assertTrue((self.probe/'enabled.txt').exists());self.assertEqual(r['keys'],2)
        self.assertTrue((Path(r['evidence'])/'install.json').exists())
    def test_runtime_or_legacy_drift_refuses(self):
        (self.runtime/'UE4SS.dll').write_bytes(b'changed')
        with self.assertRaises(ValueError):I.prepare(self.f.destination,True)
        self.assertFalse(self.probe.exists())
    def test_staging_failure_never_arms(self):
        write=I.B.write_new
        def fail(p,raw):
            if Path(p)==self.probe/'Scripts/main.lua':raise OSError('disk full')
            return write(p,raw)
        with mock.patch.object(I.B,'write_new',side_effect=fail),self.assertRaises(OSError):I.prepare(self.f.destination,True)
        self.assertFalse((self.probe/'enabled.txt').exists())
    def test_changed_journal_during_staging_never_arms(self):
        write=I.B.write_new
        def change(p,raw):
            write(p,raw)
            if Path(p)==self.probe/'Scripts/main.lua':next(self.f.journals.iterdir()).write_bytes(b'changed')
        with mock.patch.object(I.B,'write_new',side_effect=change),self.assertRaises(ValueError):I.prepare(self.f.destination,True)
        self.assertFalse((self.probe/'enabled.txt').exists())
    def test_failed_native_regressions_refuse_before_install(self):
        with mock.patch.object(I.subprocess,'run',return_value=mock.Mock(returncode=1,stdout=b'failed regression',stderr=b'')):
            with self.assertRaisesRegex(ValueError,'diagnostic regressions failed'):I.prepare(self.f.destination,True)
        self.assertFalse(self.probe.exists())
    def test_failure_after_enable_creation_disarms(self):
        write=I.B.write_new
        def fail(p,raw):
            write(p,raw)
            if Path(p)==self.probe/'enabled.txt':raise OSError('uncertain enable write')
        with mock.patch.object(I.B,'write_new',side_effect=fail),self.assertRaises(OSError):I.prepare(self.f.destination,True)
        self.assertFalse((self.probe/'enabled.txt').exists())
        self.assertFalse((self.probe/'Scripts/run.txt').exists())
    def test_existing_probe_preserved(self):
        self.probe.mkdir();(self.probe/'keep').write_bytes(b'keep')
        with self.assertRaises(ValueError):I.prepare(self.f.destination,True)
        self.assertEqual((self.probe/'keep').read_bytes(),b'keep')
if __name__=='__main__':unittest.main()
