import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('analyzer', ROOT/'tools/analyze_export_membership.py')
M = importlib.util.module_from_spec(spec); spec.loader.exec_module(M)
A, B = 'A'*64, 'B'*64
EXPECTED = dict(nonce='1'*32, manifest_sha256='a'*64, storage='2'*32, guild='a'*32,
                alias='-1431655766--1431655766--1431655766--1431655766', keys=[A, B])


def records(keys=None, unresolved=False):
    keys = EXPECTED['keys'] if keys is None else keys
    common = {k: EXPECTED[k] for k in ('nonce', 'manifest_sha256', 'storage', 'guild', 'alias')}
    common.update({k: 'false' for k in M.GRANTS})
    def row(event, sample, **changes):
        r = dict(common, event=event, sample=str(sample), world_hex='world'.encode().hex(),
                 key='none', status='none', complete='false', confirmed='0', unresolved='0',
                 not_examined='0', reason='none')
        r.update({k: str(i+1) for i, k in enumerate(M.ADDRESSES)})
        r.update(changes)
        return r
    armed = row('armed', 0, world_hex='none'); armed.update({k: '0' for k in M.ADDRESSES})
    result = [armed]
    for sample in range(1, 4):
        misses = int(unresolved and sample == 2 and bool(keys))
        for i, key in enumerate(keys):
            result.append(row('key', sample, key=key,
                              status='unresolved' if misses and i == 0 else 'current_target_confirmed'))
        result.append(row('sample', sample, complete='true', confirmed=str(len(keys)-misses),
                          unresolved=str(misses)))
    result.append(row('done', 3, complete='true', confirmed=str(len(keys))))
    return result


def render(rows):
    return ''.join('PWP_EXPORT_MEMBERSHIP\t'+'\t'.join(k+'='+v for k,v in row.items())+'\n'
                   for row in rows)


class Analyze(unittest.TestCase):
    def accept(self, rows, **overrides):
        return M.analyze(render(rows), **dict(EXPECTED, **overrides))

    def test_complete_confirmed_and_completed_unresolved_are_distinct(self):
        for unresolved in (False, True):
            rows = records(unresolved=unresolved); r = self.accept(rows)
            self.assertTrue(r['observation_completed'])
            self.assertEqual(r['all_current_confirmed'], not unresolved)
            self.assertEqual(r['unresolved_in_any_sample'], [A] if unresolved else [])
            self.assertEqual(r['source_log_sha256'], hashlib.sha256(render(rows).encode()).hexdigest())
            for key, value in r.items():
                if key.endswith(('_allowed', '_verified', '_grant')): self.assertIs(value, False)
            self.assertFalse(r['retained_history_complete'])

    def test_empty_and_exact_capacity_without_truncation(self):
        r = self.accept(records([]), keys=[])
        self.assertTrue(r['observation_completed']); self.assertFalse(r['all_current_confirmed'])
        keys = [f'{i:064X}' for i in range(1,257)]
        self.assertTrue(self.accept(records(keys), keys=keys)['all_current_confirmed'])
        keys.append(f'{257:064X}')
        with self.assertRaises(ValueError): self.accept(records(keys), keys=keys)

    def test_expected_identity_and_keys_are_strict(self):
        for field, values in {'nonce': ['0'*32, 'A'*32, 'a'*31], 'manifest_sha256': ['x'*64],
                              'storage': ['0'*32], 'guild': ['x'*32],
                              'alias': ['', 'bad\talias', '1-2-3-4', '01-2-3-4'],
                              'keys': [[B,A], [A,A], ['a'*64], ['A'*32+'0'*32], None]}.items():
            for value in values:
                with self.subTest(field=field), self.assertRaises(ValueError):
                    self.accept(records(), **{field: value})

    def test_missing_extra_duplicate_unknown_fields(self):
        for key in M.FIELDS:
            rows = records(); del rows[2][key]
            with self.subTest(missing=key), self.assertRaises(ValueError): self.accept(rows)
        raw = render(records())
        for bad in (raw.replace('event=key', 'event=unknown', 1),
                    raw.replace('event=key', 'event=key\textra=false', 1),
                    raw.replace('event=key', 'event=key\tevent=key', 1)):
            with self.assertRaises(ValueError): M.analyze(bad, **EXPECTED)

    def test_log_framing_truncation_and_extra_events(self):
        text = render(records())
        for bad in (text[:-1], text+'\n', text+text, text[:-20], '[Lua] '+text,
                    text.replace('\tkey=', '\x00key=', 1), text.replace('reason=none', 'reason=none[next]', 1),
                    text.replace('event=key', 'event=kéy', 1), '', None):
            with self.assertRaises(ValueError): M.analyze(bad, **EXPECTED)
        self.assertTrue(M.analyze(text.replace('\n','\r\n'), **EXPECTED)['observation_completed'])

    def test_wrong_order_duplicate_unknown_and_missing_keys(self):
        for mutation in ('duplicate', 'unknown', 'order', 'sample', 'missing'):
            rows = records()
            if mutation=='duplicate': rows[2]['key']=A
            elif mutation=='unknown': rows[2]['key']='C'*64
            elif mutation=='order': rows[1],rows[2]=rows[2],rows[1]
            elif mutation=='sample': rows[2]['sample']='2'
            else: del rows[2]
            with self.subTest(mutation=mutation), self.assertRaises(ValueError): self.accept(rows)

    def test_late_context_change_and_failure_revoke_whole_result(self):
        changes = {k: '99' for k in M.ADDRESSES}
        changes.update(world_hex=b'other'.hex(), nonce='4'*32, manifest_sha256='b'*64,
                       storage='5'*32, guild='6'*32, alias='different', event='failed', reason='context_changed')
        for field, value in changes.items():
            rows=records();rows[-1][field]=value
            with self.subTest(field=field), self.assertRaises(ValueError): self.accept(rows)
        rows=records();rows.append(dict(rows[-1],event='failed',reason='context_changed'))
        with self.assertRaises(ValueError): self.accept(rows)

    def test_all_false_flags_strict_booleans(self):
        for field in M.GRANTS:
            for value in ('true','0','False',''):
                rows=records();rows[-1][field]=value
                with self.subTest(field=field,value=value), self.assertRaises(ValueError): self.accept(rows)

    def test_counts_complete_status_and_native_scalar_bounds(self):
        for index, field, values in ((3,'confirmed',['1','03','-1','257','2.0']),
                                     (3,'complete',['false','1']), (1,'status',['unknown','not_examined','true']),
                                     (1,'confirmed',['1']), (0,'world_address',['1']),
                                     (1,'world_address',['0','01','1.0','9223372036854775808']),
                                     (1,'world_hex',['none','FF','0','gg','00','ff','61'*513])):
            for value in values:
                rows=records();rows[index][field]=value
                with self.subTest(field=field,value=value[:30]), self.assertRaises(ValueError): self.accept(rows)

    def test_cli_json_only_success_failure_and_no_input_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp);log=p/'events.log';expected=p/'expected.json'
            log.write_bytes(render(records()).encode())
            expected.write_text(json.dumps(dict(manifest_sha256=EXPECTED['manifest_sha256'],
                                storage=EXPECTED['storage'],guild=EXPECTED['guild'],lookup_union=[A,B])))
            before=(log.read_bytes(),expected.read_bytes())
            cmd=[sys.executable,'-B',str(ROOT/'tools/analyze_export_membership.py'),str(log),
                 '--expected',str(expected),'--nonce',EXPECTED['nonce'],'--alias='+EXPECTED['alias']]
            result=subprocess.run(cmd,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertTrue(json.loads(result.stdout)['observation_completed'])
            self.assertEqual(before,(log.read_bytes(),expected.read_bytes()))
            log.write_bytes(log.read_bytes()[:-1])
            result=subprocess.run(cmd,capture_output=True,text=True)
            self.assertEqual(result.returncode,1)
            self.assertFalse(json.loads(result.stdout)['observation_completed'])

    def test_actual_lua_runner_output_and_late_revocation(self):
        sys.path.insert(0, str(ROOT/'.test-deps'))
        from lupa.lua54 import LuaRuntime
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().TEST_ROOT = ROOT.as_posix()
        lua.execute('package.path=TEST_ROOT.."/Scripts/?.lua;"..package.path')
        factory = lua.execute((ROOT/'tests/test_export_membership_live.lua').read_text(encoding='utf-8-sig'))
        expected = dict(nonce='a'*32, manifest_sha256='b'*64, storage='1'*32,
                        guild='00000001'*4, alias='1-1-1-1', keys=[A,B])
        for mode in ('confirmed', 'unresolved', 'late_change'):
            edit = None
            if mode == 'unresolved':
                edit = lua.eval('function(f) f.on_lookup=function(k)return k==string.rep("B",64)end end')
            elif mode == 'late_change':
                edit = lua.eval('''function(f) f.on_log=function(line)
                    if line:find('event=sample\\t',1,true) and line:find('\\tsample=3\\t',1,true)
                    then f.pair.manager_address=99 end end end''')
            fixture = factory(edit)
            for _ in range(3): fixture.step()
            text = lua.eval('table.concat')(fixture.logs)
            if mode == 'late_change':
                with self.assertRaises(ValueError): M.analyze(text, **expected)
            else:
                r = M.analyze(text, **expected)
                self.assertTrue(r['observation_completed'])
                self.assertEqual(r['all_current_confirmed'], mode == 'confirmed')


if __name__=='__main__': unittest.main()
