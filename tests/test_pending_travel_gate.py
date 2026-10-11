import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('pending_gate', Path(__file__).resolve().parents[1]/'tools/accept_pending_travel_gate.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def record(t, event, scope, worker, caller, accepted=1, committed=0, timeout=0):
    return f'PWP_DEV_PENDING_1\t{t}\t{event}\t{scope}\tworker={worker}\tcaller={caller}\taccepted={accepted}\tcommitted={committed}\tparked=1\ttimeout={timeout}\n'


class GateTest(unittest.TestCase):
    def setUp(self):
        self.rows = [record(100, 'park', 'limits', 2, 2), record(101, 'park', 'priorities', 3, 3),
                     record(110, 'join', 'limits', 2, 1), record(111, 'release_join', 'limits', 2, 2),
                     record(120, 'join', 'priorities', 3, 1), record(121, 'release_join', 'priorities', 3, 3)]

    def accept(self, rows):
        return gate.accept(''.join(rows), ['limits', 'priorities'])

    def test_complete(self):
        result = self.accept(self.rows)
        self.assertTrue(result['native_pending_at_both_joins'])
        self.assertFalse(result['live_travel_verified'])
        self.assertFalse(result['durable_recovery_verified'])

    def test_each_missing_event(self):
        for i in range(6):
            with self.subTest(i=i), self.assertRaises(ValueError):
                self.accept(self.rows[:i] + self.rows[i+1:])

    def test_corrupt_evidence(self):
        mutants = [ ''.join(self.rows).replace('timeout=0', 'timeout=1', 1),
                    ''.join(self.rows).replace('accepted=1', 'accepted=0', 1),
                    ''.join(self.rows).replace('caller=1', 'caller=2', 1),
                    ''.join(self.rows).replace('worker=3', 'worker=2'),
                    ''.join(self.rows).replace('\t101\t', '\t115\t'),
                    ''.join(self.rows).replace('release_join', 'release_timeout', 1),
                    ''.join(self.rows).replace('\t111\t', '\t700000000\t'),
                    ''.join(self.rows).replace('committed=0', 'committed=-1', 1)]
        for m in mutants:
            with self.subTest(m=m), self.assertRaises(ValueError):
                gate.accept(m, ['limits', 'priorities'])


if __name__ == '__main__':
    unittest.main()
