"""Read-only independent acceptance of the disposable typed-settings game trial."""
from pathlib import Path
import argparse
import hashlib
import json
import struct

W, G = '1' * 32, '2' * 32


def require(ok, why):
    if not ok:
        raise ValueError(why)


def payload(stream, revision):
    if stream == 'priorities':
        body = '# Pal Work Priority: palkey|worktype|priority (1 highest, 5 lowest, X disabled)\n# baseline=vanilla\n'
        body += ''.join(f'trial-pal|{i}|{v}\n' for i, v in enumerate([1, 2, 3, 4, 5, 'X', revision], 1))
    else:
        body = '# Production limits. Mining limits stop only the rocks of their item; every other limit switches its whole work type.\n'
        body += '# guild|work|item|limit (OFF hides an inherited limit for this guild)\n'
        body += f'{G}|Mining|Ore|{100 * revision}\n{G}|Mining|Stone|OFF\n'
    return f'PWP-SETTINGS-1\n{W}\n{G}\n{stream}\n{len(body.encode())}\n{body}'.encode()


def inspect(log, store, nonce, recovery_only=False):
    rows = [json.loads(line) for line in log.splitlines() if line.strip()]
    require(rows and all(r['nonce'] == nonce for r in rows), 'missing/mixed run')
    events = [r['data'] for r in rows]
    require(events[0]['event'] == 'armed' and events[0]['synthetic'] is True, 'missing arm')
    require(events[0].get('recovery_only', False) is recovery_only, 'wrong trial mode')
    require(events[-1]['event'] == 'stopped' and events[-1]['state'] == 'passed', 'trial not finished')
    require(not any(e['event'] in ('failed', 'bootstrap-failed') for e in events), 'failed trial')
    passed = [e for e in events if e['event'] == 'passed']
    require(len(passed) == 1 and passed[0]['completed'] == ['priorities', 'limits'], 'both streams required')
    require(passed[0]['synthetic'] is True and passed[0]['storage'] == W and passed[0]['guild'] == G, 'wrong scope')
    configured = [e for e in events if e['event'] == 'configured']
    require(len(configured) == 1, 'root configuration count')
    game, frequency = configured[0]['game'], configured[0]['frequency']
    workers = [e for e in events if e['event'] == 'worker']
    count = 2 if recovery_only else 8
    require(len(workers) == count and len({(e['handle'], e['ticket']) for e in workers}) == count, 'worker count/identity')
    bound = [e for e in events if e['event'] == 'bound']
    released = [e for e in events if e['event'] == 'released']
    bindings = [('priorities', True), ('limits', True)] if recovery_only else [
        ('priorities', False), ('priorities', True), ('limits', False), ('limits', True)]
    require([(e['stream'], e['reopening']) for e in bound] == bindings, 'binding sequence')
    require(len({e['handle'] for e in bound}) == len(bindings), 'reused binding')
    require([(e['stream'], e['handle']) for e in released] ==
            [(e['stream'], e['handle']) for e in bound], 'owner release identities')
    for binding in bound:
        actual = [(e['stream'], e['ticket']) for e in workers if e['handle'] == binding['handle']]
        tickets = [1] if binding['reopening'] else [1, 2, 3]
        require(actual == [(binding['stream'], t) for t in tickets], 'operation sequence')
    for e in workers:
        require(e['game'] == game and e['worker'] > 0 and e['worker'] != game, 'worker route')
        require(e['frequency'] == frequency and frequency > 0 and 0 <= e['start'] <= e['finish'], 'native timing')
    expected, hashes = set(), {}
    store = Path(store)
    for stream in ('priorities', 'limits'):
        scope = f'PWP-SCOPE-1:{W}:{G}:{stream}'.encode()
        for slot, generation, revision in [('A', 1, 1), ('B', 2, 3)]:
            name = f'pwp-record-v1-{W}-{G}-{stream}-{slot}.record'
            expected.add(name)
            p = store / name
            require(p.is_file() and not p.is_symlink(), 'missing/redirected record')
            data = p.read_bytes()
            body = payload(stream, revision)
            envelope = b'PWPJNL1\n' + struct.pack('<HII', len(scope), generation, len(body)) + scope + body
            require(data == envelope + hashlib.sha256(envelope).digest(), 'record bytes/schema/hash mismatch: ' + name)
            hashes[name] = hashlib.sha256(data).hexdigest()
    require({p.name for p in store.iterdir()} == expected, 'unexpected files or missing pair')
    return {'passed': True, 'synthetic_only': True, 'recovery_only': recovery_only, 'records': hashes, 'workers': workers,
            'production_async_enabled': False, 'power_loss_verified': False}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('log', type=Path)
    parser.add_argument('store', type=Path)
    parser.add_argument('nonce')
    parser.add_argument('--recovery', action='store_true')
    args = parser.parse_args()
    print(json.dumps(inspect(args.log.read_text(), args.store, args.nonce, args.recovery), indent=2))


if __name__ == '__main__':
    main()
