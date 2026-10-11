"""Offline only: synthetic CSV, temporary paths, fake child processes/Win32 APIs."""
import copy
import csv
import ctypes
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import capture_frames as cf


WARNING = ('warning: PresentMon requires elevated privilege in order to query processes that are\n'
           'short-running or started on another account.\n')


def csv_text(pid=42, rows=201):
    # Include real extra columns and BOM; never confuse msInPresentAPI with intervals.
    return '\ufeffApplication,ProcessID,SwapChainAddress,Runtime,Dropped,TimeInSeconds,msInPresentAPI,msBetweenPresents\n' + ''.join(
        f'Palworld-Win64-Shipping.exe,{pid},0x1234,DXGI,{i%2},{5+i*.05:.8f},0.01,50\n'
        for i in range(rows))


def qpc_csv(start=212142578967, step=500000):
    rows = csv_text().splitlines()
    return rows[0] + ',QPCTime\n' + ''.join(
        row + ',' + str(start+i*step) + '\n' for i,row in enumerate(rows[1:]))


class Process:
    pid = 777
    returncode = None

    def __init__(self, waits):
        self.waits = list(waits)
        self.returncode = None
        self.timeouts = []

    def poll(self):
        return self.returncode

    def wait(self, timeout):
        self.timeouts.append(timeout)
        value = self.waits.pop(0)
        if value == 'timeout':
            raise subprocess.TimeoutExpired('owned recorder', timeout)
        if value == 'interrupt':
            raise KeyboardInterrupt()
        self.returncode = value
        return value


class Backend:
    def __init__(self, game, recorder):
        self.game = {'pid': 42, 'created_ticks': '123456', 'path': str(game)}
        self.recorder = {'pid': 777, 'created_ticks': '987654', 'path': str(recorder)}
        self.waits = [0]
        self.csv = csv_text()
        self.stderr = WARNING
        self.launched, self.stopped, self.queries = [], [], []
        self.change_at = None

    def qpc_frequency(self):
        return 10000000

    def identity(self, pid, process=None):
        self.queries.append((pid, process))
        if process is not None:
            assert pid == 777 and process is self.process
            return dict(self.recorder)
        assert pid == 42
        identity = dict(self.game)
        count = sum(p == 42 for p, _ in self.queries)
        if self.change_at is not None and count >= self.change_at:
            identity['created_ticks'] = 'new-process-same-pid'
        return identity

    def launch(self, args, stdout, stderr):
        self.launched.append(list(args))
        path = Path(args[args.index('--output_file') + 1])
        if self.csv is not None:
            path.write_text(self.csv, encoding='utf-8')
        stdout.write(b'Started recording.\nStopped recording.\n')
        stderr.write(self.stderr.encode())
        self.process = Process(self.waits)
        return self.process

    def normal_stop(self, process, identity):
        assert process is self.process and identity == self.recorder
        self.stopped.append(process.pid)
        return 'quit_posted'


class CaptureTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='capture offline spaces ')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.exe = self.root / 'PresentMon-2.5.1-x64.exe'
        self.exe.write_bytes(b'fake recorder')
        self.game = self.root / 'Palworld-Win64-Shipping.exe'
        self.game.write_bytes(b'fake game')
        self.output = self.root / 'attempts'
        for name, value in [('RECORDER', self.exe), ('RECORDER_SHA256', hashlib.sha256(b'fake recorder').hexdigest())]:
            p = patch.object(cf, name, value); p.start(); self.addCleanup(p.stop)
        self.backend = Backend(self.game, self.exe)

    def run_capture(self, **kw):
        return cf.run(42, self.game, self.output, expected_start='123456', capture=True,
                      backend=self.backend, **kw)

    def test_preflight_no_launch_or_output(self):
        r = cf.run(42, self.game, self.output, backend=self.backend)
        self.assertEqual(r['game'], self.backend.game)
        self.assertEqual(r['state'], 'preflight')
        self.assertFalse(self.output.exists())
        self.assertEqual(self.backend.launched, [])

    def test_warning_with_valid_real_schema_passes_and_retains_dropped(self):
        r = self.run_capture()
        self.assertEqual(r['state'], 'validated', r)
        self.assertEqual(r['exit_code'], 0)
        self.assertEqual(r['validation']['statistics']['frame_count'], 200)
        self.assertAlmostEqual(r['validation']['statistics']['mean_ms'], 50)
        self.assertEqual(r['validation']['dropped_raw_rows'], 100)
        self.assertEqual(r['game_after'], self.backend.game)
        self.assertEqual(self.backend.stopped, [])
        argv = self.backend.launched[0]
        self.assertEqual(argv[0], str(self.exe))
        self.assertEqual(argv[argv.index('--process_id')+1], '42')
        self.assertNotIn('--qpc_time', argv)
        self.assertNotIn('qpc', r['validation'])
        self.assertNotIn('--restart_as_admin', argv)
        self.assertNotIn('--terminate_on_proc_exit', argv)
        self.assertNotIn('--stop_existing_session', argv)
        self.assertEqual(self.backend.process.timeouts, [30])
        receipt = json.loads((Path(r['directory'])/'result.json').read_text())
        self.assertEqual(receipt['state'], 'validated')
        self.assertEqual((Path(r['directory'])/'stdout.txt').read_text(), 'Started recording.\nStopped recording.\n')

    def test_qpc_capture_retains_relative_output_and_exact_tick_bounds(self):
        self.backend.csv = qpc_csv(start=2**53+1)
        r = self.run_capture(qpc_time=True)
        self.assertEqual(r['state'], 'validated', r)
        self.assertIn('--qpc_time', self.backend.launched[0])
        qpc = r['validation']['qpc']
        self.assertEqual(qpc['coverage_start_tick'], str(2**53+1))
        self.assertEqual(qpc['coverage_end_tick'], str(2**53+1+100000000))
        self.assertEqual(qpc['frequency_hz'], 10000000)
        self.assertEqual(qpc['span_s'], 10)
        self.assertEqual(qpc['max_interval_error_ms'], 0)
        self.assertEqual(r['validation']['statistics']['frame_count'], 200)
        path = Path(r['directory'])
        self.assertEqual((path/'raw.csv').read_text(encoding='utf-8'), self.backend.csv)
        derived = list(csv.reader((path/'frames.csv').read_text().splitlines()))
        self.assertEqual(derived[0], ['time_s','frame_ms'])
        self.assertEqual(derived[1], ['5.05','50.0'])
        attempt = json.loads((path/'attempt.json').read_text())
        self.assertEqual(attempt['timestamp_mode'], 'raw_qpc')
        self.assertEqual(attempt['qpc_frequency_hz'], 10000000)

    def test_qpc_preflight_queries_frequency_without_launch(self):
        r = cf.run(42,self.game,self.output,backend=self.backend,qpc_time=True)
        self.assertEqual(r['qpc_frequency_hz'],10000000)
        self.assertFalse(self.output.exists())
        self.assertFalse(self.backend.launched)
        with patch.object(self.backend,'qpc_frequency',side_effect=AssertionError('not requested')):
            cf.run(42,self.game,self.output,backend=self.backend)

    def test_qpc_missing_or_invalid_frequency_refuses_before_launch(self):
        for value in [None,False,0,-1,1.5,'10000000',2**63]:
            with self.subTest(value=value), patch.object(self.backend,'qpc_frequency',return_value=value):
                with self.assertRaisesRegex(ValueError,'QPC frequency'):
                    self.run_capture(qpc_time=True)
        with patch.object(self.backend,'qpc_frequency',side_effect=OSError('unavailable')):
            with self.assertRaises(OSError): self.run_capture(qpc_time=True)
        self.assertFalse(self.backend.launched)
        self.assertFalse(self.output.exists())

    def test_qpc_frequency_change_after_capture_fails(self):
        self.backend.csv=qpc_csv()
        with patch.object(self.backend,'qpc_frequency',side_effect=[10000000,10000001]):
            r=self.run_capture(qpc_time=True)
        self.assertEqual(r['state'],'failed')
        self.assertIn('frequency changed',r['error'])

    def test_qpc_schema_ticks_and_both_clock_consistency_fail_closed(self):
        valid=qpc_csv()
        cases=[csv_text(), valid.replace('QPCTime','QpcTime',1),
               valid.replace('QPCTime','QPCTime,QPCTime',1)]
        for value in ['', 'NaN','1.5','1e10','-1','0','+212142578967',' 212142578967',str(2**63)]:
            cases.append(valid.replace('212142578967',value,1))
        cases += [valid.replace('212143078967','212142578967',1),
                  valid.replace('212143078967','212142578966',1),
                  qpc_csv(step=500300),  # each interval mismatches
                  qpc_csv(step=500002)]  # individually within tolerance, accumulated drift exceeds it
        for data in cases:
            with self.subTest(data=data[-100:]):
                self.backend.csv=data
                r=self.run_capture(qpc_time=True)
                self.assertEqual(r['state'],'failed',r)

    def test_qpc_zero_first_interval_keeps_anchor_not_metric(self):
        self.backend.csv=qpc_csv().replace(',50,',',0,',1)
        r=self.run_capture(qpc_time=True)
        self.assertEqual(r['state'],'validated',r)
        self.assertEqual(r['validation']['initial_zero_interval_excluded'],1)
        self.assertEqual(r['validation']['qpc']['span_s'],10)

    def test_qpc_final_raw_change_keeps_integrity_failure(self):
        self.backend.csv=qpc_csv()
        original=cf.digest
        def change(path):
            if path.name=='raw.csv': path.write_text('changed raw QPC')
            return original(path)
        with patch.object(cf,'digest',side_effect=change): r=self.run_capture(qpc_time=True)
        self.assertEqual(r['state'],'failed')
        self.assertFalse(r['integrity']['matches'])
        self.assertIn('qpc',r['validation'])

    def test_windows_qpc_frequency_adapter_reads_signed_integer_and_refuses_failure(self):
        backend=cf.WindowsBackend.__new__(cf.WindowsBackend)
        backend.c=ctypes
        for success,value in [(True,10000000),(False,10000000),(True,0),(True,-1)]:
            def query(ptr):
                ptr._obj.value=value
                return success
            backend.kernel=types.SimpleNamespace(QueryPerformanceFrequency=query)
            if success and value>0:
                self.assertEqual(backend.qpc_frequency(),value)
            else:
                with self.assertRaisesRegex(ValueError,'QueryPerformanceFrequency'):
                    backend.qpc_frequency()

    def test_qpc_cli_opt_in(self):
        with patch.object(cf,'run',return_value={'state':'preflight'}) as run, patch('sys.stdout',new=io.StringIO()):
            self.assertEqual(cf.main(['--pid','42','--game-exe',str(self.game),'--qpc-time']),0)
        self.assertTrue(run.call_args.kwargs['qpc_time'])

    def test_preflight_refusals_never_launch(self):
        for field, value in [('created_ticks', 'different'), ('path', str(self.root / 'launcher.exe'))]:
            old = self.backend.game[field]; self.backend.game[field] = value
            with self.assertRaises(ValueError): self.run_capture()
            self.backend.game[field] = old
        self.exe.write_bytes(b'wrong recorder')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'): self.run_capture()
        self.assertEqual(self.backend.launched, [])

    def test_opt_in_start_and_bounds_required(self):
        for kwargs in [{'duration': 9}, {'duration': 301}, {'duration': True}, {'delay': -1}, {'delay': 31}]:
            with self.assertRaises(ValueError): self.run_capture(**kwargs)
        with self.assertRaisesRegex(ValueError, 'expected-start'):
            cf.run(42, self.game, self.output, capture=True, backend=self.backend)
        self.assertFalse(self.output.exists())

    def test_pid_reuse_before_launch_or_during_capture(self):
        for count, launches in [(2, 0), (3, 0), (4, 1)]:
            self.backend = Backend(self.game, self.exe); self.backend.change_at = count
            if count == 2:
                with self.assertRaises(ValueError): self.run_capture()
            else:
                r = self.run_capture(); self.assertEqual(r['state'], 'failed')
            self.assertEqual(len(self.backend.launched), launches)

    def test_missing_csv_and_header_only_are_failures_not_warning_diagnosis(self):
        for data in [None, '', csv_text(rows=0), csv_text(rows=1)]:
            self.backend.csv = data
            r = self.run_capture()
            self.assertEqual(r['state'], 'failed')
            self.assertNotIn('privilege', r['error'].lower())

    def test_nonzero_exit_and_session_collision_preserve_evidence(self):
        for message in ['error: failed to start trace session: access denied.',
                        'error: a trace session named X is already running.']:
            self.backend.waits = [6]; self.backend.stderr = message
            r = self.run_capture()
            self.assertEqual(r['state'], 'failed'); self.assertEqual(r['exit_code'], 6)
            self.assertEqual((Path(r['directory'])/'stderr.txt').read_text(), message)

    def test_failed_attempt_cannot_reuse_session_receipts_or_stale_csv(self):
        a = self.run_capture()
        before = {p.name: p.read_bytes() for p in Path(a['directory']).iterdir()}
        self.backend.csv = None
        b = self.run_capture()
        self.assertEqual(b['state'], 'failed')
        self.assertNotEqual(a['capture_id'], b['capture_id'])
        self.assertNotEqual(self.backend.launched[0][6], self.backend.launched[1][6])
        self.assertEqual(before, {p.name: p.read_bytes() for p in Path(a['directory']).iterdir()})

    def test_timeout_cleanup_only_own_recorder_and_never_passes(self):
        self.backend.waits = ['timeout', 'timeout', 0]
        r = self.run_capture()
        self.assertEqual(r['state'], 'failed')
        self.assertEqual(self.backend.stopped, [777, 777])
        self.assertEqual(r['cleanup']['state'], 'exited')
        self.assertEqual(self.backend.process.timeouts, [30, 5, 5])
        self.assertEqual(json.loads((Path(r['directory'])/'cleanup.json').read_text())['state'], 'cleanup_pending')
        self.assertEqual(self.backend.process.poll(), 0)

    def test_interrupt_keeps_supervision_even_if_cleanup_receipt_fails(self):
        self.backend.waits = ['interrupt', 'interrupt', 0]
        original = cf.write_json
        def write(path, value):
            if path.name == 'cleanup.json': raise OSError('disk unavailable')
            return original(path, value)
        with patch.object(cf, 'write_json', side_effect=write): r = self.run_capture()
        self.assertEqual(r['state'], 'failed'); self.assertEqual(r['error'], 'interrupted')
        self.assertEqual(self.backend.stopped, [777, 777])
        self.assertEqual(self.backend.process.poll(), 0)

    def test_launch_failure_retained(self):
        with patch.object(self.backend, 'launch', side_effect=OSError('launch refused')):
            r = self.run_capture()
        self.assertEqual(r['state'], 'failed')
        self.assertTrue((Path(r['directory'])/'result.json').exists())

    def test_event_loss_rejects_even_with_valid_rows(self):
        self.backend.stderr = 'warning: 5 ETW events were lost.'
        r = self.run_capture()
        self.assertEqual(r['state'], 'failed')
        self.assertIn('event loss', r['error'])

    def test_csv_bad_pid_chain_clock_metrics_and_duration(self):
        cases = [csv_text(pid=43), csv_text(rows=100), csv_text(rows=230),
                 csv_text().replace('0x1234', 'garbage', 1),
                 csv_text().replace('0x1234', '0x9999', 1),
                 csv_text().replace(',50\n', ',NaN\n', 1),
                 csv_text().replace(',50\n', ',0\n', 2),
                 csv_text().replace('5.05000000', '5.00000000'),
                 csv_text().replace('5.05000000', '5.06000000'),
                 csv_text().replace('ProcessID', 'ProcessId'),
                 csv_text().replace('msBetweenPresents', 'FrameTime'),
                 csv_text().replace('Dropped,', 'Dropped,Dropped,', 1)]
        for data in cases:
            with self.subTest(data=data[:150]):
                self.backend.csv = data
                r = self.run_capture()
                self.assertEqual(r['state'], 'failed', r)

    def test_first_zero_interval_explicitly_excluded_without_extra_coverage(self):
        self.backend.csv = csv_text().replace(',50\n', ',0\n', 1)
        r = self.run_capture()
        self.assertEqual(r['state'], 'validated', r)
        v = r['validation']
        self.assertEqual(v['raw_rows'], 201)
        self.assertEqual(v['initial_zero_interval_excluded'], 1)
        self.assertEqual(v['statistics']['frame_count'], 200)
        self.assertAlmostEqual(v['statistics']['timestamp_span_s'], 9.95)
        self.assertIn(',0\n', (Path(r['directory'])/'raw.csv').read_text())

    def test_first_positive_interval_unanchored_excluded_from_derived_evidence(self):
        self.backend.csv = csv_text().replace(',50\n', ',10000000\n', 1)
        r = self.run_capture()
        self.assertEqual(r['state'], 'validated', r)
        v = r['validation']
        self.assertEqual(v['statistics']['max_ms'], 50)
        self.assertEqual(v['statistics']['frame_count'], 200)
        self.assertEqual(v['unanchored_first_interval_excluded'], 1)
        self.assertEqual(v['coverage'], {'start_s': 5.0, 'end_s': 15.0, 'span_s': 10.0})
        self.assertAlmostEqual(v['statistics']['summed_frame_durations_s'], 10.0)
        self.assertAlmostEqual(v['statistics']['first_time_s'], 5.05)
        self.assertIn(',10000000\n', (Path(r['directory'])/'raw.csv').read_text())

    def test_raw_replacement_at_final_hash_fails_preserving_both_hashes(self):
        original = cf.digest
        observed = {}
        def replace_raw(path):
            if path.name == 'raw.csv':
                observed['before'] = original(path)
                path.write_bytes(b'replaced after analysis\n')
                observed['after'] = original(path)
            return original(path)
        with patch.object(cf, 'digest', side_effect=replace_raw):
            r = self.run_capture()
        self.assertEqual(r['state'], 'failed', 'changed raw CSV retained validated receipt')
        self.assertEqual(r['validation']['raw']['sha256'], observed['before'])
        self.assertEqual(r['artifacts']['raw.csv'], observed['after'])
        self.assertIn('raw CSV changed', r['error'])
        self.assertFalse(r['integrity']['matches'])
        self.assertEqual(json.loads((Path(r['directory'])/'result.json').read_text()), r)

    def test_graceful_win32_message_bound_to_child_identity_and_window(self):
        backend = cf.WindowsBackend.__new__(cf.WindowsBackend)
        backend.c = ctypes
        backend.w = types.SimpleNamespace(DWORD=ctypes.c_uint32, HWND=lambda x: x)
        process = Process([])
        identity = dict(self.backend.recorder)
        backend.identity = lambda pid, child: dict(identity)
        calls = []
        windows = iter([100, 200])
        def find(parent, previous, cls, title):
            self.assertEqual((parent, cls, title), (-3, 'PresentMon', 'PresentMonWnd'))
            return next(windows)
        def owner(hwnd, ptr): ptr._obj.value = 42 if hwnd == 100 else 777
        backend.user = types.SimpleNamespace(FindWindowExW=find, GetWindowThreadProcessId=owner,
            PostMessageW=lambda *args: calls.append(args) or True)
        self.assertEqual(backend.normal_stop(process, identity), 'quit_posted')
        self.assertEqual(calls, [(200, 0x12, 0, 0)])
        identity['created_ticks'] = 'changed'
        backend.identity = lambda pid, child: dict(self.backend.recorder)
        self.assertEqual(backend.normal_stop(process, identity), 'identity_mismatch')
        self.assertEqual(len(calls), 1)


class ArchivedCaptureTests(unittest.TestCase):
    def test_archived_raw_qpc_captures_use_recorded_frequency_and_schema(self):
        root=Path(__file__).resolve().parents[1]/'test-results'
        for stem in ['correlation-absent1-20260913','correlation-traced-20260913']:
            with self.subTest(stem=stem):
                path=root/(stem+'.csv'); metadata=root/(stem+'.json')
                if not path.exists() or not metadata.exists():
                    self.skipTest('local archived capture not included: '+stem)
                before=path.read_bytes()
                recorded=json.loads(metadata.read_text(encoding='utf-8-sig'))
                result,frames=cf.validate_csv(path,recorded['game_pid'],recorded['duration'],
                    qpc_frequency=recorded['qpc_frequency'])
                rows=list(csv.DictReader(before.decode('utf-8-sig').splitlines()))
                self.assertEqual(result['raw_rows'],len(rows))
                self.assertEqual(len(frames),len(rows)-1)
                self.assertEqual(result['qpc']['coverage_start_tick'],rows[0]['QPCTime'])
                self.assertEqual(result['qpc']['coverage_end_tick'],rows[-1]['QPCTime'])
                self.assertAlmostEqual(result['qpc']['span_s'],result['coverage']['span_s'],places=6)
                self.assertEqual(path.read_bytes(),before)

    def test_known_successful_presentmon_captures(self):
        root = Path(__file__).resolve().parents[1] / 'test-results'
        for name, pid, count in [('stand-retest-off-presentmon-20260912.csv', 7180, 8286),
                                 ('deep-perf-restart-on1-presentmon-20260913.csv', 34308, 9545)]:
            with self.subTest(name=name):
                path = root / name
                if not path.exists():
                    self.skipTest('local archived capture not included in checkout: ' + name)
                before = hashlib.sha256(path.read_bytes()).hexdigest()
                result, frames = cf.validate_csv(path, pid, 60)
                self.assertEqual(result['raw_rows'], count)
                self.assertEqual(len(frames), count-1)
                self.assertEqual(result['unanchored_first_interval_excluded'], 1)
                self.assertGreater(result['statistics']['timestamp_span_s'], 59)
                self.assertAlmostEqual(result['statistics']['summed_frame_durations_s'], result['coverage']['span_s'], places=5)
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), before)


if __name__ == '__main__':
    unittest.main()
