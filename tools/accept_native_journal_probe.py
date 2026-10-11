"""Read-only three-phase synthetic receipt verifier.

Log/directory provenance is trusted, not authenticated. Final bytes cannot prove
intermediate readbacks or 300 writes. Cleanup is only a final snapshot; admission
and completion QPC values and cleanup warning history are not logged.
"""
from datetime import datetime
from pathlib import Path
import hashlib
import json
import re
import stat
import struct
import sys


def require(ok, message):
    if not ok:
        raise ValueError(message)


def ordinary(path, directory=False):
    info = path.lstat()
    require(not (getattr(info, 'st_file_attributes', 0) & 0x400)
            and not stat.S_ISLNK(info.st_mode), 'reparse/symlink evidence path')
    require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode),
            'evidence path type')


def inspect(log, root, nonce):
    require(re.fullmatch(r'[A-Za-z0-9-]{1,64}', nonce) is not None, 'invalid nonce')
    events = []
    previous_time = None
    for line in log.splitlines():
        if nonce not in line.split():
            continue
        match = re.fullmatch(r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) '
                             + re.escape(nonce) + r' (.+)', line)
        require(match is not None, 'malformed run line')
        stamp = datetime.strptime(match[1], '%Y-%m-%dT%H:%M:%SZ')
        require(previous_time is None or stamp >= previous_time, 'wall clock reversal')
        previous_time = stamp
        events.append(match[2])
    require(events and events[0] ==
            'ARMED synthetic only; delay=90000; phases=3; NOT production settings',
            'missing initial arm')
    events.pop(0)
    # Earlier builds did not log this optional diagnostic. Never a storage grant.
    if events and events[0].startswith('CONTEXT_PAIR '):
        require(events[0].startswith('CONTEXT_PAIR diagnostic_only=true storage_grant=false '),
                'context must remain diagnostic')
        events.pop(0)
    require(len(events) == 7, 'phase/event count')
    results = []
    game_id = frequency = previous_end = None
    for phase in (1, 2, 3):
        begin = re.fullmatch(rf'START phase={phase} game=(\d+)', events[2*(phase-1)])
        finish = re.fullmatch(rf'RESULT phase={phase} values=(\d+),(\d+),(\d+),(\d+),(\d+) completion=(\d+)',
                              events[2*(phase-1)+1])
        require(begin is not None and finish is not None, 'phase ordering/shape')
        game = int(begin[1])
        status, worker, start, end, freq, completion = map(int, finish.groups())
        require(status == 1 and 0 < game <= 0xffffffff and 0 < worker <= 0xffffffff
                and worker != game and completion == game, 'thread/status mismatch')
        require(game_id is None or game == game_id, 'game thread changed')
        require(0 < freq <= 0x7fffffffffffffff and 0 <= start <= end <= 0x7fffffffffffffff,
                'clock values')
        require(frequency is None or freq == frequency, 'clock frequency changed')
        require(previous_end is None or start >= previous_end, 'phase clock overlap/reversal')
        game_id, frequency, previous_end = game, freq, end
        results.append({'phase': phase, 'worker': worker, 'game': game,
                        'inclusive_ms': 1000*(end-start)/freq})
    require(events[-1] == 'COMPLETE native phases=3 owner_released=true '
            'independent_readback_required=true durable_ack=false', 'no final release')
    root = Path(root).absolute()
    for ancestor in (*reversed(root.parents), root):
        ordinary(ancestor, directory=True)
    scope = ('PWP-SCOPE-1:' + 32*'7' + ':' + 32*'8' + ':priorities').encode()
    stem = 'pwp-record-v1-' + 32*'7' + '-' + 32*'8' + '-priorities-'
    hashes = {}
    expected_size = 18 + len(scope) + 262144 + 32
    for slot, generation in [('A', 3), ('B', 2)]:
        path = root / (stem + slot + '.record')
        ordinary(path)
        with path.open('rb') as stream:
            raw = stream.read(expected_size + 1)
        require(len(raw) == expected_size and raw[:8] == b'PWPJNL1\n', 'bad magic/length')
        size, gen, length = struct.unpack('<HII', raw[8:18])
        require(size == len(scope) and gen == generation and length == 262144, 'header mismatch')
        require(hashlib.sha256(raw[:-32]).digest() == raw[-32:], 'digest mismatch')
        require(raw[18:18+size] == scope, 'scope mismatch')
        expected = bytes((i+generation) % 256 for i in range(256))*1024
        require(raw[18+size:-32] == expected, 'whole payload mismatch')
        hashes[slot] = hashlib.sha256(raw).hexdigest()
    require(not any(p.name.lower().startswith('pwp-journal-') for p in root.iterdir()),
            'unexpected retained stage/backup after clean run')
    return {'synthetic_live_passed': True, 'phases': results, 'slot_sha256': hashes,
            'production_async_enabled': False, 'power_loss_verified': False,
            'verified_phase_count': 3, 'write_cycles_300_verified': False,
            'cleanup_artifacts_absent_at_readback': True,
            'cleanup_warning_history_verified': False,
            'admission_completion_clock_bounds_verified': False,
            'evidence_provenance_authenticated': False}


if __name__ == '__main__':
    print(json.dumps(inspect(Path(sys.argv[1]).read_text(), sys.argv[2], sys.argv[3]), indent=2))
