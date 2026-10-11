"""External readback AFTER a logged completion. Never loads DLLs or writes saves.

Completion JSON: {"result": [status,error,tid,start_ticks,end_ticks,checksum,hz]}.
Phase initial expects published; phase conflict expects conflict for SECOND bytes.
Caller must correlate the completion with its invocation; this is not ownership proof.
"""
from pathlib import Path
import argparse
import hashlib
import json

SCRATCH = Path('C:/Users/matra/Desktop/palworld-priority-mod/test-results/native-file-probe-scratch')
TARGET = SCRATCH / ('pwp-init-' + 'a' * 32 + '-' + 'b' * 32 + '-priorities.record')
FIRST = bytes(range(256)) * 1024
SECOND = b'file-probe-conflict-DIFFERENT-BYTES'

def checksum(data):
    h = 5381
    for byte in data:
        h = (h * 33 + byte) & 0xffffffff
    return h

def validate_result(values, phase):
    if not isinstance(values, (list, tuple)) or len(values) != 7 or any(type(v) is not int for v in values):
        raise ValueError('uncertain completion shape; do not retry')
    status, error, tid, start, end, actual, frequency = values
    if status != (0 if phase == 'initial' else 2):
        raise ValueError('unconfirmed expected publication/conflict; do not retry')
    if (error != 0 if phase == 'initial' else error not in (80, 183)):
        raise ValueError('unexpected native error')
    if not 0 < tid <= 0xffffffff or start < 0 or end < start or frequency <= 0:
        raise ValueError('invalid timing metadata')
    if actual != checksum(FIRST if phase == 'initial' else SECOND):
        raise ValueError('attempted-payload checksum mismatch')

def read_exact():
    # Refuse existing reparse components before readback. Trusted-root assumption
    # still applies: this inspection is not a hostile namespace mutation defense.
    for path in (TARGET, *TARGET.parents):
        if path.lstat().st_file_attributes & 0x400:
            raise ValueError('reparse component in readback path')
    with TARGET.open('rb') as stream:
        data = stream.read(262145)
    if data != FIRST:
        raise ValueError('whole-byte fixed-target readback mismatch')
    return data

def verify(values, phase):
    validate_result(values, phase)
    data = read_exact()
    return {'phase': phase, 'result': list(values), 'target': str(TARGET),
            'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
            'whole_byte_comparison': True, 'durable_ack': False}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--phase', choices=['initial', 'conflict'], required=True)
    parser.add_argument('--completion', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(verify(json.loads(args.completion.read_text())['result'], args.phase), indent=2))
