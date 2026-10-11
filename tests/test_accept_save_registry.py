import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('registry_accept', ROOT/'tools/accept_save_registry.py')
accept = importlib.util.module_from_spec(spec)
spec.loader.exec_module(accept)


class RegistryAcceptance(unittest.TestCase):
    def setUp(self):
        self.process = {'Id': 42, 'StartTime': '2026-10-04T01:00:00+02:00'}
        self.lines = [f'2026-10-03T23:00:{i+1:02d}Z PWP registry V1 test-1 {event}'
                      for i, event in enumerate(accept.EVENTS)]

    def check(self, lines=None, before=None, after=None):
        return accept.validate('\n'.join(self.lines if lines is None else lines), 'test-1',
                               before or self.process, after or self.process)

    def test_complete_is_not_production_authorization(self):
        result = self.check()
        self.assertTrue(result['registry_fixture_passed'])
        self.assertFalse(result['production_registry_integrated'])
        self.assertFalse(result['async_enable_authorized'])

    def test_missing_duplicate_wrong_result_or_timer_is_rejected(self):
        mutations = [self.lines[:i]+self.lines[i+1:] for i in range(len(self.lines))]
        mutations += [self.lines+[self.lines[-1]], list(reversed(self.lines)),
                      [s.replace('timer_cancelled=true', 'timer_cancelled=false') for s in self.lines],
                      [s.replace('cross_class=refused', 'cross_class=allowed') for s in self.lines],
                      [s.replace('test-1', 'other-nonce') for s in self.lines],
                      self.lines+['2026-10-03T23:00:07Z PWP registry V1 test-1 FAIL late failure']]
        for lines in mutations:
            with self.subTest(lines=lines), self.assertRaises(ValueError):
                self.check(lines)

    def test_process_and_timestamp_guards(self):
        with self.assertRaises(ValueError):
            self.check(after={**self.process, 'Id': 43})
        later = {**self.process, 'StartTime': '2026-10-04T01:01:00+02:00'}
        with self.assertRaises(ValueError):
            self.check(before=later, after=later)
        with self.assertRaises(ValueError):
            self.check([s.replace('23:00:05', '23:08:05') for s in self.lines])

    def test_empty_archive_cli_fails(self):
        with tempfile.TemporaryDirectory() as folder:
            result = subprocess.run([sys.executable, str(ROOT/'tools/accept_save_registry.py'), folder],
                                    capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('"registry_fixture_passed": false', result.stdout)

    def test_v2_requires_capacity_and_correct_version(self):
        events = accept.EVENTS[:1] + ('REGISTRY_CAPACITY_PASS retained_scopes=32 overflow_refused=1',) + accept.EVENTS[1:]
        lines = [f'2026-10-03T23:00:{i+1:02d}Z PWP registry V2 test-1 {event}' for i,event in enumerate(events)]
        check = lambda rows: accept.validate('\n'.join(rows), 'test-1', self.process, self.process, version=2)
        result = check(lines)
        self.assertEqual(result['registry_version'], 2)
        self.assertFalse(result['async_enable_authorized'])
        for damaged in (lines[:1]+lines[2:], [s.replace('retained_scopes=32','retained_scopes=31') for s in lines],
                        [s.replace('overflow_refused=1','overflow_refused=0') for s in lines],
                        lines[:1]+[lines[1]]+lines[1:]):
            with self.assertRaises(ValueError): check(damaged)
        with self.assertRaises(ValueError):
            accept.validate('\n'.join(lines), 'test-1', self.process, self.process)


if __name__ == '__main__':
    unittest.main()
