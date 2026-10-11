"""Pinned PresentMon capture with offline validation; default is read-only preflight.

--capture is opt-in. No elevation, game launch, force termination, session stealing,
or inferred performance acceptance. A stuck recorder remains supervised.
"""
from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
import uuid

import analyze_frames as af

ROOT = Path(__file__).resolve().parents[1]
RECORDER = ROOT / 'test-results/capture-tools/PresentMon-2.5.1-x64.exe'
RECORDER_SHA256 = '9bec3083069f58f911e6a512f4806db51a27bd096103087bc1d05ef54c80a191'
GAME_NAME = 'palworld-win64-shipping.exe'
MAX_DURATION = 300


def require(condition, message):
    if not condition:
        raise ValueError(message)


def utc():
    return datetime.now(timezone.utc).isoformat()


def plain_path(path):
    path = Path(path).absolute()
    for part in (path, *path.parents):
        if part.is_symlink():
            raise ValueError('symlink path refused')
        if part.exists():
            require(not (getattr(part.stat(), 'st_file_attributes', 0)
                         & stat.FILE_ATTRIBUTE_REPARSE_POINT), 'reparse path refused')
    return path


def digest(path):
    path = plain_path(path)
    with path.open('rb') as stream:
        before = os.fstat(stream.fileno())
        value = hashlib.file_digest(stream, 'sha256').hexdigest()
        after = os.fstat(stream.fileno())
    signature = lambda s: (s.st_ino, s.st_size, s.st_mtime_ns)
    require(signature(before) == signature(after) == signature(path.stat()), 'file changed while hashing')
    return value


def same_process(a, b):
    return (a['pid'], a['created_ticks'], os.path.normcase(a['path'])) == (
        b['pid'], b['created_ticks'], os.path.normcase(b['path']))


def write_json(path, value):
    with path.open('x', encoding='utf-8') as stream:
        json.dump(value, stream, indent=2, allow_nan=False)
        stream.write('\n')


def validate_csv(path, pid, duration, *, qpc_frequency=None):
    """v1 PresentMon schema; intervals end at TimeInSeconds, not display times."""
    if qpc_frequency is not None:
        require(type(qpc_frequency) is int and 0 < qpc_frequency <= 2**63-1,
                'invalid QPC frequency')
    raw = af.read_bytes(path)
    first_qpc, previous_qpc = None, None
    max_qpc_interval_error, max_qpc_relative_error = 0.0, 0.0
    frames, chains, applications, dropped = [], set(), set(), 0
    previous, first_timestamp, initial_zero, raw_rows = None, None, 0, 0
    required = ('Application', 'ProcessID', 'SwapChainAddress', 'Runtime',
                'Dropped', 'TimeInSeconds', 'msBetweenPresents')
    if qpc_frequency is not None:
        required += ('QPCTime',)
    for i, row in af.csv_rows(raw, required):
        require(row['ProcessID'] == str(pid), f'row {i}: wrong process ID')
        require(row['Application'].lower() in (GAME_NAME, '<unknown>'), f'row {i}: unexpected application')
        require(re.fullmatch(r'0x[0-9a-fA-F]+', row['SwapChainAddress']) is not None
                and int(row['SwapChainAddress'], 16) != 0, f'row {i}: invalid swapchain')
        require(row['Runtime'] in ('DXGI', 'D3D9'), f'row {i}: unsupported runtime')
        require(row['Dropped'] in ('0', '1'), f'row {i}: invalid dropped flag')
        t = af.finite(row['TimeInSeconds'], f'row {i} timestamp')
        ms = af.finite(row['msBetweenPresents'], f'row {i} interval')
        require(t >= 0, f'row {i}: negative timestamp')
        require(ms > 0 or (i == 1 and ms == 0), f'row {i}: nonpositive interval')
        if previous is not None:
            delta = t - previous
            require(delta > 0, f'row {i}: nonmonotonic timestamp')
            require(abs(delta * 1000 - ms) <= 0.02, f'row {i}: interval/timestamp mismatch')
        if qpc_frequency is not None:
            # Archived --v1_metrics --qpc_time CSV keeps TimeInSeconds and
            # adds decimal integer QPCTime. Never parse ticks through float.
            tick_text = row['QPCTime']
            require(re.fullmatch(r'[0-9]{1,19}', tick_text) is not None,
                    f'row {i}: invalid integer QPCTime')
            tick = int(tick_text)
            require(0 < tick <= 2**63-1, f'row {i}: invalid QPCTime range')
            if previous_qpc is not None:
                require(tick > previous_qpc, f'row {i}: nonmonotonic QPCTime')
                interval_error = abs((tick - previous_qpc) * 1000 / qpc_frequency - ms)
                relative_error = abs((tick - first_qpc) / qpc_frequency - (t - first_timestamp)) * 1000
                max_qpc_interval_error = max(max_qpc_interval_error, interval_error)
                max_qpc_relative_error = max(max_qpc_relative_error, relative_error)
                require(interval_error <= 0.02, f'row {i}: QPC interval mismatch')
                require(relative_error <= 0.02, f'row {i}: QPC relative timestamp mismatch')
            else:
                first_qpc = tick
            previous_qpc = tick
        previous, raw_rows = t, i
        if i == 1:
            # Its interval starts outside the observed timestamp series. Keep
            # this timestamp as the anchor for row 2, but never use its metric.
            first_timestamp, initial_zero = t, int(ms == 0)
        else:
            frames.append((t, ms))
        chains.add(row['SwapChainAddress'].lower())
        applications.add(row['Application'])
        dropped += int(row['Dropped'])
    require(len(frames) >= 2, 'insufficient frame samples')
    require(len(chains) == 1, 'multiple swapchains: separate analysis required')
    # Each retained interval ENDS at its row timestamp. The first retained
    # interval starts at the excluded row's timestamp, not its own endpoint.
    span = frames[-1][0] - first_timestamp
    # Permit startup/flush edge loss, but never call a short sample complete.
    tolerance = max(0.5, duration * 0.02)
    require(duration - tolerance <= span <= duration + tolerance, 'insufficient or excessive duration coverage')
    validation = {'raw': af.identity(path, raw), 'schema': 'PresentMon v1 metrics',
            'applications': sorted(applications), 'swapchain': next(iter(chains)),
            'raw_rows': raw_rows, 'initial_zero_interval_excluded': initial_zero,
            'unanchored_first_interval_excluded': 1,
            'coverage': {'start_s': first_timestamp, 'end_s': frames[-1][0], 'span_s': span},
            'dropped_raw_rows': dropped, 'duration_tolerance_s': tolerance,
            'statistics': af.statistics(frames, af.DEFAULT_SPIKES)}
    if qpc_frequency is not None:
        validation['qpc'] = {
            'column': 'QPCTime', 'unit': 'ticks', 'frequency_hz': qpc_frequency,
            # Strings preserve exact integers in downstream JSON consumers.
            'coverage_start_tick': str(first_qpc), 'coverage_end_tick': str(previous_qpc),
            'span_s': (previous_qpc - first_qpc) / qpc_frequency,
            'max_interval_error_ms': max_qpc_interval_error,
            'max_relative_error_ms': max_qpc_relative_error,
            'derived_frames_clock': 'TimeInSeconds (unchanged relative Present seconds)',
            'alignment': 'raw QPC does not establish a Lua clock map or causal attribution'}
    return validation, frames


class WindowsBackend:
    """Only process reads and an exact-child PresentMon WM_QUIT; no kill API."""
    def __init__(self):
        require(os.name == 'nt', 'capture requires Windows')
        import ctypes as c
        from ctypes import wintypes as w
        self.c, self.w = c, w
        self.kernel = c.WinDLL('kernel32', use_last_error=True)
        self.user = c.WinDLL('user32', use_last_error=True)
        signatures = [
            (self.kernel.QueryPerformanceFrequency, [c.POINTER(c.c_longlong)], w.BOOL),
            (self.kernel.OpenProcess, [w.DWORD, w.BOOL, w.DWORD], w.HANDLE),
            (self.kernel.CloseHandle, [w.HANDLE], w.BOOL),
            (self.kernel.GetProcessTimes, [w.HANDLE] + [c.POINTER(w.FILETIME)] * 4, w.BOOL),
            (self.kernel.GetProcessId, [w.HANDLE], w.DWORD),
            (self.kernel.QueryFullProcessImageNameW, [w.HANDLE, w.DWORD, w.LPWSTR, c.POINTER(w.DWORD)], w.BOOL),
            (self.kernel.GetExitCodeProcess, [w.HANDLE, c.POINTER(w.DWORD)], w.BOOL),
            (self.user.FindWindowExW, [w.HWND, w.HWND, w.LPCWSTR, w.LPCWSTR], w.HWND),
            (self.user.GetWindowThreadProcessId, [w.HWND, c.POINTER(w.DWORD)], w.DWORD),
            (self.user.PostMessageW, [w.HWND, w.UINT, w.WPARAM, w.LPARAM], w.BOOL),
        ]
        for function, arguments, result in signatures:
            function.argtypes, function.restype = arguments, result

    def qpc_frequency(self):
        value = self.c.c_longlong()
        require(self.kernel.QueryPerformanceFrequency(self.c.byref(value)) and value.value > 0,
                'QueryPerformanceFrequency unavailable')
        return value.value

    def identity(self, pid, process=None):
        c, w, k = self.c, self.w, self.kernel
        # Retain Popen's OS process handle for recorder ownership, not a fresh PID lookup.
        owned = process is None
        handle = k.OpenProcess(0x1000, False, pid) if owned else int(process._handle)
        require(bool(handle), 'process identity unavailable')
        try:
            require(k.GetProcessId(handle) == pid, 'process handle mismatch')
            stamps = [w.FILETIME() for _ in range(4)]
            require(k.GetProcessTimes(handle, *(c.byref(x) for x in stamps)), 'process creation time unavailable')
            path, size, code = c.create_unicode_buffer(32768), w.DWORD(32768), w.DWORD()
            require(k.QueryFullProcessImageNameW(handle, 0, path, c.byref(size)), 'process image unavailable')
            require(k.GetExitCodeProcess(handle, c.byref(code)) and code.value == 259, 'process no longer running')
            return {'pid': pid, 'created_ticks': str((stamps[0].dwHighDateTime << 32) | stamps[0].dwLowDateTime),
                    'path': str(Path(path.value).absolute())}
        finally:
            if owned:
                k.CloseHandle(handle)

    def launch(self, arguments, stdout, stderr):
        return subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                creationflags=subprocess.CREATE_NO_WINDOW, shell=False)

    def normal_stop(self, process, identity):
        if process.poll() is not None:
            return 'already_exited'
        if (os.path.normcase(identity['path']) != os.path.normcase(str(RECORDER))
                or not same_process(identity, self.identity(process.pid, process))):
            return 'identity_mismatch'
        hwnd = None
        for _ in range(1024):
            hwnd = self.user.FindWindowExW(self.w.HWND(-3), hwnd, 'PresentMon', 'PresentMonWnd')
            if not hwnd:
                return 'window_unavailable'
            owner = self.w.DWORD()
            self.user.GetWindowThreadProcessId(hwnd, self.c.byref(owner))
            if owner.value == process.pid:
                if process.poll() is not None:
                    return 'already_exited'
                # Same message used by v2.5.1 ExitMainThread(): graceful trace/thread teardown.
                return 'quit_posted' if self.user.PostMessageW(hwnd, 0x0012, 0, 0) else 'quit_refused'
        return 'window_search_limit'


def supervise(process, backend, recorder_identity, directory):
    """Never return while our recorder lives. Acquisition bounded, cleanup may wait."""
    attempts, last = 0, 'not_requested'
    while process.poll() is None:
        attempts += 1
        try:
            if recorder_identity is None:
                recorder_identity = backend.identity(process.pid, process)
                require(os.path.normcase(recorder_identity['path']) == os.path.normcase(str(RECORDER)),
                        'recorder path mismatch')
            last = backend.normal_stop(process, recorder_identity)
        except (Exception, KeyboardInterrupt):
            last = 'normal_stop_unavailable'
        if attempts == 1:
            try:
                write_json(directory / 'cleanup.json', {'state': 'cleanup_pending', 'recorder_pid': process.pid,
                           'identity': recorder_identity, 'requested_utc': utc(), 'normal_stop': last,
                           'policy': 'supervise until exit; no force termination'})
            except (Exception, KeyboardInterrupt):
                # Failed evidence IO must not abandon a live recorder.
                pass
        try:
            process.wait(timeout=5)
        except (Exception, KeyboardInterrupt):
            continue
    return {'state': 'exited', 'normal_stop': last, 'attempts': attempts, 'exit_code': process.returncode}


def run(pid, game_exe, output_root, *, expected_start=None, duration=10, delay=5,
        capture=False, backend=None, qpc_time=False):
    require(type(qpc_time) is bool, 'qpc_time must be boolean')
    require(type(pid) is int and 0 < pid <= 0xffffffff, 'invalid PID')
    require(type(duration) is int and 10 <= duration <= MAX_DURATION, 'duration must be 10..300 seconds')
    require(type(delay) is int and 0 <= delay <= 30, 'delay must be 0..30 seconds')
    game_exe = plain_path(game_exe)
    require(game_exe.name.lower() == GAME_NAME, 'expected shipping game executable')
    require(digest(RECORDER) == RECORDER_SHA256, 'recorder hash mismatch')
    backend = backend or WindowsBackend()
    qpc_frequency = backend.qpc_frequency() if qpc_time else None
    if qpc_time:
        require(type(qpc_frequency) is int and 0 < qpc_frequency <= 2**63-1,
                'invalid QPC frequency')
    game = backend.identity(pid)
    require(os.path.normcase(game['path']) == os.path.normcase(str(game_exe)), 'game process path mismatch')
    game_hash = digest(game_exe)
    require(same_process(game, backend.identity(pid)), 'game changed during fingerprint')
    if expected_start is not None:
        require(str(expected_start) == game['created_ticks'], 'game creation time mismatch')
    preflight = {'state': 'preflight', 'game': game, 'game_exe_disk_sha256': game_hash,
                 'recorder_sha256': RECORDER_SHA256, 'duration_s': duration, 'delay_s': delay}
    if qpc_time:
        preflight.update(timestamp_mode='raw_qpc', qpc_frequency_hz=qpc_frequency,
                         qpc_frequency_source='QueryPerformanceFrequency')
    if not capture:
        return preflight
    require(expected_start is not None, '--capture requires --expected-start from preflight')
    parent = plain_path(output_root)
    parent.mkdir(parents=True, exist_ok=True)
    nonce = uuid.uuid4().hex
    directory = parent / nonce
    directory.mkdir()  # exclusive, never replace an earlier failure or CSV
    arguments = [str(RECORDER), '--process_id', str(pid), '--output_file', str(directory / 'raw.csv'),
                 '--session_name', 'PWPFrames_' + nonce, '--v1_metrics', '--no_track_input',
                 '--no_console_stats', '--delay', str(delay), '--timed', str(duration), '--terminate_after_timed']
    if qpc_time:
        arguments.append('--qpc_time')
    write_json(directory / 'attempt.json', {**preflight, 'capture_id': nonce, 'created_utc': utc(),
               'arguments': arguments, 'collection_timeout_s': delay + duration + 15,
               'limitations': 'disk hashes are not loaded-byte attestation; Present intervals are not display latency'})
    result = {'state': 'failed', 'capture_id': nonce, 'directory': str(directory)}
    process, recorder_identity = None, None
    begun = time.monotonic()
    try:
        with (directory / 'stdout.txt').open('xb') as stdout, (directory / 'stderr.txt').open('xb') as stderr:
            try:
                require(same_process(game, backend.identity(pid)), 'game changed before launch')
                require(digest(RECORDER) == RECORDER_SHA256, 'recorder changed before launch')
                process = backend.launch(arguments, stdout, stderr)
                result['recorder_pid'] = process.pid
                recorder_identity = backend.identity(process.pid, process)
                require(os.path.normcase(recorder_identity['path']) == os.path.normcase(str(RECORDER)),
                        'launched recorder path mismatch')
                result['recorder'] = recorder_identity
                process.wait(timeout=delay + duration + 15)
                result['exit_code'] = process.returncode
                require(process.returncode == 0, 'recorder exited unsuccessfully')
            finally:
                if process is not None and process.poll() is None:
                    result['cleanup'] = supervise(process, backend, recorder_identity, directory)
        after = backend.identity(pid)
        result['game_after'] = after
        require(same_process(game, after), 'game exited or changed during capture')
        require(digest(game_exe) == game_hash, 'game executable changed during capture')
        # Read warnings as evidence; the generic SeDebugPrivilege warning is not a failure.
        stderr_data = af.read_bytes(directory / 'stderr.txt', 1024 * 1024)
        warning_text = stderr_data.decode('utf-8-sig', errors='replace')
        require(not re.search(r'ETW (?:events|buffers) were lost|overflowed present events', warning_text),
                'capture reports event loss')
        if qpc_time:
            current_frequency = backend.qpc_frequency()
            require(type(current_frequency) is int and current_frequency == qpc_frequency,
                    'QPC frequency changed or unavailable after capture')
        validation, frames = validate_csv(directory / 'raw.csv', pid, duration,
                                          qpc_frequency=qpc_frequency)
        result['validation'] = validation
        with (directory / 'frames.csv').open('x', encoding='utf-8', newline='') as stream:
            writer = csv.writer(stream)
            writer.writerow(('time_s', 'frame_ms'))
            writer.writerows(frames)
        result['state'] = 'validated'
    except (Exception, KeyboardInterrupt) as exc:
        result['error'] = 'interrupted' if isinstance(exc, KeyboardInterrupt) else str(exc)
        result['error_type'] = type(exc).__name__
    result['finished_utc'] = utc()
    result['elapsed_s'] = time.monotonic() - begun
    if process is not None:
        result['exit_code'] = process.returncode
    result['artifacts'] = {}
    for path in directory.iterdir():
        if path.is_file():
            try:
                result['artifacts'][path.name] = digest(path)
            except Exception as exc:
                result.setdefault('artifact_errors', {})[path.name] = str(exc)
                result['state'], result['error'] = 'failed', 'artifact fingerprint unavailable'
    if 'validation' in result:
        expected = result['validation']['raw']['sha256']
        actual = result['artifacts'].get('raw.csv')
        result['integrity'] = {'validated_raw_sha256': expected, 'final_raw_sha256': actual,
                               'matches': expected == actual}
        if expected != actual:
            result['state'] = 'failed'
            result['error'] = 'validated raw CSV changed before final artifact hashing'
            result['error_type'] = 'ArtifactChanged'
    write_json(directory / 'result.json', result)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--game-exe', type=Path, required=True)
    parser.add_argument('--expected-start')
    parser.add_argument('--duration', type=int, default=10)
    parser.add_argument('--delay', type=int, default=5)
    parser.add_argument('--output-root', type=Path, default=ROOT / 'test-results/frame-captures')
    parser.add_argument('--qpc-time', action='store_true',
                        help='retain and validate raw QPCTime ticks alongside relative Present timestamps')
    parser.add_argument('--capture', action='store_true')
    args = parser.parse_args(argv)
    try:
        result = run(args.pid, args.game_exe, args.output_root, expected_start=args.expected_start,
                     duration=args.duration, delay=args.delay, capture=args.capture, qpc_time=args.qpc_time)
        print(json.dumps(result, indent=2, allow_nan=False))
        return 0 if result['state'] in ('preflight', 'validated') else 2
    except (Exception, KeyboardInterrupt) as exc:
        print(json.dumps({'state': 'refused', 'error': str(exc)}))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
