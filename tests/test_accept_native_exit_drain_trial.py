"""Independent synthetic verifier fixtures; no installer or game entry points."""
import copy
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import accept_native_exit_drain_trial as acceptance

WORLD, GUILD, NONCE = '3' * 32, '4' * 32, 'exitdrain-fixture-20261004'
STREAMS = ('priorities', 'limits')


def typed_payload(stream, revision, world=WORLD, guild=GUILD):
    if stream == 'priorities':
        body = ('# Pal Work Priority: palkey|worktype|priority (1 highest, 5 lowest, X disabled)\n'
                '# baseline=vanilla\n'
                'trial-pal|1|1\ntrial-pal|2|2\ntrial-pal|3|3\ntrial-pal|4|4\n'
                'trial-pal|5|5\ntrial-pal|6|X\n' + f'trial-pal|7|{revision}\n')
    else:
        body = ('# Legacy work-type groups: may stop unrelated products of the same suitability.\n'
                '# guild|work|item|ceiling (OFF masks an inherited group rule for this guild)\n'
                + f'{guild}|Mining|Ore|{100 * revision}\n{guild}|Mining|Stone|OFF\n')
    raw = body.encode('utf-8')
    return f'PWP-SETTINGS-1\n{world}\n{guild}\n{stream}\n{len(raw)}\n'.encode() + raw


def envelope(stream, generation, revision, world=WORLD, guild=GUILD):
    scope = f'PWP-SCOPE-1:{world}:{guild}:{stream}'.encode()
    body = typed_payload(stream, revision, world, guild)
    wire = b'PWPJNL1\n' + struct.pack('<HII', len(scope), generation, len(body)) + scope + body
    return wire + hashlib.sha256(wire).digest()


class Acceptance(unittest.TestCase):
    fixture_version, world, guild = 1, WORLD, GUILD

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pwp-exit-drain-accept-')
        self.addCleanup(self.temp.cleanup)
        self.store = Path(self.temp.name)
        self.prior = {}
        for stream in STREAMS:
            for slot, generation, revision in [('A', 1, 1), ('B', 2, 3)]:
                name = f'pwp-record-v1-{"1"*32}-{"2"*32}-{stream}-{slot}.record'
                raw = envelope(stream, generation, revision, '1'*32, '2'*32)
                (self.store / name).write_bytes(raw)
                self.prior[name] = hashlib.sha256(raw).hexdigest()
        if self.fixture_version == 2:
            for stream, slot, generation, revision in [('priorities', 'A', 3, 3), ('priorities', 'B', 2, 2), ('limits', 'A', 1, 1)]:
                name = f'pwp-record-v1-{WORLD}-{GUILD}-{stream}-{slot}.record'
                raw = envelope(stream, generation, revision)
                (self.store/name).write_bytes(raw)
                self.prior[name] = hashlib.sha256(raw).hexdigest()
        self.paths = {}
        self.disk(2, 2)
        self.fixture()

    def fixture(self, committed=1, empty_object=True):
        self.events = [dict(event='armed', synthetic=True, exit_hook_installed=True),
                       dict(event='configured', game=10, frequency=10000000)]
        events = self.events
        owners = {s: dict(stream=s, scope=f'PWP-SCOPE-1:{self.world}:{self.guild}:{s}',
                         incarnation=NONCE+'-exit-'+s, handle=i+1) for i, s in enumerate(STREAMS)}
        tick = 100

        def event(kind, s, **kw):
            e = dict(event=kind, **owners[s]);e.update(kw);events.append(e)

        def call(cmd, s, ticket=0, fields=None, status=1, handle=None):
            nonlocal tick
            event('call', s, command=cmd, ticket=ticket, status=status, fields=fields if fields is not None else ({} if empty_object else []),
                  thread=10, start=tick, finish=tick+1, frequency=10000000)
            if handle is not None:
                events[-1]['handle'] = handle
            tick += 2

        def status(s, c, generation, terminal, ticket=3, cmd=5, revision=1, phase='ready', accepted=1):
            b = owners[s]
            return [b['scope'], b['incarnation'], '1', str(accepted), str(c), phase, 'none',
                    str(generation), '0', terminal, '1', '0', str(ticket), str(cmd), str(revision), 'accepted']

        for s in STREAMS:
            b = owners[s]
            call(1, s, fields=[str(b['handle'])], handle=1)
            event('bound', s, synthetic=True)
            call(2, s, 1)
            call(3, s, status=2)
            call(3, s, fields=[b['scope'], b['incarnation'], '1', 'recovered', '1', '0', '0',
                              'exact-preimage', '0', '0', 'missing', '0', '', 'missing', '0', ''])
            call(4, s, 2)
            call(5, s, 3, ['1'])
            call(6, s, fields=status(s, 0, 0, 'recovered'))
            call(6, s, fields=status(s, 1, 1, 'initialized'))
            event('initialized', s, accepted=1, committed=1, generation=1, cleanup_error='0')
        events.append(dict(event='ready', synthetic=True, storage=self.world, guild=self.guild, owners_retained=2))
        for s in STREAMS:
            call(6, s, fields=status(s, 1, 1, 'initialized'))
        events.append(dict(event='quit-observed', reason=4, game_thread=10, synthetic=True, scope_verified=False))
        for s in STREAMS:
            call(5, s, 4, ['2']);call(5, s, 5, ['3'])
            gen = 1 if committed == 1 else 2 if committed == 2 else self.generations[s]
            call(6, s, fields=status(s, committed, gen, 'initialized' if committed == 1 else 'updated',
                                   ticket=5, revision=3, accepted=3))
            event('pending-observation', s, accepted=3, committed=committed, generation=gen, pending_observed=committed<3)
        for s in STREAMS:
            call(8, s, 6, status(s, 3, self.generations[s], 'updated', ticket=6, cmd=8, revision=0, phase='closed', accepted=3))
            event('drained', s, accepted=3, committed=3, generation=self.generations[s], cleanup_error='0')
        for s in STREAMS:
            call(9, s);event('released', s)
        events.extend([dict(event='passed', synthetic=True, explicit_drain=True, quit_reason=4, storage=self.world, guild=self.guild,
                            completed=list(STREAMS), shutdown_route_verified=False, worker_thread_independently_observed=False),
                       dict(event='stopped', state='passed', phase='complete')])

    def log(self, events=None):
        return '\n'.join(json.dumps(dict(nonce=NONCE, data=e)) for e in (self.events if events is None else events))

    def inspect(self, events=None):
        return acceptance.inspect(self.log(events), self.store, NONCE, self.prior, fixture_version=self.fixture_version)

    def reject(self, events):
        with self.assertRaises((ValueError, KeyError, TypeError, IndexError)):
            self.inspect(events)

    def test_complete_run_all_schedules_pending_and_empty_replies(self):
        for p, l in ((2, 2), (3, 3), (2, 3), (3, 2)):
            self.disk(p, l)
            for committed in (1, 2, 3):
                for empty_object in (True, False):
                    self.fixture(committed, empty_object)
                    result = self.inspect()
                    self.assertTrue(result['passed'] and result['prior_records_unchanged'] and result['quit_callback_completed'])
                    self.assertFalse(result['shutdown_route_verified'] or result['process_exit_independently_verified'])
                    self.assertEqual(result['pending_observed'], {s: committed<3 for s in STREAMS})

    def test_every_required_event_removed_duplicated_or_swapped(self):
        for i, e in enumerate(self.events):
            # Repeated recovery-pending and initialization-pending observations are optional.
            optional = e['event'] == 'call' and (e['status'] == 2 or e['command'] == 6 and e['fields'][4] == '0')
            if not optional:
                with self.subTest(i=i, action='remove'):
                    self.reject(self.events[:i]+self.events[i+1:])
                with self.subTest(i=i, action='duplicate'):
                    self.reject(self.events[:i]+[e]+self.events[i:])
            if i+1 < len(self.events):
                bad = copy.deepcopy(self.events);bad[i], bad[i+1] = bad[i+1], bad[i]
                with self.subTest(i=i, action='swap'):
                    self.reject(bad)

    def test_no_prefix_or_only_success_can_pass(self):
        for i in range(len(self.events)):
            self.reject(self.events[:i])
        self.reject([self.events[0], self.events[1], self.events[-2], self.events[-1]])
        self.reject(self.events+[dict(event='failed')])
        self.reject(self.events[:-1]+[dict(event='bootstrap-failed')]+self.events[-1:])

    def test_all_call_routes_tickets_and_identity(self):
        for i, e in enumerate(self.events):
            if e['event'] != 'call':
                continue
            for field, value in [('thread', 11), ('thread', True), ('frequency', 1), ('start', -1), ('finish', 0),
                                 ('status', 0), ('status', True), ('handle', 99), ('ticket', 123),
                                 ('scope', 'foreign'), ('incarnation', 'old'), ('stream', 'other'), ('fields', None)]:
                bad = copy.deepcopy(self.events);bad[i][field] = value
                with self.subTest(i=i, field=field):
                    self.reject(bad)

    def test_every_status_field_cannot_be_forged(self):
        changes = {0:'foreign', 1:'old', 2:'2', 3:'4', 4:'4', 5:'blocked', 6:'uncertain', 7:'4', 8:'29',
                   9:'failed', 10:'0', 11:'29', 12:'99', 13:'7', 14:'99', 15:'unknown'}
        for i, e in enumerate(self.events):
            if e['event'] != 'call' or e['command'] not in (6, 8):
                continue
            for field, value in changes.items():
                bad = copy.deepcopy(self.events);bad[i]['fields'][field] = value
                with self.subTest(i=i, field=field):
                    self.reject(bad)

    def test_nonmissing_recovery_and_bad_admission(self):
        for i, e in enumerate(self.events):
            if e['event'] != 'call' or e['status'] != 1:
                continue
            changes = []
            if e['command'] == 3:
                changes = [(k, 'foreign' if k in (0,10,13) else 'unexpected') for k in range(16)]
            if e['command'] in (1,5):
                changes = [(0, '0'), (0, '01'), (0, '99')]
            for field, value in changes:
                bad = copy.deepcopy(self.events);bad[i]['fields'][field] = value
                # The preimage is opaque, only nonempty is checked.
                if e['command'] == 3 and field == 7:
                    bad[i]['fields'][field] = ''
                with self.subTest(i=i, field=field):
                    self.reject(bad)

    def test_ready_quit_drain_completion_claims(self):
        changes = {'ready': [('owners_retained', 1), ('storage', '1'*32)],
                   'quit-observed': [('reason', 1), ('reason', True), ('game_thread', 11), ('scope_verified', True)],
                   'pending-observation': [('pending_observed', False), ('committed', 3)],
                   'drained': [('committed', 2), ('generation', 1), ('cleanup_error', '29')],
                   'passed': [('completed', ['priorities']), ('shutdown_route_verified', True), ('quit_reason', 1)],
                   'stopped': [('state', 'ready')]}
        for i, e in enumerate(self.events):
            for field, value in changes.get(e['event'], []):
                bad = copy.deepcopy(self.events);bad[i][field] = value
                with self.subTest(i=i, field=field):
                    self.reject(bad)

    def test_terminal_before_consumption_is_not_an_ack(self):
        for e in self.events:
            if e['event'] == 'call' and e['command'] == 6:
                if e['fields'][4] == '0':
                    e['fields'][9] = 'initialized'
                elif e['fields'][3] == '3' and e['fields'][4] == '1':
                    e['fields'][9] = 'updated'
        self.assertTrue(self.inspect()['passed'])
        self.fixture(committed=3)
        for i, e in enumerate(self.events):
            if e['event'] == 'call' and e['command'] == 6 and e['fields'][3] == '3':
                bad = copy.deepcopy(self.events);bad[i]['fields'][9] = 'initialized'
                self.reject(bad)

    def test_json_nonce_and_duplicate_keys(self):
        for text in ('', self.log().replace(NONCE, 'foreign', 1), self.log().replace('"nonce":', '"nonce":"bad","nonce":', 1)):
            with self.assertRaises((ValueError, KeyError, IndexError)):
                acceptance.inspect(text, self.store, NONCE, self.prior, fixture_version=self.fixture_version)

    def test_explicit_version_and_exact_prior_name_allowlist(self):
        result = self.inspect()
        self.assertEqual(result['fixture_version'], self.fixture_version)
        self.assertEqual(len(result['prior_records']), 4 if self.fixture_version == 1 else 7)
        for version in (3-self.fixture_version, True, str(self.fixture_version)):
            events = copy.deepcopy(self.events);events[0]['fixture_version'] = version
            self.reject(events)
        for version in (0, 3, True, '2', None, 3-self.fixture_version):
            with self.subTest(version=version):
                with self.assertRaises(ValueError):
                    acceptance.inspect(self.log(), self.store, NONCE, self.prior, fixture_version=version)
        # A valid digest never makes an arbitrary prior path admissible.
        original = next(iter(self.prior))
        for name in ('../outside.record', str(self.store/original),
                     f'pwp-record-v1-{WORLD}-{GUILD}-limits-B.record',
                     f'pwp-record-v1-{self.world}-{self.guild}-priorities-A.record'):
            prior = dict(self.prior);prior[name] = prior.pop(original)
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    acceptance.inspect(self.log(), self.store, NONCE, prior, fixture_version=self.fixture_version)

    def test_actual_bootstrap_and_runner_event_schema(self):
        # Actual bootstrap, runner, codec and serializers; only native fixed ABI,
        # callback scheduling and bootstrap file handles are mocked. This is a
        # schema/composition test, not evidence that a native worker or game ran.
        root = Path(__file__).resolve().parents[1]
        sys.path.insert(0, str(root/'.test-deps'))
        from lupa.lua54 import LuaRuntime

        def pack(fields):
            return b''.join(struct.pack('<I', len(x.encode()))+x.encode() for x in fields)

        def unpack(raw):
            result = []
            while raw:
                n, = struct.unpack('<I', raw[:4]);raw = raw[4:]
                self.assertGreaterEqual(len(raw), n)
                result.append(raw[:n]);raw = raw[n:]
            return result

        for generation, committed in ((2, 1), (3, 3)):
            self.disk(generation, generation);self.fixture(committed)
            expected_calls = iter(e for e in self.events if e['event'] == 'call')
            submitted = {s: 0 for s in STREAMS}

            def native(command, handle, ticket, hex_input, length):
                self.assertEqual(len(hex_input), length)
                args = unpack(bytes.fromhex(hex_input))
                if command == 0:
                    self.assertEqual((handle, ticket, args), (0, 0, []))
                    return 1, pack(['1']).decode(), 10, 0, 1, 10000000
                e = next(expected_calls)
                self.assertEqual((command, handle, ticket), (e['command'], e['handle'], e['ticket']))
                stream = e['stream']
                if command == 1:
                    self.assertEqual(args, [self.world.encode(), self.guild.encode(), stream.encode(), e['incarnation'].encode(), b'1'])
                elif command == 4:
                    self.assertEqual(args, [b'initialize_missing'])
                elif command == 5:
                    submitted[stream] += 1
                    self.assertEqual(args, [typed_payload(stream, submitted[stream], self.world, self.guild)])
                else:
                    self.assertEqual(args, [])
                return e['status'], pack(e['fields']).decode(), e['thread'], e['start'], e['finish'], e['frequency']

            lua = LuaRuntime(unpack_returned_tuples=True)
            lua.globals().TEST_ROOT = root.as_posix()
            lua.globals().NONCE = NONCE
            lua.globals().native_callback = native
            lua.execute('''
                package.path=TEST_ROOT..'/Scripts/?.lua;'..package.path
                local original_dofile=dofile
                dofile=function(path)
                    path=path:gsub('/experiments/native%-exit%-drain%-live/experiments/', '/experiments/')
                    return original_dofile(path)
                end
                lines={};scheduled={};marker='PWP_EXIT_DRAIN_TRIAL '..NONCE..'\\n'
                io.open=function(path, mode)
                    assert(path:match('/run.txt$') or path:match('/exit%-drain%-trial.jsonl$'))
                    local read=false
                    return {read=function(_,n)if read then return nil end;read=true;return marker end,
                        write=function(_,s)
                            if path:match('/run.txt$') then marker=s else lines[#lines+1]=s end
                            return true
                        end,close=function()return true end}
                end
                package.loadlib=function(_,symbol)
                    assert(symbol=='luaopen_pwp_draining_bridge')
                    return function(...)return native_callback(...)end
                end
                RegisterEndPlayPreHook=function(fn)quit_hook=fn end
                ExecuteInGameThreadWithDelay=function(_,fn)scheduled[#scheduled+1]=fn end
            ''')
            bootstrap = root/'experiments/native-exit-drain-live/main.lua'
            source = bootstrap.read_text()
            # Exercise the same bootstrap with each explicitly supported fixture.
            # The installed v2 source itself is unchanged for the v2 test.
            source = source.replace('fixture_version=2', 'fixture_version='+str(self.fixture_version))
            lua.execute(source, name='@'+bootstrap.as_posix())
            lua.execute('''
                local n=0
                while #scheduled>0 do n=n+1;assert(n<100);table.remove(scheduled,1)() end
                assert(marker=='DISABLED\\n')
                quit_hook(nil,{get=function()return 4 end})
            ''')
            emitted = lua.eval("table.concat(lines)")
            self.assertNotIn('bootstrap-failed', emitted, emitted)
            result = acceptance.inspect(emitted, self.store, NONCE, self.prior, fixture_version=self.fixture_version)
            self.assertTrue(result['passed'])
            self.assertIsNone(next(expected_calls, None))
            self.assertEqual(submitted, {s: 3 for s in STREAMS})

    def disk(self, pgen, lgen):
        self.generations = dict(priorities=pgen, limits=lgen)
        for stream, generation in self.generations.items():
            slots = [('A', 1, 1), ('B', 2, 3)] if generation == 2 else [('A', 3, 3), ('B', 2, 2)]
            for slot, gen, rev in slots:
                path = self.store / f'pwp-record-v1-{self.world}-{self.guild}-{stream}-{slot}.record'
                path.write_bytes(envelope(stream, gen, rev, self.world, self.guild))
                self.paths[(stream, slot)] = path

    def test_all_physical_layouts(self):
        for p, l in ((2, 2), (3, 3), (2, 3), (3, 2)):
            self.disk(p, l)
            hashes = acceptance.inspect_records(self.store, self.generations, self.prior, fixture_version=self.fixture_version)
            self.assertEqual(hashes, {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in self.paths.values()})

    def test_exact_records_including_rehashed_corruption(self):
        for path in self.paths.values():
            original = path.read_bytes()
            changes = [original[:-1], original+b'x', original[:-1]+bytes([original[-1]^1])]
            for offset in (0, 8, 10, 14, 18, len(original)-33):
                body = bytearray(original[:-32]);body[offset] ^= 1
                changes.append(bytes(body)+hashlib.sha256(body).digest())
            try:
                for raw in changes:
                    with self.subTest(path=path.name, raw=raw[:18]):
                        path.write_bytes(raw)
                        with self.assertRaises(ValueError):
                            acceptance.inspect_records(self.store, self.generations, self.prior, fixture_version=self.fixture_version)
            finally:
                path.write_bytes(original)

    def test_prior_manifest_missing_foreign_or_changed(self):
        variants = [{}, dict(self.prior), dict(self.prior), dict(self.prior)]
        variants[1].pop(next(iter(self.prior)))
        variants[2]['../elsewhere'] = variants[2].pop(next(iter(self.prior)))
        variants[3][next(iter(self.prior))] = 'g'*64
        for manifest in variants:
            with self.assertRaises(ValueError):
                acceptance.inspect_records(self.store, self.generations, manifest, fixture_version=self.fixture_version)
        for name in self.prior:
            path = self.store/name;raw = path.read_bytes()
            try:
                path.write_bytes(raw+b'x')
                with self.assertRaises(ValueError):
                    acceptance.inspect_records(self.store, self.generations, self.prior, fixture_version=self.fixture_version)
            finally:
                path.write_bytes(raw)

    def test_missing_new_or_prior_and_unexpected_artifacts(self):
        for path in list(self.paths.values()) + [self.store/n for n in self.prior]:
            raw = path.read_bytes();path.unlink()
            try:
                with self.assertRaises(ValueError):
                    acceptance.inspect_records(self.store, self.generations, self.prior, fixture_version=self.fixture_version)
            finally:
                path.write_bytes(raw)
        (self.store/'unexpected-backup').write_bytes(b'keep')
        with self.assertRaises(ValueError):
            acceptance.inspect_records(self.store, self.generations, self.prior, fixture_version=self.fixture_version)


class AcceptanceV2(Acceptance):
    fixture_version, world, guild = 2, '5'*32, '6'*32


if __name__ == '__main__':
    unittest.main()
