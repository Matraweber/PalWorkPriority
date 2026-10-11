"""Independent synthetic evidence; never installs, drives the game, or runs CLI."""
import copy
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
from contextlib import redirect_stdout
import io
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'.test-deps'))
from lupa.lua54 import LuaRuntime

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
import accept_native_settings_chain_trial as acceptance

WORLD, GUILD, NONCE = '7'*32, '8'*32, 'chain-fixture-20261004'
STREAMS = ('priorities', 'limits')


def fixture_body(stream, revision):
    if stream == 'priorities':
        return ('# Pal Work Priority: palkey|worktype|priority (1 highest, 5 lowest, X disabled)\n'
                '# baseline=vanilla\ntrial-pal|1|1\ntrial-pal|2|2\ntrial-pal|3|3\ntrial-pal|4|4\n'
                'trial-pal|5|5\ntrial-pal|6|X\n'+f'trial-pal|7|{revision}\n').encode()
    return ('# Legacy work-type groups: may stop unrelated products of the same suitability.\n'
            '# guild|work|item|ceiling (OFF masks an inherited group rule for this guild)\n'
            +GUILD+f'|Mining|Ore|{revision*100}\n'+GUILD+'|Mining|Stone|OFF\n').encode()


def fixture_payload(stream, revision):
    body = fixture_body(stream, revision)
    return f'PWP-SETTINGS-1\n{WORLD}\n{GUILD}\n{stream}\n{len(body)}\n'.encode()+body


def fixture_record(stream, generation, revision):
    scope = f'PWP-SCOPE-1:{WORLD}:{GUILD}:{stream}'.encode()
    payload = fixture_payload(stream, revision)
    raw = b'PWPJNL1\n'+struct.pack('<HII', len(scope), generation, len(payload))+scope+payload
    return raw+hashlib.sha256(raw).digest()


class Acceptance(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pwp-chain-accept-')
        self.addCleanup(self.temp.cleanup)
        self.store = Path(self.temp.name)
        names = [f'pwp-record-v1-{w*32}-{g*32}-{s}-{a}.record'
                 for w, g in (('1', '2'), ('5', '6')) for s in STREAMS for a in ('A', 'B')]
        names += [f'pwp-record-v1-{"3"*32}-{"4"*32}-{s}-{a}.record'
                  for s, a in (('priorities', 'A'), ('priorities', 'B'), ('limits', 'A'))]
        self.prior = {}
        for name in names:
            raw = ('exact preserved fixture bytes: '+name).encode()
            (self.store/name).write_bytes(raw)
            self.prior[name] = hashlib.sha256(raw).hexdigest()
        self.disk()

    def disk(self, before=2, tail=1):
        self.before, self.tail = before, tail
        self.gen = before+tail
        older_revision = 3 if tail == 1 else 4
        self.paths, self.records = {}, {}
        for stream in STREAMS:
            for gen, revision in ((self.gen-1, older_revision), (self.gen, 5)):
                slot = 'A' if gen % 2 else 'B'
                name = f'pwp-record-v1-{WORLD}-{GUILD}-{stream}-{slot}.record'
                p = self.store/name;p.write_bytes(fixture_record(stream, gen, revision))
                self.paths[(stream, slot)] = p
                self.records[name] = hashlib.sha256(p.read_bytes()).hexdigest()

    def test_exact_four_new_and_eleven_preserved_records(self):
        for before, tail in ((2, 1), (3, 1), (2, 2), (3, 2)):
            self.disk(before, tail)
            hashes, records = acceptance.inspect_records(self.store, self.prior)
            self.assertEqual(hashes, self.records)
            for stream in STREAMS:
                self.assertEqual(sorted(r['generation'] for r in records[stream].values()), [self.gen-1, self.gen])
            self.assertEqual(acceptance.inspect_records(self.store, self.prior, hashes)[0], hashes)

    def test_corruption_even_rehashed_record(self):
        for p in self.paths.values():
            original = p.read_bytes()
            changes = [original[:-1], original+b'x', original[:-1]+bytes([original[-1]^1])]
            for offset in (0, 8, 10, 14, 18, len(original)-33):
                raw = bytearray(original[:-32]);raw[offset] ^= 1
                changes.append(bytes(raw)+hashlib.sha256(raw).digest())
            try:
                for value in changes:
                    p.write_bytes(value)
                    with self.assertRaises(ValueError):
                        acceptance.inspect_records(self.store, self.prior)
            finally:
                p.write_bytes(original)

    def test_prior_name_allowlist_and_every_preserved_hash(self):
        original = next(iter(self.prior))
        for name in ('../outside', str(self.store/original),
                     f'pwp-record-v1-{"3"*32}-{"4"*32}-limits-B.record', next(iter(self.records))):
            bad = dict(self.prior);bad[name] = bad.pop(original)
            with self.assertRaises(ValueError):
                acceptance.inspect_records(self.store, bad)
        for name in self.prior:
            p = self.store/name;raw = p.read_bytes();p.write_bytes(raw+b'x')
            try:
                with self.assertRaises(ValueError):
                    acceptance.inspect_records(self.store, self.prior)
            finally:
                p.write_bytes(raw)

    def test_missing_unexpected_or_changed_recovery_records(self):
        for p in list(self.paths.values())+[self.store/n for n in self.prior]:
            raw = p.read_bytes();p.unlink()
            try:
                with self.assertRaises(ValueError):
                    acceptance.inspect_records(self.store, self.prior)
            finally:
                p.write_bytes(raw)
        stale = dict(self.records);stale[next(iter(stale))] = '0'*64
        with self.assertRaises(ValueError):
            acceptance.inspect_records(self.store, self.prior, stale)
        (self.store/'unexpected-backup').write_bytes(b'keep')
        with self.assertRaises(ValueError):
            acceptance.inspect_records(self.store, self.prior)


    def composition(self, recovery=False):
        """Run unchanged bootstrap and real Lua chain; mock only IO/scheduler/DLL."""
        root = Path(__file__).resolve().parents[1]
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().TEST_ROOT = root.as_posix()
        lua.globals().NONCE = NONCE
        lua.globals().MODE = 'RECOVER' if recovery else 'WRITE'
        lua.execute("package.path=TEST_ROOT..'/Scripts/?.lua;'..TEST_ROOT..'/experiments/?.lua;'..package.path")
        wire = lua.execute("return dofile(TEST_ROOT..'/experiments/save_native_backend.lua')")
        owners, disk, tick = {}, {}, 0
        if recovery:
            for stream in STREAMS:
                disk[stream] = {}
                for gen, rev in ((self.gen-1, 3 if self.tail == 1 else 4), (self.gen, 5)):
                    disk[stream]['A' if gen % 2 else 'B'] = (gen, fixture_payload(stream, rev).decode())

        def publish(h, rev):
            h['g'] += 1;h['c'] = rev
            disk.setdefault(h['s'], {})['A' if h['g'] % 2 else 'B'] = (h['g'], h['payloads'][rev])
            h['terminal'] = 'initialized' if rev == 1 else 'updated'

        def advance(h):
            if h['phase'] == 'recovering':
                h['g'] = max((g for g, _ in disk.get(h['s'], {}).values()), default=0)
                h['phase'], h['terminal'] = 'awaiting_validation', 'recovered'
            elif h['phase'] in ('ready', 'closing') and h['a'] > h['c']:
                if h['c'] == 0: publish(h, 1)
                if h['a'] > h['c']: publish(h, h['a'])

        def native(cmd, handle, ticket, hextext, length):
            nonlocal tick
            self.assertEqual(len(hextext), length)
            values = wire.unpack(bytes.fromhex(hextext).decode(), 5 if cmd == 1 else 1 if cmd in (4, 5) else 0)
            args = list(values.values())
            out = []
            if cmd == 0: out = ['1']
            elif cmd == 1:
                handle = len(owners)+1
                owners[handle] = dict(s=args[2], scope='PWP-SCOPE-1:'+':'.join(args[:3]), inc=args[3],
                    a=0,c=0,g=0,phase='dormant',terminal='',ticket=0,command=0,revision=0,payloads={})
                out = [str(handle)]
            else:
                h = owners[handle]
                if cmd in (2,4,5,7,8):
                    self.assertGreater(ticket, h['ticket'])
                    h.update(ticket=ticket,command=cmd,revision=0)
                if cmd == 2: h['phase'] = 'recovering'
                elif cmd == 3:
                    out = [h['scope'],h['inc'],'1','recovered','1',str(h['g']),'0','preimage','0','0']
                    for slot in ('A','B'):
                        item = disk.get(h['s'],{}).get(slot)
                        out += ['valid',str(item[0]),item[1]] if item else ['missing','0','']
                elif cmd == 4:
                    self.assertEqual(args, ['existing' if recovery else 'initialize_missing'])
                    h['phase'] = 'ready'
                elif cmd == 5:
                    self.assertFalse(recovery)
                    h['a'] += 1;h['revision'] = h['a'];h['payloads'][h['a']] = args[0]
                    self.assertEqual(args[0], fixture_payload(h['s'], h['a']).decode())
                    out = [str(h['a'])]
                    if (h['a'] <= 3 and self.before == 3) or (h['a'] > 3 and self.tail == 2): publish(h,h['a'])
                elif cmd == 7: h['phase'] = 'closing'
                elif cmd == 9: self.assertEqual(h['phase'], 'closed')
                if cmd in (6,8):
                    advance(h)
                    if cmd == 8: h['phase'] = 'closed'
                    out = [h['scope'],h['inc'],'1',str(h['a']),str(h['c']),h['phase'],'none',str(h['g']),'0',
                        h['terminal'],'1' if h['terminal'] else '', '0' if h['terminal'] else '',
                        str(h['ticket']),str(h['command']),str(h['revision']),'accepted' if h['ticket'] else 'none']
            tick += 10
            return 1, wire.pack(lua.table_from(out)), 10, tick, tick+1, 1000

        lua.globals().native_callback = native
        lua.execute(r"""
            local original=dofile
            dofile=function(path)return original(path:gsub('/experiments/native%-settings%-chain%-live/experiments/','/experiments/'))end
            lines={};scheduled={};marker='PWP_SETTINGS_CHAIN '..MODE..' '..NONCE..'\n'
            io.open=function(path,mode)
                assert(path:match('/run.txt$') or path:match('/settings%-chain%-trial.jsonl$'))
                local read=false
                return {read=function()if read then return nil end;read=true;return marker end,
                    write=function(_,s)if path:match('/run.txt$')then marker=s else lines[#lines+1]=s end;return true end,
                    close=function()return true end}
            end
            package.loadlib=function(_,symbol)assert(symbol=='luaopen_pwp_draining_bridge');return function(...)return native_callback(...)end end
            RegisterEndPlayPreHook=function(fn)quit_hook=fn end
            ExecuteInGameThreadWithDelay=function(_,fn)scheduled[#scheduled+1]=fn end
        """)
        bootstrap = root/'experiments/native-settings-chain-live/main.lua'
        lua.execute(bootstrap.read_text(), name='@'+bootstrap.as_posix())
        lua.execute("local n=0;while #scheduled>0 do n=n+1;assert(n<100);table.remove(scheduled,1)()end")
        if not recovery: lua.execute('quit_hook(nil,{get=function()return 4 end})')
        log = lua.eval('table.concat(lines)')
        self.assertNotIn('bootstrap-failed',log)
        self.assertNotIn('"event":"failed"',log)
        return log

    def inspect_log(self, log, recovery=False):
        return acceptance.inspect(log,self.store,NONCE,self.prior,recovery_only=recovery,
                                  write_records=self.records if recovery else None)

    def test_actual_bootstrap_chain_all_schedules_and_existing_recovery(self):
        for before, tail in ((2,1),(3,1),(2,2),(3,2)):
            self.disk(before,tail)
            for recovery in (False,True):
                with self.subTest(before=before,tail=tail,recovery=recovery):
                    result=self.inspect_log(self.composition(recovery),recovery)
                    self.assertTrue(result['passed'])
                    self.assertEqual(result['records'],self.records)
                    self.assertEqual(result['prior_records'],self.prior)
                    self.assertEqual(result['recovery_no_writes'],recovery)

    def test_bad_identity_counts_pending_saved_and_completion(self):
        rows=[json.loads(x) for x in self.composition().splitlines()]
        cases=[]
        for event,key,value in [('saved','committed',2),('submitted','state','saved'),('saved','native_sequence',1),
                ('recovered','body','foreign'),('drained','cleaned',False),('passed','completed',['priorities'])]:
            bad=copy.deepcopy(rows);next(r['data'] for r in bad if r['data']['event']==event)[key]=value;cases.append(bad)
        for command,key,value in [(5,'thread',11),(5,'count',5),(5,'ticket',1),(5,'handle',128),
                                  (8,'status',0),(9,'status',0),(5,'payload_revision',5)]:
            bad=copy.deepcopy(rows);next(r['data'] for r in bad if r['data']['event']=='call' and r['data']['command']==command)[key]=value;cases.append(bad)
        for index,value in [(0,'foreign'),(1,'stale'),(3,'4'),(4,'2'),(7,'0'),(10,'0'),(12,'0')]:
            bad=copy.deepcopy(rows)
            raw=next(r['data'] for r in bad if r['data']['event']=='call' and r['data']['command']==8)
            raw['result_fields'][index]=value;cases.append(bad)
        for kind in ('saved','submitted','recovered','drained','stopped'):
            bad=copy.deepcopy(rows);bad.pop(next(i for i,r in enumerate(bad) if r['data']['event']==kind));cases.append(bad)
        cases += [rows[:-1],rows[:4],rows+[rows[-1]]]
        for i,bad in enumerate(cases):
            with self.subTest(case=i),self.assertRaises(ValueError):
                self.inspect_log('\n'.join(json.dumps(r) for r in bad))

    def test_recovery_refuses_init_write_or_changed_payload(self):
        rows=[json.loads(x) for x in self.composition(True).splitlines()]
        for command,field,value in [(4,'fields',['initialize_missing']),(4,'command',5),(3,'result_fields',None)]:
            bad=copy.deepcopy(rows);raw=next(r['data'] for r in bad if r['data']['event']=='call' and r['data']['command']==command)
            if value is None: raw['result_fields'][12]='corrupt'
            else: raw[field]=value
            with self.assertRaises(ValueError): self.inspect_log('\n'.join(json.dumps(r) for r in bad),True)

    def test_recovery_cli_uses_full_fifteen_baseline_and_split_inspection(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);write=root/'write';recover=root/'recover';write.mkdir();recover.mkdir()
            scripts=root/'Mods/PWPSettingsChainRecovery/Scripts';scripts.mkdir(parents=True)
            prod=root/'Mods/PalWorkPriority';prod.mkdir();(prod/'main.lua').write_text('unchanged')
            (scripts/'main.lua').write_text('installed');(scripts/'run.txt').write_text('DISABLED')
            (scripts/'settings-chain-trial.jsonl').write_text(self.composition(True))
            baseline={**self.prior,**self.records}
            manifest=dict(nonce=NONCE,recovery_only=True,prior_records=baseline,
                installed={'main.lua':acceptance.digest(scripts/'main.lua')},production_before={'main.lua':acceptance.digest(prod/'main.lua')})
            (write/'receipt.json').write_text(json.dumps(dict(passed=True,mode='write',prior_records=self.prior,records=self.records)))
            (recover/'install.json').write_text(json.dumps(manifest))
            with patch.multiple(acceptance,RUNTIME=root,WRITE_EVIDENCE=write,RECOVERY_EVIDENCE=recover,STORE=self.store),patch.object(sys,'argv',['accept','--recover']),redirect_stdout(io.StringIO()):
                acceptance.main()
                result=json.loads((recover/'receipt.json').read_text())
                self.assertEqual(result['prior_records'],self.prior)
                self.assertEqual(result['records'],self.records)
                (recover/'receipt.json').unlink()
                for bad in (dict(manifest,prior_records=self.prior),dict(manifest,recovery_only=False)):
                    (recover/'install.json').write_text(json.dumps(bad))
                    with self.assertRaises(ValueError): acceptance.main()
                    self.assertFalse((recover/'receipt.json').exists())


if __name__ == '__main__':
    unittest.main()
