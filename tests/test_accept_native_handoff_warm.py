import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('warm_accept', Path(__file__).resolve().parents[1] / 'tools/accept_native_handoff_warm.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fixture():
    lines = ['2026-10-04T11:00:00Z test trial=0 ARMED warm']
    raw = ('version=2 clock=QPC_us worker_ok=true n=5 checksum=2382238981 tid=2 start_us=1000000 end_us=1200100 elapsed_us=200100 frequency_hz=10000000'
           ' | baseline n=5 checksum=5381 tid=1 start_us=900000 end_us=900000 elapsed_us=0 frequency_hz=10000000'
           ' | completion_ok=true n=5 checksum=5381 tid=1 start_us=1200200 end_us=1200200 elapsed_us=0 frequency_hz=10000000'
           ' | beat[1] n=5 checksum=5381 tid=1 start_us=1100000 end_us=1100001 elapsed_us=1 frequency_hz=10000000')
    result = ('handoff version=2 clock=QPC_us checksum=2382238981 worker=2 game=1 start_us=1000000 end_us=1200100 '
              'beat_start_us=1100000 beat_end_us=1100001 beats=1 frequency_hz=10000000; NOT A SAVE TEST')
    for trial, seconds in enumerate((20, 30, 40), 1):
        prefix = f'2026-10-04T11:01:{seconds}Z test trial={trial} '
        lines.extend([prefix+'START warm', prefix+'DIAG '+raw, prefix+'PASS '+result])
    return '\n'.join(lines)


class AcceptanceTests(unittest.TestCase):
    def accept(self, text):
        return module.accept(text, 'test', '2026-10-04T11:01:00Z')

    def test_complete_evidence(self):
        self.assertTrue(self.accept(fixture())['passed'])

    def test_rejects_inert_partial_and_false_evidence(self):
        good = fixture()
        cases = ['', good.replace('test trial=3', 'other trial=3'), good+'\n'+good,
                 good.replace(' PASS ', ' FAIL '), good.replace(' DIAG ', ' UNKNOWN '),
                 good.replace('worker=2', 'worker=1'), good.replace('checksum=2382238981', 'checksum=1'),
                 good.replace('end_us=1200100', 'end_us=1199999'),
                 good.replace('beat_start_us=1100000', 'beat_start_us=1200200'),
                 good.replace('tid=2', 'tid=3'), good.replace('elapsed_us=200100', 'elapsed_us=1'),
                 good.replace('11:01:20Z', '11:00:20Z')]
        for bad in cases:
            with self.subTest(bad=bad[:100]), self.assertRaises((AssertionError, KeyError)):
                self.accept(bad)


if __name__ == '__main__':
    unittest.main()
