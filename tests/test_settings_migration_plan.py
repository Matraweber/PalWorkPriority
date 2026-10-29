from pathlib import Path
import tempfile,sys,unittest,base64
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
import settings_migration_backup as B
import settings_migration_plan as P
W='a'*32;G='00000001000000020000000300000004';ALIAS='1-2-3-4'
def envelope(body,gen):
    h=2166136261
    for x in body:h=((h^x)*16777619)&0xffffffff
    return f'# PWP-DATA 1 {gen} {len(body)} {h:08x}\n'.encode()+body
class PlanTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
        self.p=b'# baseline=vanilla\npalA|1|X\npalA|2|3\n'
        self.c=b'1-2-3-4|Mining|Stone|OFF\n1-2-3-4|Mining|Ore|300\n'
        (self.root/'priorities.txt').write_bytes(self.p);(self.root/'caps.txt').write_bytes(self.c)
    def plan(self):return P.proposal(B.capture(self.root),W,G,ALIAS)
    def test_actual_parser_plan_preserves_unproven_pals_and_off(self):
        r=self.plan();p=r['plan']
        self.assertFalse(r['activation_allowed']);self.assertFalse(r['live_scope_verified']);self.assertFalse(p['authorized'])
        self.assertEqual(p['candidate']['counts'],{'priorities':0,'limits':2})
        self.assertEqual(p['preserved']['counts']['priorities'],2)
        self.assertIn('palA|1|X',p['preserved']['bodies']['priorities'])
        self.assertIn(G+'|Mining|Stone|OFF',p['candidate']['bodies']['limits'])
        self.assertEqual(base64.b64decode(p['backup']['original']['priorities']['bytes']),self.p)
    def test_newest_checked_recovery_selected_exact_original(self):
        newest=envelope(self.c.replace(b'300',b'450'),8)
        # A 0.5 live file: a plain one beside a .bak is a 0.4.1 or hand edit
        # and wins over every generation (review round 3, datafile.read).
        (self.root/'caps.txt').write_bytes(envelope(self.c,6))
        (self.root/'caps.txt.pending').write_bytes(newest)
        (self.root/'caps.txt.bak').write_bytes(envelope(self.c,7))
        r=self.plan()
        self.assertEqual(r['selected']['limits']['source'],'caps.txt.pending')
        self.assertEqual(r['selected']['limits']['generation'],8)
        self.assertEqual(base64.b64decode(r['plan']['backup']['original']['limits']['bytes']),newest)
        self.assertIn('|450',r['plan']['candidate']['bodies']['limits'])
    def test_equal_generation_keeps_live_and_unchecked_tmp_rejected(self):
        (self.root/'caps.txt').write_bytes(envelope(self.c,3))
        (self.root/'caps.txt.bak').write_bytes(envelope(self.c.replace(b'300',b'400'),3))
        (self.root/'caps.txt.tmp').write_bytes(self.c.replace(b'300',b'500'))
        self.assertEqual(self.plan()['selected']['limits']['source'],'caps.txt')
    def test_corrupt_live_uses_valid_backup(self):
        (self.root/'caps.txt').write_bytes(b'# PWP-DATA 1 9 1 deadbeef\nbad')
        (self.root/'caps.txt.bak').write_bytes(envelope(self.c,2))
        self.assertEqual(self.plan()['selected']['limits']['source'],'caps.txt.bak')
    def test_missing_or_invalid_stream_refuses_no_invented_defaults(self):
        (self.root/'caps.txt').unlink()
        with self.assertRaises(Exception):self.plan()
        (self.root/'caps.txt').write_bytes(b'broken\n')
        with self.assertRaises(Exception):self.plan()
    def test_wrong_alias_claim_refuses(self):
        with self.assertRaises(Exception):P.proposal(B.capture(self.root),W,G,'1-2-3-5')
    def test_all_files_remain_exact(self):
        before=B.capture(self.root);self.plan();self.assertEqual(B.capture(self.root),before)
    def test_non_utf8_original_comment_preserved_losslessly(self):
        raw=b'# old comment \xff\xfe\x00\n'+self.c
        (self.root/'caps.txt').write_bytes(raw)
        r=self.plan();original=r['plan']['backup']['original']['limits']
        self.assertEqual(original['encoding'],'base64')
        self.assertEqual(base64.b64decode(original['bytes']),raw)
        self.assertEqual(r['plan']['candidate']['counts']['limits'],2)
if __name__=='__main__':unittest.main()
