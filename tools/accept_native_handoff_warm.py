"""Read-only acceptance of three warm synthetic handoffs; never enables saves."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import re


def timestamp(value):
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.utcoffset() is None:
        raise ValueError('timezone required')
    return result


def accept(text, nonce, ready_utc):
    ready = timestamp(ready_utc)
    events = []
    for line in text.splitlines():
        match = re.fullmatch(r'(\S+) ' + re.escape(nonce) + r' trial=(\d+) (\w+) (.*)', line)
        if match:
            when, trial, kind, body = match.groups()
            events.append((timestamp(when), int(trial), kind, body))
    assert events and not any(e[2] == 'FAIL' for e in events), 'missing events or failed trial'
    assert sum(e[2] == 'ARMED' and e[1] == 0 for e in events) == 1, 'one arm required'
    assert all(e[1] in (0, 1, 2, 3) for e in events), 'unexpected trial'
    checksum = 5381
    for byte in bytes(range(256)) * 1024:
        checksum = (checksum * 33 + byte) & 0xffffffff
    results = []
    previous_pass = None
    for trial in (1, 2, 3):
        selected = {kind: [e for e in events if e[1] == trial and e[2] == kind]
                    for kind in ('START', 'DIAG', 'PASS')}
        assert all(len(v) == 1 for v in selected.values()), 'missing or duplicate trial evidence'
        start, diag, end = (selected[kind][0] for kind in ('START', 'DIAG', 'PASS'))
        assert ready < start[0] <= diag[0] <= end[0], 'not after observed world readiness'
        if previous_pass is not None:
            # ISO log timestamps have whole-second resolution.
            assert (start[0] - previous_pass).total_seconds() >= 9, 'trials not spaced'
        previous_pass = end[0]
        assert 'version=2 clock=QPC_us' in end[3] and 'NOT A SAVE TEST' in end[3]
        values = dict(re.findall(r'(\w+)=(\d+)', end[3]))
        fields = {key: int(values[key]) for key in (
            'checksum', 'worker', 'game', 'start_us', 'end_us',
            'beat_start_us', 'beat_end_us', 'beats', 'frequency_hz')}
        assert fields['checksum'] == checksum, 'checksum mismatch'
        assert fields['worker'] > 0 and fields['game'] > 0 and fields['worker'] != fields['game'], 'same thread'
        assert fields['end_us'] - fields['start_us'] >= 200000, 'short interval'
        assert fields['beat_start_us'] <= fields['beat_end_us'], 'reversed beat'
        assert fields['beat_start_us'] - fields['start_us'] > 3, 'beat outside interval'
        assert fields['end_us'] - fields['beat_end_us'] > 3, 'beat outside interval'
        assert fields['beats'] > 0 and 1000000 <= fields['frequency_hz'] <= 9223372036854
        raw_pattern = (r'n=5 checksum=(\d+) tid=(\d+) start_us=(\d+) end_us=(\d+) '
                       r'elapsed_us=(\d+) frequency_hz=(\d+)')
        def raw(label):
            match = re.search(re.escape(label) + raw_pattern, diag[3])
            assert match, 'missing raw ' + label
            value = tuple(map(int, match.groups()))
            assert value[3] - value[2] == value[4], 'raw elapsed mismatch'
            return value
        worker = raw('worker_ok=true ')
        baseline = raw('baseline ')
        completion = raw('completion_ok=true ')
        assert worker == (checksum, fields['worker'], fields['start_us'], fields['end_us'],
                          fields['end_us'] - fields['start_us'], fields['frequency_hz']), 'raw worker mismatch'
        assert baseline[0] == completion[0] == 5381 and baseline[1] == completion[1] == fields['game']
        assert baseline[5] == completion[5] == fields['frequency_hz']
        assert baseline[3] <= worker[2] and completion[2] >= worker[3], 'completion order'
        raw_beats = re.findall(r'beat\[\d+\] ' + raw_pattern, diag[3])
        assert len(raw_beats) == fields['beats'], 'raw beat count mismatch'
        assert any(tuple(map(int, b)) == (5381, fields['game'], fields['beat_start_us'],
                   fields['beat_end_us'], fields['beat_end_us']-fields['beat_start_us'],
                   fields['frequency_hz']) for b in raw_beats), 'claimed beat absent'
        results.append({'trial': trial, 'started_utc': start[0].isoformat(), **fields})
    return {'passed': True, 'world_ready_utc': ready.isoformat(), 'trials': results,
            'decoded_bytes_per_trial': 262144, 'save_test': False,
            'frame_time_acceptance': False, 'production_async_enabled': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--nonce', required=True)
    parser.add_argument('--world-ready-utc', required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(accept(args.log.read_text(), args.nonce, args.world_ready_utc), indent=2))
    except (AssertionError, KeyError, ValueError, OSError) as error:
        print(json.dumps({'passed': False, 'error': str(error)}))
        raise SystemExit(1)
