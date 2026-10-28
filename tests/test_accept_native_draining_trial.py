"""Synthetic acceptance tests only; never call installer/verifier main or game APIs."""
import copy
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from accept_native_draining_trial import inspect

# Independent fixture constants, serializer and wire encoder. Do not import the
# verifier's payload(), W/G, require(), or any native implementation.
WORLD, GUILD, NONCE = '1' * 32, '2' * 32, 'drain-fixture-20261004'


def typed_payload(stream, revision):
    if stream == 'priorities':
        body = ('# Pal Work Priority: palkey|worktype|priority (1 highest, 5 lowest, X disabled)\n'
                '# baseline=vanilla\n'
                'trial-pal|1|1\ntrial-pal|2|2\ntrial-pal|3|3\ntrial-pal|4|4\n'
                'trial-pal|5|5\ntrial-pal|6|X\n' + f'trial-pal|7|{revision}\n')
    else:
        body = ('# Production limits. Mining limits stop only the rocks of their item; every other limit switches its whole work type.\n'
                '# guild|work|item|limit (OFF hides an inherited limit for this guild)\n'
                + f'{GUILD}|Mining|Ore|{100 * revision}\n{GUILD}|Mining|Stone|OFF\n')
    raw = body.encode('utf-8')
    return f'PWP-SETTINGS-1\n{WORLD}\n{GUILD}\n{stream}\n{len(raw)}\n'.encode() + raw


def envelope(stream, generation, revision):
    scope = f'PWP-SCOPE-1:{WORLD}:{GUILD}:{stream}'.encode()
    body = typed_payload(stream, revision)
    wire = b'PWPJNL1\n' + struct.pack('<HII', len(scope), generation, len(body)) + scope + body
    return wire + hashlib.sha256(wire).digest()


class Acceptance(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pwp-drain-accept-')
        self.addCleanup(self.temp.cleanup)
        self.store = Path(self.temp.name)
        self.fixture(2, 2)

    def fixture(self, priorities, limits):
        events = [{'event': 'armed', 'synthetic': True},
                  {'event': 'configured', 'game': 10, 'frequency': 10000000}]
        self.paths = {}
        tick = 100

        def call(command, handle, ticket=0, status=1):
            nonlocal tick
            events.append(dict(event='call', command=command, handle=handle, ticket=ticket,
                               status=status, thread=10, start=tick, finish=tick+1, frequency=10000000))
            tick += 2

        for stream, generation, first in [('priorities', priorities, 1), ('limits', limits, 3)]:
            slots = [('A', 1, 1), ('B', 2, 3)] if generation == 2 else [('A', 3, 3), ('B', 2, 2)]
            for slot, gen, rev in slots:
                name = f'pwp-record-v1-{WORLD}-{GUILD}-{stream}-{slot}.record'
                path = self.store / name
                path.write_bytes(envelope(stream, gen, rev))
                self.paths[(stream, slot)] = path
            for reopening, handle in [(False, first), (True, first+1)]:
                call(1, 1)
                events.append(dict(event='bound', stream=stream, handle=handle, reopening=reopening))
                call(2, handle, 1)
                call(3, handle, status=2)  # permitted pending poll
                call(3, handle)
                if not reopening:
                    call(4, handle, 2)
                    for ticket in (3, 4, 5):
                        call(5, handle, ticket)
                    call(8, handle, 6)
                    events.append(dict(event='drained', stream=stream, accepted=3, committed=3,
                                       generation=generation, cleanup_error='0'))
                else:
                    for slot, gen, rev in slots:
                        events.append(dict(event='slot', stream=stream, slot=slot, generation=gen,
                                           payload=typed_payload(stream, rev).decode()))
                    call(8, handle, 2)
                call(9, handle)
                events.append(dict(event='released', stream=stream, handle=handle))
        events.extend([dict(event='passed', synthetic=True, explicit_drain=True,
                            completed=['priorities', 'limits'], shutdown_route_verified=False),
                       dict(event='stopped', state='passed')])
        self.events = events

    def log(self, events=None):
        return '\n'.join(json.dumps(dict(nonce=NONCE, data=e))
                         for e in (self.events if events is None else events))

    def reject(self, events):
        with self.assertRaises((ValueError, KeyError, TypeError, IndexError)):
            inspect(self.log(events), self.store, NONCE)

    def test_positive_all_physical_layouts_and_honest_limits(self):
        for p, l in ((2, 2), (3, 3), (2, 3), (3, 2)):
            with self.subTest(priorities=p, limits=l):
                self.fixture(p, l)
                result = inspect(self.log(), self.store, NONCE)
                self.assertTrue(result['passed'] and result['synthetic'] and result['explicit_drain'])
                self.assertFalse(result['shutdown_route_verified'])
                self.assertFalse(result['worker_thread_independently_observed'])
                self.assertEqual(result['records'], {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                                    for p in self.paths.values()})

    def test_missing_drain_step_cleanup_or_release(self):
        for index, event in enumerate(self.events):
            if event['event'] in ('drained', 'released', 'slot', 'bound', 'configured', 'passed', 'stopped') or (
                    event['event'] == 'call' and event['command'] != 3):
                with self.subTest(index=index, event=event):
                    self.reject(self.events[:index] + self.events[index+1:])

    def test_bad_saved_revision_generation_and_cleanup(self):
        for index, event in enumerate(self.events):
            if event['event'] != 'drained':
                continue
            for field, value in [('accepted', 2), ('committed', 2), ('committed', 4),
                                 ('generation', 1), ('generation', 4), ('cleanup_error', '29')]:
                with self.subTest(index=index, field=field, value=value):
                    bad = copy.deepcopy(self.events)
                    bad[index][field] = value
                    self.reject(bad)

    def test_every_record_wrong_byte_digest_and_rehashed_content(self):
        for key, path in self.paths.items():
            original = path.read_bytes()
            changes = [original[:-1], original+b'x', original[:-1]+bytes([original[-1]^1])]
            for offset in (0, 8, 10, 14, 18, len(original)-33):
                body = bytearray(original[:-32]);body[offset] ^= 1
                changes.append(bytes(body)+hashlib.sha256(body).digest())
            try:
                for index, raw in enumerate(changes):
                    with self.subTest(slot=key, mutation=index):
                        path.write_bytes(raw)
                        self.reject(self.events)
            finally:
                path.write_bytes(original)

    def test_missing_record_and_unknown_artifact(self):
        path = self.paths[('limits', 'B')]
        raw = path.read_bytes();path.unlink()
        self.reject(self.events);path.write_bytes(raw)
        (self.store/'unknown-backup').write_bytes(b'keep')
        self.reject(self.events)

    def test_wrong_control_thread_clock_or_refusal_each_call(self):
        for index, event in enumerate(self.events):
            if event['event'] != 'call':
                continue
            for field, value in [('thread', 11), ('thread', 0), ('frequency', 1), ('finish', -1), ('status', 0)]:
                with self.subTest(index=index, field=field):
                    bad = copy.deepcopy(self.events);bad[index][field] = value
                    self.reject(bad)

    def test_nonce_failure_and_explicit_failure_event(self):
        for text in (self.log().replace(NONCE, 'different', 1), self.log().replace(NONCE, 'different'), ''):
            with self.subTest(text=text[:100]):
                with self.assertRaises((ValueError, KeyError, IndexError)):
                    inspect(text, self.store, NONCE)
        for event in ('failed', 'bootstrap-failed'):
            self.reject(self.events[:-1]+[dict(event=event)]+self.events[-1:])

    def test_extra_or_changed_mutating_commands(self):
        for index, event in enumerate(self.events):
            if event['event'] != 'call' or event['command'] not in (2, 4, 5, 8, 9):
                continue
            with self.subTest(index=index, mutation='duplicate'):
                self.reject(self.events[:index]+[event]+self.events[index:])
            bad = copy.deepcopy(self.events);bad[index]['command'] = 7
            with self.subTest(index=index, mutation='unexpected-command'):
                self.reject(bad)

    def test_mutating_calls_must_match_owner_ticket_and_success(self):
        # A valid disk snapshot cannot authenticate an unrelated/replayed command.
        for field, value in [('handle', 99), ('ticket', 0), ('ticket', 123), ('status', 2)]:
            bad = copy.deepcopy(self.events)
            next(e for e in bad if e['event'] == 'call' and e['command'] == 5)[field] = value
            with self.subTest(field=field, value=value):
                self.reject(bad)


if __name__ == '__main__':
    unittest.main()
