import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import settings_export_coverage as C
try:
    from tests.test_settings_journal_export import record, W, G
    from tests.test_settings_migration_plan import envelope
except ImportError:
    from test_settings_journal_export import record, W, G
    from test_settings_migration_plan import envelope

P = b'# Pal Work Priority: palkey|worktype|priority (1 highest, 5 lowest, X disabled)\n'
LIMITS = (b'# Production limits. Mining limits stop only the rocks of their item; every other limit switches its whole work type.\n'
          b'# guild|work|item|limit (OFF hides an inherited limit for this guild)\n')
ALIAS = '-1145324613--1145324613--1145324613--1145324613'


class Coverage(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.source = self.root / 'mod'; self.source.mkdir()
        (self.source / 'async-trial').mkdir()
        self.journals = self.root / 'journals'; self.journals.mkdir()
        self.bundle = self.root / 'bundle'
        (self.source / 'priorities.txt').write_bytes(P+b'obsolete|1|3\n')
        legacy = P+b'shared|1|X\nshared|2|3\nshared|3|X\nunclaimed|1|X\nforeign|2|4\ndeleted|1|X\n'
        (self.source / 'priorities.txt.pending').write_bytes(envelope(legacy, 17))
        (self.source / 'caps.txt').write_bytes(LIMITS)
        for stream, body in [('priorities', P+b'new|1|X\nshared|1|X\nshared|2|X\nshared|4|2\n'),
                             ('limits', LIMITS)]:
            for slot, gen in [('A', 1), ('B', 2)]:
                old = P+b'historical|2|X\n'+body[len(P):] if stream == 'priorities' and slot == 'A' else body
                (self.journals/f'pwp-record-v1-{W}-{G}-{stream}-{slot}.record').write_bytes(record(stream, old, gen))
        claims = [dict(pal=p, storage=W, guild=G) for p in ('shared', 'new', 'deleted', 'claimonly')]
        claims.append(dict(pal='foreign', storage=W, guild='c'*32))
        self.manifest = C.Bundle.prepare(self.source, self.journals, self.bundle, W, G, ALIAS, claims, lambda: True)

    def test_selected_rows_false_values_claims_and_diff_semantics(self):
        r = C.audit(self.bundle); rows = {p['pal']: p for p in r['pals']}
        self.assertEqual(r['selected_legacy']['generation'], 17)
        self.assertNotIn('obsolete', rows)
        self.assertEqual(r['coverage'], {'legacy_only': ['deleted', 'foreign', 'unclaimed'],
                         'journal_only': ['new'], 'shared': ['shared'], 'claim_only': ['claimonly'],
                         'history_only': ['historical']})
        self.assertEqual(r['claim_categories']['foreign'], ['foreign'])
        self.assertEqual(r['ambiguous_legacy_only_unclaimed'], ['unclaimed'])
        self.assertEqual(rows['shared']['legacy_to_journal'], dict(removed=1, added=1, changed=1))
        self.assertEqual(rows['deleted']['legacy_to_candidate']['removed'], 1)
        self.assertEqual(rows['new']['legacy_to_journal']['added'], 1)
        self.assertEqual(rows['unclaimed']['legacy_to_journal']['removed'], 1)
        self.assertEqual(rows['unclaimed']['legacy_to_candidate'], dict(removed=0, added=0, changed=0))
        self.assertEqual(r['older_peer_only_keys'], ['historical'])
        self.assertIn('historical', r['lookup_union'])
        self.assertEqual(rows['historical']['retained_journal_slots'], ['A'])
        self.assertFalse(r['retained_history_complete'])
        self.assertEqual(rows['historical']['claim_category'], 'unclaimed')
        for key, value in r.items():
            if key.endswith(('_verified', '_allowed', '_grant')): self.assertIs(value, False)

    def test_hash_binding_and_no_writes(self):
        before = {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        r = C.audit(self.bundle)
        self.assertEqual(r['manifest_sha256'], hashlib.sha256((self.bundle/'proposal.json').read_bytes()).hexdigest())
        for stream, h in r['candidate_hashes'].items():
            self.assertEqual(h, hashlib.sha256((self.bundle/f'candidates/{stream}.body').read_bytes()).hexdigest())
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()})

    def test_source_paths_never_followed(self):
        path = self.bundle/'proposal.json'; m = json.loads(path.read_bytes())
        m['source']['source'] = 'Z:/DO-NOT-READ'; m['journal_root'] = 'Z:/DO-NOT-READ'
        path.write_text(json.dumps(m), encoding='utf-8')
        read = C.Bundle.B.read_exact; seen = []
        def checked(path, *args):
            self.assertTrue(Path(path).is_relative_to(self.bundle)); seen.append(path)
            return read(path, *args)
        with mock.patch.object(C.Bundle.B, 'read_exact', side_effect=checked): C.audit(self.bundle)
        self.assertTrue(seen)

    def test_tampered_candidate_rejected(self):
        path = self.bundle/'candidates/priorities.body'; path.write_bytes(P)
        with self.assertRaises(Exception): C.audit(self.bundle)

    def test_altered_claims_rejected(self):
        path = self.bundle/'proposal.json'; m = json.loads(path.read_bytes())
        m['membership_claims'] = []
        path.write_text(json.dumps(m), encoding='utf-8')
        with self.assertRaises(Exception): C.audit(self.bundle)

    def test_missing_older_slot_is_not_complete_history(self):
        (self.journals/f'pwp-record-v1-{W}-{G}-priorities-A.record').unlink()
        other = self.root/'one-slot'
        C.Bundle.prepare(self.source, self.journals, other, W, G, ALIAS,
                         self.manifest['membership_claims'], lambda: True)
        r = C.audit(other)
        self.assertEqual(r['retained_priority_records']['A'], {'state': 'missing', 'keys': []})
        self.assertEqual(r['older_peer_only_keys'], [])
        self.assertFalse(r['retained_history_complete'])

    def test_corrupt_older_slot_rejected_not_ignored(self):
        path = self.bundle/'journals/priorities-A.record'
        raw = bytearray(path.read_bytes()); raw[-1] ^= 1; path.write_bytes(raw)
        with self.assertRaises(Exception): C.audit(self.bundle)

    def test_manifest_changed_after_verification_rejected(self):
        original = C.Bundle.verify
        def changed(path):
            m = original(path)
            with (path/'proposal.json').open('ab') as f: f.write(b' ')
            return m
        with mock.patch.object(C.Bundle, 'verify', side_effect=changed):
            with self.assertRaisesRegex(ValueError, 'manifest changed during audit'): C.audit(self.bundle)

    def test_artifact_changed_during_decode_rejected(self):
        decode = C._decode
        def changed(manifest):
            rows = decode(manifest)
            (self.bundle/'candidates/priorities.body').write_bytes(P)
            return rows
        with mock.patch.object(C, '_decode', side_effect=changed):
            with self.assertRaisesRegex(ValueError, 'artifact bytes changed'): C.audit(self.bundle)

    def test_cli_json_success_and_failure(self):
        command = [sys.executable, '-B', str(ROOT/'tools/settings_export_coverage.py')]
        r = subprocess.run(command+[str(self.bundle)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)['contract'], 'PWP-EXPORT-COVERAGE-1')
        r = subprocess.run(command+[str(self.root/'missing')], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1); self.assertFalse(json.loads(r.stdout)['audit_completed'])


if __name__ == '__main__': unittest.main()
