"""Accept archived disposable-file evidence; never loads code or changes saves."""
from datetime import datetime, timedelta
from pathlib import Path
import argparse
import hashlib
import json
import re

TARGET = ('C:/Users/matra/Desktop/palworld-priority-mod/test-results/native-file-probe-scratch/'
          'pwp-init-'+'a'*32+'-'+'b'*32+'-priorities.record')


def stamp(value):
    value = datetime.fromisoformat(value.replace('Z', '+00:00'))
    assert value.utcoffset() is not None, 'timezone missing'
    return value


def accept(log, nonce, ready, receipts):
    if not __debug__:
        raise RuntimeError('Acceptance requires assertions enabled; refuse optimized Python')
    events = []
    for line in log.splitlines():
        parts = line.split(' ', 3)
        if len(parts) == 4 and parts[1] == nonce:
            events.append((stamp(parts[0]), parts[2], parts[3]))
    assert [e[1] for e in events] == ['ARMED', 'START', 'RESULT', 'COMPLETE', 'START', 'RESULT', 'COMPLETE'], 'incomplete/duplicate/failed run'
    assert all(a[0] <= b[0] for a, b in zip(events, events[1:])), 'event order'
    assert stamp(ready) < events[1][0], 'not demonstrated after world ready'
    assert set(receipts) == {'initial', 'conflict'}
    data = bytes(range(256)) * 1024
    digest = hashlib.sha256(data).hexdigest()
    output = []
    previous_end = None
    identity = None
    for phase, offset, status, checksum in [('initial', 1, 0, 2382238981), ('conflict', 4, 2, 3713148193)]:
        start, result, complete = events[offset:offset+3]
        assert start[2].startswith('phase='+phase+' ')
        assert complete[2].startswith('phase='+phase+';')
        match = re.fullmatch(r'phase='+phase+r' values=([\d,]+) game=(\d+) completion=(\d+) completion_tick=(\d+)', result[2])
        assert match, 'malformed completion'
        values = list(map(int, match[1].split(',')))
        assert len(values) == 7
        state, error, worker, begin, end, actual, hz = values
        game, completion, tick = map(int, match.group(2, 3, 4))
        assert start[2] == 'phase='+phase+' game='+str(game), 'start/completion identity'
        assert state == status and error in ([0] if phase == 'initial' else [80, 183])
        assert worker > 0 and game > 0 and worker != game and completion == game
        assert 0 <= begin <= end <= tick and hz > 0 and actual == checksum
        if previous_end is not None:
            assert previous_end <= begin and identity == (game, hz)
        previous_end, identity = end, (game, hz)
        receipt = receipts[phase]
        assert receipt['nonce'] == nonce and receipt['phase'] == phase
        assert receipt['result'] == values
        assert (receipt['game_tid'], receipt['completion_tid'], receipt['completion_tick']) == (game, completion, tick)
        assert receipt['whole_byte_comparison'] is True and receipt['durable_ack'] is False
        assert receipt['bytes'] == len(data) and receipt['sha256'] == digest
        assert receipt['target'].replace('\\', '/') == TARGET, 'wrong destination'
        read = stamp(receipt['readback_utc'])
        assert result[0] <= read <= result[0] + timedelta(seconds=10), 'late/unrelated readback'
        if phase == 'initial':
            assert read < events[4][0], 'no intermediate readback'
        output.append({'phase': phase, 'native_inclusive_ms': (end-begin)*1000/hz, 'worker': worker, 'game': game})
    assert receipts['initial']['target'] == receipts['conflict']['target']
    return {'passed': True, 'nonce': nonce, 'phases': output, 'production_async_enabled': False,
            'durable_ack_proven': False, 'frame_time_acceptance': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--world-ready-utc', required=True)
    args = parser.parse_args()
    nonce = json.loads((args.directory/'installation.json').read_text())['nonce']
    receipts = {p: json.loads((args.directory/(p+'-readback.json')).read_text()) for p in ['initial', 'conflict']}
    print(json.dumps(accept((args.directory/'file.log').read_text(), nonce, args.world_ready_utc, receipts), indent=2))
