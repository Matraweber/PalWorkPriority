import hashlib
import json
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from accept_native_journal_probe import inspect

SCOPE = ('PWP-SCOPE-1:' + 32*'7' + ':' + 32*'8' + ':priorities').encode()
STEM = 'pwp-record-v1-' + 32*'7' + '-' + 32*'8' + '-priorities-'
SCRIPT = Path(__file__).resolve().parents[1] / 'tools/accept_native_journal_probe.py'


def envelope(generation):
    # Independent encoder, no native codec or verifier constants imported.
    payload = bytes((i + generation) % 256 for i in range(262144))
    raw = b'PWPJNL1\n' + struct.pack('<HII', len(SCOPE), generation, len(payload)) + SCOPE + payload
    return raw + hashlib.sha256(raw).digest()


class Acceptance(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.paths = {s: self.root / (STEM + s + '.record') for s in ('A', 'B')}
        for slot, generation in [('A', 3), ('B', 2)]:
            self.paths[slot].write_bytes(envelope(generation))
        self.events = ['ARMED synthetic only; delay=90000; phases=3; NOT production settings']
        for phase in (1, 2, 3):
            self.events.extend([f'START phase={phase} game=1',
                                f'RESULT phase={phase} values=1,{phase+1},{phase*100},{phase*100+10},10000000 completion=1'])
        self.events.append('COMPLETE native phases=3 owner_released=true independent_readback_required=true durable_ack=false')

    def log(self, events=None):
        return '\n'.join('2026-10-04T15:00:00Z fixture ' + event
                         for event in (self.events if events is None else events))

    def rejected(self, log):
        with self.assertRaises((ValueError, OSError)):
            inspect(log, self.root, 'fixture')

    def test_valid_distinct_workers_and_explicit_limits(self):
        result = inspect(self.log(), self.root, 'fixture')
        self.assertTrue(result['synthetic_live_passed'])
        self.assertEqual([p['worker'] for p in result['phases']], [2, 3, 4])
        self.assertEqual(result['slot_sha256'], {s: hashlib.sha256(p.read_bytes()).hexdigest() for s, p in self.paths.items()})
        for flag in ('production_async_enabled', 'power_loss_verified', 'write_cycles_300_verified',
                     'cleanup_warning_history_verified', 'admission_completion_clock_bounds_verified',
                     'evidence_provenance_authenticated'):
            self.assertFalse(result[flag])

    def test_optional_context_and_other_nonce(self):
        events = self.events[:1] + ['CONTEXT_PAIR diagnostic_only=true storage_grant=false status=unverified'] + self.events[1:]
        self.assertTrue(inspect(self.log(events) + '\n2026-10-04T15:00:00Z different FAIL bad', self.root, 'fixture')['synthetic_live_passed'])
        self.rejected(self.log(events).replace('diagnostic_only=true', 'diagnostic_only=false'))

    def test_inert_missing_duplicate_and_fail_traces(self):
        traces = ['', self.log(self.events[:1]), self.log(self.events[-1:]), self.log(self.events[1:]),
                  self.log(self.events + ['FAIL late']), self.log(self.events + [self.events[-1]]),
                  self.log(self.events + ['UNKNOWN']), self.log().replace('phase=3', 'phase=2')]
        for index in range(len(self.events)):
            traces.append(self.log(self.events[:index] + self.events[index+1:]))
            traces.append(self.log(self.events[:index] + [self.events[index]] + self.events[index:]))
        for trace in traces:
            with self.subTest(trace=trace):
                self.rejected(trace)

    def test_every_pairwise_event_swap_rejected(self):
        for i in range(len(self.events)):
            for j in range(i+1, len(self.events)):
                events = self.events.copy()
                events[i], events[j] = events[j], events[i]
                with self.subTest(i=i, j=j):
                    self.rejected(self.log(events))

    def test_strict_shape_and_nonce(self):
        for trace in [self.log().replace('completion=1', 'completion=1 garbage'),
                      self.log().replace('game=1', 'game=1 game=2'),
                      self.log().replace('fixture', 'fixture-alias'),
                      self.log().replace('2026-10-04', '2026-99-04'),
                      self.log().replace('durable_ack=false', 'durable_ack=true'),
                      self.log().replace('Z fixture START phase=1', 'Z  fixture START phase=1')]:
            self.rejected(trace)
        for nonce in ('', 'fixture x', 'fixture.*', 'x'*65):
            with self.assertRaises(ValueError):
                inspect(self.log(), self.root, nonce)

    def test_thread_identity_each_phase(self):
        for phase in (1, 2, 3):
            for worker, game, completion in [(1, 1, 1), (0, 1, 1), (2**32, 1, 1),
                                             (2, 0, 0), (2, 2**32, 2**32), (2, 1, 9),
                                             (2, 9, 9)]:
                events = self.events.copy()
                events[2*phase-1] = f'START phase={phase} game={game}'
                events[2*phase] = f'RESULT phase={phase} values=1,{worker},{phase*100},{phase*100+10},10000000 completion={completion}'
                with self.subTest(phase=phase, worker=worker, game=game, completion=completion):
                    self.rejected(self.log(events))

    def test_clock_and_status_each_phase(self):
        for phase in (1, 2, 3):
            for status, start, end, frequency in [(0, 300, 310, 10000000), (1, 5, 4, 10000000),
                                                (1, 300, 310, 0), (1, 300, 310, 9),
                                                (1, 2**63, 2**63, 10000000),
                                                (1, 300, 310, 2**63)]:
                events = self.events.copy()
                events[phase*2] = f'RESULT phase={phase} values={status},2,{start},{end},{frequency} completion=1'
                with self.subTest(phase=phase, status=status, start=start, frequency=frequency):
                    self.rejected(self.log(events))
        self.rejected(self.log().replace('3,200,210', '3,100,110'))
        self.rejected(self.log().replace('Z fixture RESULT phase=3', 'Z fixture RESULT phase=3').replace(
            '2026-10-04T15:00:00Z fixture COMPLETE', '2026-10-04T14:59:59Z fixture COMPLETE'))

    def test_complete_bytes_for_both_slots_including_rehashed_corruption(self):
        for slot, path in self.paths.items():
            original = path.read_bytes()
            mutations = [original[:-1], original + b'X', envelope(300), envelope(2 if slot == 'A' else 3)]
            # Valid digests must not hide incorrect scope/header/payload bytes.
            for offset in (0, 8, 10, 14, 18, 18+len(SCOPE), len(original)-33):
                changed = bytearray(original[:-32])
                changed[offset] ^= 1
                mutations.append(bytes(changed) + hashlib.sha256(changed).digest())
            mutations.append(original[:-1] + bytes([original[-1] ^ 1]))
            for raw in mutations:
                with self.subTest(slot=slot, length=len(raw)):
                    path.write_bytes(raw)
                    self.rejected(self.log())
            path.write_bytes(original)

    def test_missing_and_malformed_target(self):
        for path in self.paths.values():
            original = path.read_bytes()
            path.unlink()
            self.rejected(self.log())
            path.mkdir()
            self.rejected(self.log())
            path.rmdir()
            path.write_bytes(original)

    def test_cleanup_artifacts_fail_and_remain_untouched(self):
        for name in ('pwp-journal-stage-test.tmp', 'pwp-journal-backup-test.record', 'PWP-JOURNAL-unknown'):
            path = self.root / name
            path.write_bytes(b'keep')
            self.rejected(self.log())
            self.assertEqual(path.read_bytes(), b'keep')
            path.unlink()
        path = self.root / 'pwp-journal-directory'
        path.mkdir()
        self.rejected(self.log())
        self.assertTrue(path.is_dir())

    def test_cli_inert_badtrace_fails_even_optimized_without_mutation(self):
        log_path = self.root / 'journal.log'
        before = {s: p.read_bytes() for s, p in self.paths.items()}
        for flags in ([], ['-O']):
            for events in (self.events[:1], list(reversed(self.events))):
                log_path.write_text(self.log(events))
                result = subprocess.run([sys.executable, '-B', *flags, str(SCRIPT), str(log_path),
                                         str(self.root), 'fixture'], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertEqual(log_path.read_text(), self.log(events))
                self.assertEqual({s: p.read_bytes() for s, p in self.paths.items()}, before)
            log_path.write_text(self.log())
            result = subprocess.run([sys.executable, '-B', *flags, str(SCRIPT), str(log_path),
                                     str(self.root), 'fixture'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(json.loads(result.stdout)['synthetic_live_passed'])


if __name__ == '__main__':
    unittest.main()
