"""Strict clock-only log acceptance: advancement observed, elapsed NOT validated.

No game access, enablement, process control, or writes. Native identity and
restoration evidence are separate obligations; this parser cannot attest them.
"""
from pathlib import Path
import argparse
import json
import math
import re


def require(value, message):
    if not value:
        raise ValueError(message)


def accept(text, nonce):
    require(isinstance(nonce, str) and re.fullmatch(r'[0-9a-f]{32}', nonce)
            and nonce != '0' * 32, 'invalid nonce')
    require(isinstance(text, str) and len(text) <= 9 * 4096, 'invalid log size')
    lines = text.splitlines()
    require(len(lines) == 9 and text.endswith('\n'), 'incomplete clock log')
    rows = []
    for line in lines:
        parts = line.split(' | ')
        require(parts[0] == 'PWP_DEDICATED_CLOCK' and len(line) < 4096, 'invalid record')
        row = {}
        for field in parts[1:]:
            require('=' in field, 'invalid field')
            key, value = field.split('=', 1)
            require(key not in row and re.fullmatch(r'[a-z_]+', key), 'duplicate/invalid key')
            require(re.fullmatch(r'[A-Za-z0-9_.+\-]+', value) is not None, 'invalid value')
            row[key] = value
        require(row.get('nonce') == nonce, 'nonce mismatch')
        for key in ('verified', 'active', 'storage_grant', 'authority_grant', 'coverage_grant', 'elapsed_validated'):
            require(row.get(key) == 'false', 'grant or validation claim')
        require(row.get('clock') == 'GameplayStatics_GetAccurateRealTime'
                and row.get('measurement') == 'clock_under_test', 'wrong clock')
        require(row.get('total_callback_ms') == 'unknown' and row.get('resolver_ms') == 'unknown',
                'unsupported cost claim')
        rows.append(row)

    def number(row, key):
        try:
            value = float(row[key])
        except (KeyError, ValueError):
            raise ValueError('missing or invalid number') from None
        require(math.isfinite(value) and value >= 0, 'invalid number')
        return value

    advances = 0
    elapsed = 0.0
    for index, row in enumerate(rows[:8], 1):
        require(row.get('status') == 'observed' and row.get('reason') == 'sample', 'failed sample')
        require(row.get('samples') == str(index) and row.get('callbacks') == str(index), 'sample sequence')
        for key, expected in [('reads', 34), ('read_intervals', 32), ('work_steps', 4096),
                              ('checksum', sum(range(1, 4097)) % 65521)]:
            require(row.get(key) == str(expected), 'operation count mismatch')
        if index == 1:
            require(row.get('between_sample_ms') == 'unknown'
                    and row.get('between_sample_advanced') == 'false', 'first sample interval')
        else:
            require(0 < number(row, 'between_sample_ms') <= 60000
                    and row.get('between_sample_advanced') == 'true', 'no between-sample progress')
        if index > 1:
            elapsed += number(row, 'between_sample_ms')
        require(elapsed < 60000, 'run elapsed limit exceeded')
        burst = number(row, 'read_burst_ms')
        work = number(row, 'work_and_final_read_ms')
        total = number(row, 'first_to_last_read_ms')
        require(total <= 100 and math.isclose(burst + work, total, abs_tol=0.00001, rel_tol=0.00001),
                'sample span differs')
        require(math.isclose(number(row, 'mean_read_interval_ms') * 32, burst,
                             abs_tol=0.00001, rel_tol=0.00001), 'mean differs')
        require(row.get('within_sample_advanced') == ('true' if total > 0 else 'false'), 'advance mismatch')
        advances += total > 0
    end = rows[8]
    require(end.get('status') == 'finished' and end.get('reason') == 'sample_limit', 'no successful terminal')
    for key, expected in [('samples', 8), ('callbacks', 8), ('observed_samples', 8),
                          ('forward_intervals', 7), ('within_sample_advances', advances)]:
        require(end.get(key) == str(expected), 'terminal count differs')
    require(advances > 0 and end.get('advancement_observed') == 'true', 'no synchronous progress')
    require(end.get('cancellation_attempted') == 'true' and end.get('timer_cancelled') == 'true',
            'cancellation unconfirmed')
    return {'advancement_observed': True, 'elapsed_validated': False, 'samples': 8,
            'within_sample_advances': advances, 'timer_cancelled': True,
            'native_identity_verified': False, 'restoration_verified': False,
            'storage_grant': False, 'authority_grant': False, 'coverage_grant': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--nonce', required=True)
    args = parser.parse_args()
    try:
        require(args.log.stat().st_size <= 9 * 4096, 'log too large')
        result = accept(args.log.read_text(encoding='utf-8'), args.nonce)
    except (OSError, UnicodeError, ValueError):
        print(json.dumps({'advancement_observed': False, 'reason': 'incomplete_or_invalid_evidence'}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
