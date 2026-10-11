from pathlib import Path
from dataclasses import replace
import hashlib
import json
import os
import sys
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
import settings_installation_binding as M
try:
    from tests import test_settings_export_bundle as F
    from tests import test_analyze_export_membership as A
except ImportError:
    import test_settings_export_bundle as F
    import test_analyze_export_membership as A


class Binding(unittest.TestCase):
    def setUp(self):
        self.f=F.Bundle();self.f.setUp();self.addCleanup(self.f.doCleanups)
        self.key='A'*64;other='B'*64
        (self.f.source/'priorities.txt').write_bytes(F.P+self.key.encode()+b'|1|3\n'+other.encode()+b'|2|X\n')
        self.f.claims=[dict(pal=self.key,storage=F.W,guild=F.G)]
        for slot,gen in (('A',1),('B',2)):
            (self.f.journals/f'pwp-record-v1-{F.W}-{F.G}-priorities-{slot}.record').write_bytes(
                F.record('priorities',F.P+self.key.encode()+b'|1|X\n',gen))
        scripts=self.f.source/'Scripts';scripts.mkdir();(scripts/'main.lua').write_bytes(b'guard main')
        (scripts/'helper.lua').write_bytes(b'helper');(self.f.source/'priority.log').write_bytes(b'changing log')
        (scripts/'priority.log').write_bytes(b'protected nested log')
        self.f.prepare()
        runtime=self.f.root/'runtime';runtime.mkdir();dll=runtime/'UE4SS.dll';dll.write_bytes(b'pinned runtime')
        evidence=self.f.root/'evidence';evidence.mkdir()
        manifest_hash=hashlib.sha256((self.f.destination/'proposal.json').read_bytes()).hexdigest()
        expected=dict(nonce='1'*32,manifest_sha256=manifest_hash,storage=F.W,guild=F.G,alias=F.ALIAS,
                      keys=[self.key,other])
        with mock.patch.dict(A.EXPECTED,expected,clear=True):raw=A.render(A.records()).encode('ascii')
        (evidence/'native.log').write_bytes(raw)
        analysis=M.Analyzer.analyze(raw.decode('ascii'),**expected)
        (evidence/'analysis.json').write_text(json.dumps(analysis),encoding='utf-8')
        install={'nonce':expected['nonce'],'runtime_sha256':hashlib.sha256(b'pinned runtime').hexdigest(),
                 'bundle':str(self.f.destination),'probe':str(runtime/'Mods/PWPExportMembershipRead'),
                 'config':{k:v for k,v in expected.items() if k!='nonce'},'read_only':True,
                 'activation_allowed':False,'replacement_allowed':False,'sources':{},
                 'production_before':{p.relative_to(self.f.source).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in self.f.source.rglob('*') if p.is_file() and p.relative_to(self.f.source).as_posix()!='priority.log'}}
        (evidence/'install.json').write_text(json.dumps(install),encoding='utf-8')
        self.paths=M.Paths(self.f.source,dll,self.f.journals,self.f.destination,evidence)
        self.pins=M.Pins(hashlib.sha256(b'pinned runtime').hexdigest(),hashlib.sha256(b'guard main').hexdigest(),
                         manifest_hash,hashlib.sha256(raw).hexdigest(),'1'*32,F.W,F.G,F.ALIAS,
                         hashlib.sha256((evidence/'install.json').read_bytes()).hexdigest())

    def capture(self,**kw):return M.capture_for(self.paths,self.pins,lambda:True,**kw)
    def check(self,binding,**kw):return M.recheck_for(binding,self.paths,self.pins,lambda:True,**kw)

    def test_capture_recheck_and_exact_marker_do_not_change_binding(self):
        before=self.f.originals();binding=self.capture()
        self.assertEqual(binding,self.check(binding))
        self.assertEqual(binding['roots']['mod']['inode'],self.f.source.stat().st_ino)
        self.assertEqual(len(binding['legacy']),8);self.assertEqual(len(binding['journals']),4)
        self.assertEqual(len(binding['trial']),2)
        marker=b'owned rehearsal\n';(self.f.source/M.MARKER).write_bytes(marker)
        (self.f.source/M.LOCK).write_bytes(b'')
        (self.f.source/'priority.log').write_bytes(b'new diagnostic log')
        self.assertEqual(binding,self.check(binding,expected_marker=marker))
        for k,v in binding.items():
            if k.endswith(('_allowed','_verified','_grant')):self.assertIs(v,False)
        (self.f.source/M.MARKER).unlink();(self.f.source/M.LOCK).unlink()
        (self.f.source/'priority.log').write_bytes(b'changing log')
        self.assertEqual(before,self.f.originals(),'capture/recheck wrote installed payload')

    def test_tampered_binding_paths_and_exclusions_not_followed(self):
        binding=self.capture()
        for field,value in (('mod','Z:/never-follow'),('excluded_root_paths',['Scripts/main.lua']),
                            ('binding_sha256','0'*64),('activation_allowed',True)):
            bad={**binding,field:value}
            with self.subTest(field=field),self.assertRaisesRegex(ValueError,'binding drift'):self.check(bad)

    def test_guard_runtime_scope_and_manifest_pins(self):
        for field in ('runtime_sha256','main_sha256','manifest_sha256','membership_sha256','install_sha256','guild','storage'):
            pins=replace(self.pins,**{field:'0'*len(getattr(self.pins,field))})
            with self.subTest(field=field),self.assertRaises(ValueError):
                M.capture_for(self.paths,pins,lambda:True)

    def test_all_payload_groups_and_code_drift_refuse(self):
        binding=self.capture()
        files=[self.f.source/'Scripts/helper.lua',self.f.source/'priorities.txt',
               self.f.source/'caps.txt.pending',self.f.source/'async-trial/receipt.lua',
               next(self.f.journals.glob('*priorities-A*'))]
        for path in files:
            original=path.read_bytes() if path.exists()else None
            path.write_bytes(b'newer edit must survive')
            with self.subTest(path=path),self.assertRaises(ValueError):self.check(binding)
            self.assertEqual(path.read_bytes(),b'newer edit must survive')
            if original is None:path.unlink()
            else:path.write_bytes(original)
            # New baseline must still match the immutable bundle bytes.
            binding=self.capture()

    def test_priority_log_exclusion_is_root_only_and_new_files_fail(self):
        binding=self.capture()
        nested=self.f.source/'Scripts/priority.log';nested.write_bytes(b'changed nested log')
        with self.assertRaisesRegex(ValueError,'protected file tree differs'):self.check(binding)
        nested.write_bytes(b'protected nested log')
        (self.f.source/'Scripts/new.lua').write_bytes(b'unreviewed code')
        with self.assertRaisesRegex(ValueError,'protected file tree differs'):self.capture()

    def test_initial_dependency_tamper_and_receipt_identity_fail(self):
        helper=self.f.source/'Scripts/helper.lua';helper.write_bytes(b'changed BEFORE capture')
        with self.assertRaisesRegex(ValueError,'protected file tree differs'):self.capture()
        helper.write_bytes(b'helper')
        path=self.paths.membership/'install.json';original=json.loads(path.read_bytes())
        for field,value in (('nonce','2'*32),('probe','Z:/not-followed'),('activation_allowed',True),
                            ('config',{}),('runtime_sha256','0'*64)):
            path.write_text(json.dumps({**original,field:value}),encoding='utf-8')
            pins=replace(self.pins,install_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
            with self.subTest(field=field),self.assertRaisesRegex(ValueError,'installation receipt'):
                M.capture_for(self.paths,pins,lambda:True)

    def test_marker_and_lock_validation(self):
        marker=self.f.source/M.MARKER;lock=self.f.source/M.LOCK
        marker.write_bytes(b'foreign')
        with self.assertRaisesRegex(ValueError,'marker'):self.capture()
        with self.assertRaisesRegex(ValueError,'marker'):self.capture(expected_marker=b'own')
        marker.unlink();marker.mkdir()
        with self.assertRaises(ValueError):self.capture()
        marker.rmdir();lock.write_bytes(b'nonempty')
        with self.assertRaisesRegex(ValueError,'lock artifact'):self.capture()
        lock.unlink();lock.mkdir()
        with self.assertRaises(ValueError):self.capture()
        lock.rmdir();other=self.f.source/'empty';other.write_bytes(b'');os.link(other,lock)
        with self.assertRaisesRegex(ValueError,'lock artifact'):self.capture()

    @unittest.skipUnless(os.name=='nt','real share-zero handle')
    def test_recheck_under_real_share_zero_lock_reads_metadata_only(self):
        import settings_cutover_lock as L
        binding=self.capture();k=L._kernel()
        handle=k.CreateFileW(str(self.f.source/M.LOCK),0xC0000000,0,None,4,0x80,None)
        self.assertNotEqual(handle,L.ctypes.c_void_p(-1).value)
        try:
            marker=b'own marker';(self.f.source/M.MARKER).write_bytes(marker)
            self.assertEqual(binding,self.check(binding,expected_marker=marker))
        finally:self.assertTrue(k.CloseHandle(handle))

    def test_root_identity_replacement_refused_even_identical_bytes(self):
        import shutil
        binding=self.capture();held=self.f.source.with_name('held-original')
        self.f.source.rename(held);shutil.copytree(held,self.f.source)
        with self.assertRaisesRegex(ValueError,'root identity'):self.check(binding)

    def test_process_guard_and_during_capture_drift(self):
        calls=0
        def starts():
            nonlocal calls
            calls+=1;return calls==1
        with self.assertRaisesRegex(ValueError,'process started'):M.capture_for(self.paths,self.pins,starts)
        with mock.patch.object(M,'_read',side_effect=AssertionError('read before process guard')):
            with self.assertRaisesRegex(ValueError,'must be closed'):M.capture_for(self.paths,self.pins,lambda:False)
        calls=0
        def changes():
            nonlocal calls
            calls+=1
            if calls==2:(self.f.source/'Scripts/helper.lua').write_bytes(b'between reads')
            return True
        with self.assertRaisesRegex(ValueError,'changed during binding|protected file tree differs'):
            M.capture_for(self.paths,self.pins,changes)

    def test_membership_analyzer_is_executed_and_source_paths_not_followed(self):
        raw=(self.paths.membership/'native.log').read_bytes().replace(b'event=done',b'event=failed')
        (self.paths.membership/'native.log').write_bytes(raw)
        pins=replace(self.pins,membership_sha256=hashlib.sha256(raw).hexdigest())
        with self.assertRaises(ValueError):M.capture_for(self.paths,pins,lambda:True)
        # Even a manifest with a correspondingly changed trusted test pin cannot
        # redirect IO through its source/journal-root fields.
        path=self.paths.bundle/'proposal.json';m=json.loads(path.read_bytes())
        m['journal_root']='Z:/DO-NOT-FOLLOW';path.write_text(json.dumps(m),encoding='utf-8')
        pins=replace(self.pins,manifest_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        with mock.patch.object(M.J,'capture',side_effect=AssertionError('followed manifest path')):
            with self.assertRaisesRegex(ValueError,'journal path differs'):M.capture_for(self.paths,pins,lambda:True)


if __name__=='__main__':unittest.main()
