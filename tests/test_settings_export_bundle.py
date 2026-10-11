from pathlib import Path
import base64
import hashlib
import json
import sys
import tempfile
import unittest
from unittest import mock
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
import settings_export_bundle as E
# Import the independent binary fixture encoder, not the planner's decoder.
try: from tests.test_settings_journal_export import record,W,G
except ImportError: from test_settings_journal_export import record,W,G
ALIAS='-1145324613--1145324613--1145324613--1145324613'
P=b'# Pal Work Priority: palkey|worktype|priority (1 highest, 5 lowest, X disabled)\n'
C=(b'# Legacy work-type groups: may stop unrelated products of the same suitability.\n'
   b'# guild|work|item|ceiling (OFF masks an inherited group rule for this guild)\n')

class Bundle(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.source=self.root/'mod';self.journals=self.root/'journals'
        self.source.mkdir();self.journals.mkdir();(self.source/'async-trial').mkdir()
        (self.source/'async-trial/launch.lua').write_bytes(b'error("never execute")')
        (self.source/'async-trial/receipt.lua').write_bytes(b'error("never execute")')
        (self.source/'priorities.txt').write_bytes(P+b'mine|1|3\nunrelated|2|X\n')
        (self.source/'caps.txt').write_bytes(C+ALIAS.encode()+b'|Mining|Stone|100\n*|Mining|Wood|200\n')
        for stream,body in [('priorities',P+b'mine|1|X\n'),('limits',C+G.encode()+b'|Mining|Stone|OFF\n')]:
            for slot,gen in [('A',1),('B',2)]:
                (self.journals/f'pwp-record-v1-{W}-{G}-{stream}-{slot}.record').write_bytes(record(stream,body,gen))
        self.claims=[dict(pal='mine',storage=W,guild=G)]
        self.destination=self.root/'bundle'
    def prepare(self,q=lambda:True):
        return E.prepare(self.source,self.journals,self.destination,W,G,ALIAS,self.claims,q)
    def originals(self):
        return {str(p.relative_to(self.root)):p.read_bytes() for d in (self.source,self.journals) for p in d.rglob('*') if p.is_file()}
    def test_complete_bundle_preserves_originals_and_unrelated_rows(self):
        before=self.originals();m=self.prepare()
        self.assertEqual(before,self.originals());self.assertFalse(m['replacement_allowed'])
        self.assertFalse(m['membership_verified']);self.assertFalse(m['plan']['deletion_coverage_verified'])
        p=(self.destination/'candidates/priorities.body').read_bytes()
        c=(self.destination/'candidates/limits.body').read_bytes()
        self.assertIn(b'mine|1|X',p);self.assertIn(b'unrelated|2|X',p)
        self.assertIn(ALIAS.encode()+b'|Mining|Stone|OFF',c);self.assertIn(b'*|Mining|Wood|200',c)
        disk=json.loads((self.destination/'proposal.json').read_bytes());self.assertEqual(disk,m)
        for name,info in m['files'].items():
            raw=(self.destination/name).read_bytes()
            self.assertEqual(hashlib.sha256(raw).hexdigest(),info['sha256'])
            self.assertEqual(len(raw),info['bytes'])
        with self.assertRaisesRegex(ValueError,'destination exists'):self.prepare()
    def test_missing_ownership_refuses_before_creating_bundle(self):
        self.claims=[]
        with self.assertRaises(Exception):self.prepare()
        self.assertFalse(self.destination.exists())
    def test_live_process_and_source_mutation_block_completion(self):
        with self.assertRaisesRegex(ValueError,'offline'):self.prepare(lambda:False)
        self.assertFalse(self.destination.exists())
        calls=0
        def changed():
            nonlocal calls
            calls+=1
            if calls==3:(self.source/'priorities.txt').write_bytes(P+b'other|1|2\n')
            return True
        with self.assertRaisesRegex(ValueError,'legacy changed'):self.prepare(changed)
        self.assertFalse((self.destination/'proposal.json').exists())
    def test_marker_mutation_blocks_completion(self):
        calls=0
        def changed():
            nonlocal calls
            calls+=1
            if calls==3:(self.source/'async-trial/launch.lua').write_bytes(b'changed')
            return True
        with self.assertRaisesRegex(ValueError,'trial markers changed'):self.prepare(changed)
        self.assertFalse((self.destination/'proposal.json').exists())
    def test_destination_cannot_be_inside_live_roots(self):
        for root in (self.source,self.journals):
            self.destination=root/'bundle'
            with self.assertRaisesRegex(ValueError,'outside live roots'):self.prepare()
            self.assertFalse(self.destination.exists())
    def test_write_failure_preserves_source_and_incomplete_bundle(self):
        before=self.originals();write=E.B.write_new;calls=0
        def fail(path,raw):
            nonlocal calls
            calls+=1
            if calls==3:raise OSError('injected disk full')
            return write(path,raw)
        with mock.patch.object(E.B,'write_new',side_effect=fail):
            with self.assertRaisesRegex(OSError,'disk full'):self.prepare()
        self.assertEqual(before,self.originals());self.assertTrue(self.destination.exists())
        self.assertFalse((self.destination/'proposal.json').exists())
        with self.assertRaisesRegex(ValueError,'destination exists'):self.prepare()
    def test_verifier_recomputes_and_rejects_tampering(self):
        self.prepare()
        self.assertFalse(E.verify(self.destination)['replacement_allowed'])
        path=self.destination/'candidates/priorities.body'
        original=path.read_bytes();path.write_bytes(original.replace(b'mine|1|X',b'mine|1|2'))
        with self.assertRaisesRegex(ValueError,'artifact bytes'):E.verify(self.destination)
        path.write_bytes(original)
        manifest=self.destination/'proposal.json';raw=manifest.read_bytes();data=json.loads(raw)
        data['plan']['bodies']['priorities']=data['plan']['bodies']['priorities'].replace('mine|1|X','mine|1|2')
        manifest.write_text(json.dumps(data),encoding='utf-8')
        with self.assertRaisesRegex(ValueError,'plan differs'):E.verify(self.destination)
        manifest.write_bytes(raw);data=json.loads(raw);data['replacement_allowed']=True
        manifest.write_text(json.dumps(data),encoding='utf-8')
        with self.assertRaisesRegex(ValueError,'cannot grant'):E.verify(self.destination)
    def test_verifier_rejects_missing_and_extra_artifacts(self):
        self.prepare();path=self.destination/'extra';path.write_bytes(b'extra')
        with self.assertRaisesRegex(ValueError,'unexpected'):E.verify(self.destination)
        path.unlink();path=self.destination/'candidates/limits.body';path.unlink()
        with self.assertRaisesRegex(ValueError,'missing bundle'):E.verify(self.destination)
    def test_pending_legacy_generation_preserved_and_selected(self):
        try: from tests.test_settings_migration_plan import envelope
        except ImportError: from test_settings_migration_plan import envelope
        # The selected unrelated row comes from a checked pending generation.
        newer=P+b'mine|1|5\nunrelated|2|4\n'
        (self.source/'priorities.txt.pending').write_bytes(envelope(newer,17))
        r=self.prepare()
        self.assertEqual(r['plan']['selected_legacy']['priorities']['generation'],17)
        self.assertIn('unrelated|2|4',r['plan']['bodies']['priorities'])
        self.assertEqual((self.destination/'legacy/priorities.txt.pending').read_bytes(),envelope(newer,17))
    def test_sources_and_launcher_are_preserved_on_every_interrupted_write(self):
        # All artifact boundaries, including final proposal publication.
        count=len(self.prepare()['files'])+1
        for stop in range(1,count+1):
            self.destination=self.root/f'partial-{stop}'
            before=self.originals();write=E.B.write_new;calls=0
            def interrupted(path,raw):
                nonlocal calls
                calls+=1
                if calls==stop:raise OSError('interrupted')
                return write(path,raw)
            with mock.patch.object(E.B,'write_new',side_effect=interrupted):
                with self.assertRaises(OSError):self.prepare()
            self.assertEqual(before,self.originals())
            self.assertFalse((self.destination/'proposal.json').exists())
    def test_journal_change_during_copy_aborts(self):
        calls=0
        path=self.journals/f'pwp-record-v1-{W}-{G}-limits-B.record'
        def changed():
            nonlocal calls
            calls+=1
            if calls==4:path.write_bytes(record('limits',C+G.encode()+b'|Mining|Stone|222\n',3))
            return True
        with self.assertRaisesRegex(ValueError,'journals changed'):self.prepare(changed)
        self.assertFalse((self.destination/'proposal.json').exists())

    def test_corrupt_newer_journal_never_becomes_older_export(self):
        p=self.journals/f'pwp-record-v1-{W}-{G}-limits-B.record';raw=bytearray(p.read_bytes());raw[-1]^=1;p.write_bytes(raw)
        with self.assertRaisesRegex(ValueError,'checksum'):self.prepare()
        self.assertFalse(self.destination.exists())

if __name__=='__main__':unittest.main()
