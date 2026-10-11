"""Offline publication brackets; no engine, polling process, or capture."""
import contextlib
import ctypes
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import observe_frame_anchor as anchor


class Fixture:
    def __init__(self, reads):
        self.reads = iter(reads)
        self.now = 0.0
        self.sleeps = []
        self.before = []

    def clock(self):
        return self.now

    def qpc(self):
        # Deliberately unrelated epoch to perf_counter's zero origin.
        return 9_000_000 + round(self.now * 1_000_000)

    def read(self):
        self.before.append(self.qpc())
        delay, result = next(self.reads)
        self.now += delay
        if isinstance(result, Exception):
            raise result
        return result

    def sleep(self, duration):
        self.sleeps.append(duration)
        self.now += duration

    def observe(self, **kwargs):
        return anchor.observe("unused", "new-123", qpc=self.qpc, frequency=1_000_000,
                              clock=self.clock, read=self.read, sleep=self.sleep,
                              recorded_at=lambda: "2026-09-13T16:00:00+00:00", **kwargs)


class FrameAnchorTests(unittest.TestCase):
    def test_crossing_write_uses_before_absent_read_not_its_completion(self):
        # Writer publishes at 5 ms while a read holding old contents completes
        # at 10 ms. Using that read's completion would exclude publication.
        f = Fixture([(0.010, b"old\n"), (0.002, b"new-123\n")])
        result = f.observe()
        self.assertEqual(result["qpc_absent_before"], 9_000_000)
        self.assertEqual(result["qpc_present_after"], 9_013_000)
        self.assertLessEqual(result["qpc_absent_before"], 9_005_000)
        self.assertGreaterEqual(result["qpc_present_after"], 9_005_000)
        self.assertEqual(result["bound_width_ms"], 13)
        self.assertEqual(result["frequency"], 1_000_000)
        self.assertEqual(result["polls"], 2)
        self.assertEqual(result["read_failures"], 0)
        self.assertEqual(f.sleeps, [0.001])
        self.assertEqual(set(result), {"nonce", "qpc_absent_before", "qpc_present_after",
                                      "frequency", "bound_width_ms", "polls", "read_failures", "recorded_at"})

    def test_errors_and_missed_polls_widen_bound_without_replacing_absence(self):
        f = Fixture([(0.002, b"old\n"), (0.004, PermissionError()),
                     (0.010, FileNotFoundError()), (0.002, b"new-123\n")])
        result = f.observe()
        self.assertEqual(result["qpc_absent_before"], f.before[0])
        self.assertEqual(result["qpc_present_after"], f.qpc())
        self.assertEqual(result["bound_width_ms"], 21)
        self.assertEqual(result["polls"], 4)
        self.assertEqual(result["read_failures"], 2)
        self.assertEqual(f.sleeps, [0.001] * 3)

    def test_latest_completed_nonmatch_tightens_lower_bound(self):
        f = Fixture([(0.001, b"old\n"), (0.002, b""), (0.003, b"new-123\n")])
        result = f.observe()
        self.assertEqual(result["qpc_absent_before"], f.before[1])
        self.assertEqual(result["bound_width_ms"], 6)

    def test_exact_bytes_only_including_newline(self):
        f = Fixture([(0, b"new-123"), (0, b"new-123\r\n"), (0, b"new-123\nextra"),
                     (0, b"wrong\n"), (0, b"new-123\n")])
        result = f.observe()
        self.assertEqual(result["polls"], 5)
        self.assertEqual(result["qpc_absent_before"], f.before[3])

    def test_matching_first_read_and_no_confirmed_absence_fail(self):
        with self.assertRaisesRegex(anchor.AnchorError, "first read"):
            Fixture([(0, b"new-123\n")]).observe()
        with self.assertRaisesRegex(anchor.AnchorError, "without confirmed"):
            Fixture([(0, FileNotFoundError()), (0, b"new-123\n")]).observe()

    def test_timeout_including_late_matching_read(self):
        for last in (b"old\n", b"new-123\n", PermissionError()):
            with self.subTest(last=last), self.assertRaisesRegex(anchor.AnchorError, "timeout"):
                Fixture([(0, b"old\n"), (15, last)]).observe()
        f = Fixture([(0, b"old\n")])
        with self.assertRaisesRegex(anchor.AnchorError, "timeout"):
            f.observe(timeout=0.0005)
        self.assertEqual(f.sleeps, [0.0005])
        self.assertEqual(len(f.before), 1)

    def test_invalid_nonce_timeout_and_counter_inputs_fail_before_read(self):
        for nonce in ("", "white space", "line\n", "line\r", "é", "a.b", "../nonce", "a" * 65, None):
            with self.subTest(nonce=nonce), self.assertRaises(anchor.AnchorError):
                anchor.observe("unused", nonce)
        for timeout in (0, -1, 15.001, float("nan"), float("inf"), True):
            with self.subTest(timeout=timeout), self.assertRaises(anchor.AnchorError):
                Fixture([]).observe(timeout=timeout)
        for frequency in (None, 0, -1, 1.5, True):
            with self.subTest(frequency=frequency), self.assertRaises(anchor.AnchorError):
                anchor.observe("unused", "valid", qpc=lambda: 1, frequency=frequency)
        self.assertEqual(anchor.validate_nonce("A" * 64), b"A" * 64 + b"\n")
        self.assertEqual(anchor.validate_nonce("-_S1"), b"-_S1\n")

    def test_backwards_counter_and_nonbytes_reader_refuse(self):
        ticks = iter([100, 99])
        with self.assertRaisesRegex(anchor.AnchorError, "backwards"):
            anchor.observe("unused", "valid", qpc=lambda: next(ticks), frequency=1000,
                           read=lambda: b"old\n")
        for contents in ("old\n", None):
            with self.subTest(contents=contents), self.assertRaisesRegex(anchor.AnchorError, "exact bytes"):
                Fixture([(0, contents)]).observe()

    def test_delayed_sleep_widens_bracket_using_actual_ticks(self):
        f = Fixture([(0, b"old\n"), (0, b"new-123\n")])
        original_sleep = f.sleep
        f.sleep = lambda requested: original_sleep(0.020)
        result = f.observe()
        self.assertEqual(result["bound_width_ms"], 20)
        self.assertEqual(result["qpc_absent_before"], 9_000_000)
        self.assertEqual(result["qpc_present_after"], 9_020_000)

    def test_default_reader_is_bounded_binary_and_does_not_write(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "anchor.txt"
            target.write_bytes(b"new-123\n" + b"x" * 10000)
            f = Fixture([])

            def publish(duration):
                f.sleep(duration)
                target.write_bytes(b"new-123\n")

            result = anchor.observe(target, "new-123", qpc=f.qpc, frequency=1_000_000,
                                    clock=f.clock, sleep=publish)
            self.assertEqual(result["polls"], 2)
            self.assertEqual(target.read_bytes(), b"new-123\n")

    def test_windows_backend_reads_actual_counter_and_checks_os_failures(self):
        frequency, counter = mock.Mock(), mock.Mock()

        def fill(value):
            def call(pointer):
                ctypes.cast(pointer, ctypes.POINTER(ctypes.c_longlong))[0] = value
                return 1
            return call

        frequency.side_effect = fill(10_000_000)
        counter.side_effect = fill(987_654_321)
        kernel = mock.Mock(QueryPerformanceFrequency=frequency, QueryPerformanceCounter=counter)
        with mock.patch.object(anchor.sys, "platform", "win32"), \
                mock.patch.object(anchor.ctypes, "WinDLL", return_value=kernel, create=True):
            qpc = anchor.WindowsQPC()
            self.assertEqual(qpc.frequency, 10_000_000)
            self.assertEqual(qpc(), 987_654_321)
            counter.side_effect = None
            counter.return_value = 0
            with self.assertRaisesRegex(anchor.AnchorError, "Counter failed"):
                qpc()
            frequency.side_effect = None
            frequency.return_value = 0
            with self.assertRaisesRegex(anchor.AnchorError, "Frequency failed"):
                anchor.WindowsQPC()

    def test_cli_json_success_and_failure_exit(self):
        expected = Fixture([(0, b"old\n"), (0, b"new-123\n")]).observe()
        with mock.patch.object(anchor, "observe", return_value=expected), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(anchor.main(["anchor.txt", "new-123"]), 0)
            self.assertEqual(json.loads(output.getvalue()), expected)
        with mock.patch.object(anchor, "observe", side_effect=anchor.AnchorError("no absence")), \
                contextlib.redirect_stdout(io.StringIO()) as output, \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(anchor.main(["anchor.txt", "new-123"]), 2)
            self.assertEqual(output.getvalue(), "")
            self.assertEqual(json.loads(errors.getvalue()), {"error": "no absence"})


if __name__ == "__main__":
    unittest.main()
