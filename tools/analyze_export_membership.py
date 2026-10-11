"""Strict read-only analysis of three bundle-bound membership observations.

Caller supplies independently checked expectations. Accepted observations never
establish historical completeness, migration authority, or deletion permission.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

MAX_KEYS = 256
MAX_LOG = 4 * 1024 * 1024
MAX_LINE = 4096
ADDRESSES = ('world_address', 'state_address', 'instance_address', 'manager_address',
             'player_address', 'controller_address', 'player_state_address', 'guild_address')
GRANTS = frozenset(('activation_allowed', 'ownership_verified', 'deletion_coverage_verified',
                    'history_coverage_verified', 'authority_grant', 'storage_grant',
                    'coverage_grant', 'replacement_allowed', 'deletion_allowed'))
FIELDS = frozenset(('event', 'nonce', 'manifest_sha256', 'storage', 'guild', 'world_hex',
                    'sample', 'key', 'status', 'complete', 'confirmed', 'unresolved',
                    'not_examined', 'reason', 'alias')) | GRANTS | frozenset(ADDRESSES)
STATUSES = ('current_target_confirmed', 'unresolved', 'not_examined')


def require(ok, why):
    if not ok:
        raise ValueError(why)


def _hex(value, width, nonzero=False):
    return (type(value) is str and re.fullmatch('[0-9a-f]{' + str(width) + '}', value)
            and (not nonzero or value != '0' * width))


def _count(value):
    require(re.fullmatch(r'0|[1-9][0-9]{0,2}', value) is not None, 'invalid count')
    n = int(value)
    require(n <= MAX_KEYS, 'count exceeds bound')
    return n


def analyze(text, *, nonce, manifest_sha256, storage, guild, alias, keys):
    require(_hex(nonce, 32, True) and _hex(manifest_sha256, 64)
            and _hex(storage, 32, True) and _hex(guild, 32, True), 'invalid expected identity')
    require(type(alias) is str and 0 < len(alias) <= 256 and alias.isascii()
            and not any(ord(c) < 32 or ord(c) == 127 for c in alias), 'invalid expected alias')
    words = re.fullmatch(r'(-?[0-9]+)-(-?[0-9]+)-(-?[0-9]+)-(-?[0-9]+)', alias)
    require(words is not None, 'invalid expected alias')
    integers = [int(v) for v in words.groups()]
    require(all(str(n) == word and -2147483648 <= n <= 4294967295
                for n, word in zip(integers, words.groups()))
            and ''.join(f'{n % 4294967296:08x}' for n in integers) == guild,
            'alias does not match expected guild')
    require(type(keys) is list and len(keys) <= MAX_KEYS, 'invalid expected keys')
    require(all(type(k) is str and re.fullmatch(r'[0-9A-F]{64}', k)
                and k[32:] != '0' * 32 for k in keys), 'invalid expected key')
    require(keys == sorted(set(keys)), 'expected keys must be sorted and unique')
    keys = list(keys)
    require(type(text) is str and 0 < len(text) <= MAX_LOG and text.isascii()
            and text.endswith('\n'), 'invalid log framing')
    lines = text.splitlines(keepends=True)
    require(len(lines) == 2 + 3 * (len(keys) + 1), 'incomplete or extra records')
    rows = []
    for line in lines:
        require(line.endswith('\n') and len(line) <= MAX_LINE, 'invalid line framing')
        line = line[:-2] if line.endswith('\r\n') else line[:-1]
        require(not any(ord(c) < 32 and c != '\t' for c in line) and '\x7f' not in line,
                'invalid control character')
        parts = line.split('\t')
        require(parts[0] == 'PWP_EXPORT_MEMBERSHIP' and len(parts) == len(FIELDS) + 1,
                'invalid record shape')
        row = {}
        for field in parts[1:]:
            k, sep, v = field.partition('=')
            require(sep and k in FIELDS and k not in row, 'unknown or duplicate field')
            row[k] = v
        require(set(row) == FIELDS, 'missing fields')
        for k, expected in (('nonce', nonce), ('manifest_sha256', manifest_sha256),
                            ('storage', storage), ('guild', guild), ('alias', alias)):
            require(row[k] == expected, 'observation identity mismatch')
        require(all(row[k] == 'false' for k in GRANTS), 'observation cannot grant authority')
        require(row['reason'] == 'none' and row['event'] != 'failed', 'failed observation')
        row['counts'] = tuple(_count(row[k]) for k in ('confirmed', 'unresolved', 'not_examined'))
        rows.append(row)
    armed = rows[0]
    require(armed['event'] == 'armed' and armed['sample'] == '0' and armed['world_hex'] == 'none'
            and armed['key'] == armed['status'] == 'none' and armed['complete'] == 'false'
            and armed['counts'] == (0, 0, 0) and all(armed[k] == '0' for k in ADDRESSES),
            'invalid armed event')
    cursor, world, samples, addresses = 1, None, [], None

    def bind_world(row):
        nonlocal world, addresses
        encoded = row['world_hex']
        require(0 < len(encoded) <= 1024 and len(encoded) % 2 == 0
                and re.fullmatch('[0-9a-f]+', encoded), 'invalid world encoding')
        try:
            decoded = bytes.fromhex(encoded).decode('utf-8')
        except (ValueError, UnicodeDecodeError) as exc:
            raise ValueError('invalid world encoding') from exc
        require(decoded and not any(ord(c) < 32 or ord(c) == 127 for c in decoded), 'invalid world')
        if world is None:
            world = encoded
        require(encoded == world, 'late context change')
        identity = tuple(row[k] for k in ADDRESSES)
        require(all(re.fullmatch('[1-9][0-9]{0,18}', v) and int(v) <= 9223372036854775807
                    for v in identity), 'invalid native identity')
        if addresses is None:
            addresses = identity
        require(identity == addresses, 'late native identity change')

    for sample in range(1, 4):
        decisions = []
        for key in keys:
            row = rows[cursor]; cursor += 1
            bind_world(row)
            require(row['event'] == 'key' and row['sample'] == str(sample) and row['key'] == key,
                    'unexpected key or sample ordering')
            require(row['status'] in STATUSES and row['status'] != 'not_examined', 'unexamined key')
            require(row['complete'] == 'false' and row['counts'] == (0, 0, 0), 'invalid key summary')
            decisions.append(row['status'])
        row = rows[cursor]; cursor += 1
        bind_world(row)
        counts = tuple(decisions.count(status) for status in STATUSES)
        require(row['event'] == 'sample' and row['sample'] == str(sample)
                and row['key'] == row['status'] == 'none' and row['complete'] == 'true'
                and row['counts'] == counts, 'incomplete or inconsistent sample')
        samples.append(decisions)
    done = rows[cursor]
    bind_world(done)
    require(done['event'] == 'done' and done['sample'] == '3'
            and done['key'] == done['status'] == 'none' and done['complete'] == 'true'
            and done['counts'] == rows[cursor - 1]['counts'], 'invalid completion')
    confirmed = [k for i, k in enumerate(keys)
                 if all(sample[i] == 'current_target_confirmed' for sample in samples)]
    unresolved = [k for k in keys if k not in confirmed]
    return {'contract': 'PWP-EXPORT-MEMBERSHIP-ANALYSIS-1', 'observation_completed': True,
            'all_current_confirmed': bool(keys) and not unresolved,
            'nonce': nonce, 'manifest_sha256': manifest_sha256, 'storage': storage, 'guild': guild,
            'alias': alias, 'native_identity': dict(zip(ADDRESSES, addresses)),
            'source_log_sha256': hashlib.sha256(text.encode('ascii')).hexdigest(),
            'world': bytes.fromhex(world).decode('utf-8'), 'samples': 3, 'keys': keys,
            'confirmed_in_all_samples': confirmed, 'unresolved_in_any_sample': unresolved,
            'sample_statuses': samples, 'retained_history_complete': False,
            'membership_verified': False, 'migration_allowed': False,
            **{k: False for k in GRANTS}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--expected', type=Path, required=True,
                        help='Independent coverage report containing manifest_sha256/storage/guild/lookup_union')
    parser.add_argument('--nonce', required=True)
    parser.add_argument('--alias', required=True, help='Independently checked runtime guild alias')
    args = parser.parse_args()
    try:
        require(args.log.stat().st_size <= MAX_LOG, 'log too large')
        require(args.expected.stat().st_size <= MAX_LOG, 'expectations too large')
        expected = json.loads(args.expected.read_bytes())
        result = analyze(args.log.read_bytes().decode('ascii'), nonce=args.nonce,
                         manifest_sha256=expected['manifest_sha256'], storage=expected['storage'],
                         guild=expected['guild'], alias=args.alias, keys=expected['lookup_union'])
    except Exception:
        print(json.dumps({'observation_completed': False, 'error': 'invalid_membership_evidence',
                          'migration_allowed': False, **{k: False for k in GRANTS}}, sort_keys=True))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
