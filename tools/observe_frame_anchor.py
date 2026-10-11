"""Observe one local anchor publication; never send commands or start captures.

Start before the Lua command, with an existing readable nonmatching file.
Use a fresh ASCII nonce, a single publisher, and exact bytes nonce + LF (Lua
should write in binary mode). Run only before/after a capture, never during one.
Raw Windows QPC ticks bracket publication, not a frame or Lua callback duration. Pair this result with
the Lua start/end record for the same nonce; do not infer a clock offset here.

The 15-second deadline rejects even a matching read that finishes late. Local
file reads are synchronous: an OS-stalled read cannot be interrupted by this
observer. Polling requests 1 ms sleeps; actual scheduling may widen the bracket.
"""
from __future__ import annotations

import argparse
import ctypes
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import re
import sys
import time


class AnchorError(ValueError):
    pass


def validate_nonce(nonce):
    if not isinstance(nonce, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", nonce):
        raise AnchorError("nonce must be 1-64 ASCII letters/digits/underscore/hyphen")
    return nonce.encode("ascii") + b"\n"


class WindowsQPC:
    """Read the OS counter directly; perf_counter is only the deadline clock."""

    def __init__(self):
        if sys.platform != "win32":
            raise AnchorError("native observer requires Windows QPC")
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self._counter = kernel.QueryPerformanceCounter
        frequency = kernel.QueryPerformanceFrequency
        for function in (self._counter, frequency):
            function.argtypes = [ctypes.POINTER(ctypes.c_longlong)]
            function.restype = ctypes.c_int
        value = ctypes.c_longlong()
        if not frequency(ctypes.byref(value)) or value.value <= 0:
            raise AnchorError("QueryPerformanceFrequency failed")
        self.frequency = value.value

    def __call__(self):
        value = ctypes.c_longlong()
        if not self._counter(ctypes.byref(value)):
            raise AnchorError("QueryPerformanceCounter failed")
        return value.value


def observe(path, nonce, *, timeout=15.0, qpc=None, frequency=None,
            clock=time.perf_counter, read=None, sleep=time.sleep, recorded_at=None):
    expected = validate_nonce(nonce)
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or not 0 < timeout <= 15:
        raise AnchorError("timeout must be finite, greater than zero and at most 15 seconds")
    if qpc is None and frequency is None:
        qpc = WindowsQPC()
        frequency = qpc.frequency
    if not callable(qpc) or type(frequency) is not int or frequency <= 0:
        raise AnchorError("QPC callable and positive integer frequency are required together")
    if read is None:
        target = Path(path)

        def read():
            with target.open("rb") as handle:
                # One extra byte detects trailing content without a large read.
                return handle.read(len(expected) + 1)

    started = clock()
    absent = previous_tick = None
    polls = failures = 0

    def tick():
        nonlocal previous_tick
        value = qpc()
        if type(value) is not int or value < 0 or (previous_tick is not None and value < previous_tick):
            raise AnchorError("invalid or backwards QPC counter")
        previous_tick = value
        return value

    while True:
        if clock() - started >= timeout:
            raise AnchorError("timeout before anchor publication was confirmed")
        before = tick()
        polls += 1
        read_ok = True
        try:
            contents = read()
        except OSError:
            # Missing files, sharing violations and partial-read errors are not
            # completed nonmatching reads: they cannot tighten the lower bound.
            failures += 1
            read_ok = False
        after = tick()
        elapsed = clock() - started
        if elapsed >= timeout:
            raise AnchorError("timeout before anchor publication was confirmed")
        if read_ok:
            if not isinstance(contents, bytes):
                raise AnchorError("reader must return exact bytes")
            if contents == expected:
                if polls == 1:
                    raise AnchorError("anchor already matches on the first read")
                if absent is None:
                    raise AnchorError("matching anchor without confirmed prior absence")
                return {
                    "nonce": nonce,
                    "qpc_absent_before": absent,
                    "qpc_present_after": after,
                    "frequency": frequency,
                    "bound_width_ms": (after - absent) * 1000 / frequency,
                    "polls": polls,
                    "read_failures": failures,
                    "recorded_at": recorded_at() if recorded_at else datetime.now(timezone.utc).isoformat(),
                }
            absent = before
        sleep(min(0.001, timeout - elapsed))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="existing local perf-anchor.txt")
    parser.add_argument("nonce", help="fresh nonce also supplied to the Lua command")
    parser.add_argument("--timeout", type=float, default=15.0)
    args = parser.parse_args(argv)
    try:
        result = observe(args.path, args.nonce, timeout=args.timeout)
    except (AnchorError, OSError) as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 2
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
