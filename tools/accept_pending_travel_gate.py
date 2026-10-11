"""Accept native hold evidence only; not proof of UE travel or durable recovery."""
from pathlib import Path
import argparse
import json


def accept(text, scopes):
    def require(ok, why):
        if not ok:
            raise ValueError(why)
    require(len(scopes) == 2 and len(set(scopes)) == 2, 'two distinct expected scopes required')
    rows = []
    for line in text.splitlines():
        parts = line.split('\t')
        require(len(parts) == 10 and parts[0] == 'PWP_DEV_PENDING_1', 'record shape')
        fields = dict(p.split('=', 1) for p in parts[4:])
        require(set(fields) == {'worker', 'caller', 'accepted', 'committed', 'parked', 'timeout'}, 'record fields')
        require(all(v.isascii() and v.isdigit() for v in fields.values()), 'integer fields')
        row = {k: int(v) for k, v in fields.items()}
        require(parts[1].isascii() and parts[1].isdigit(), 'timestamp')
        row.update(time=int(parts[1]), event=parts[2], scope=parts[3])
        require(row['time'] > 0 and row['worker'] > 0 and row['caller'] > 0, 'invalid identity/time')
        require(row['scope'] in scopes and row['timeout'] == 0 and row['parked'] == 1, 'timeout or unheld worker')
        rows.append(row)
    require(len(rows) == 6, 'exactly three events for each stream required')
    joins, parks, workers, callers = [], [], set(), set()
    for scope in scopes:
        events = [r for r in rows if r['scope'] == scope]
        require([r['event'] for r in events] == ['park', 'join', 'release_join'], 'hold/join/release order')
        park, join, release = events
        require(park['time'] <= join['time'] <= release['time'], 'non-monotonic stream evidence')
        require(release['time'] - park['time'] <= 60000 * 10000, 'hold exceeded bound')
        require(park['worker'] == join['worker'] == release['worker'], 'worker changed')
        require(park['caller'] == release['caller'] == park['worker'] != join['caller'], 'worker/control thread mismatch')
        require(park['accepted'] > park['committed'] and join['accepted'] > join['committed'], 'not pending at join')
        require(join['committed'] == park['committed'] and join['accepted'] >= park['accepted'], 'publication before join')
        workers.add(park['worker']); callers.add(join['caller'])
        parks.append(park['time']); joins.append(join['time'])
    require(len(workers) == 2 and len(callers) == 1 and not workers.intersection(callers), 'two workers and one control thread required')
    require(max(parks) <= min(joins), 'both workers must be parked before first join')
    return dict(native_pending_at_both_joins=True, timeouts=0, streams=list(scopes),
                live_travel_verified=False, durable_recovery_verified=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('evidence', type=Path)
    parser.add_argument('--scope', action='append', required=True)
    args = parser.parse_args()
    print(json.dumps(accept(args.evidence.read_text(), args.scope), indent=2))


if __name__ == '__main__':
    main()
