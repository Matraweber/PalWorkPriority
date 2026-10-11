"""Accept only a complete isolated registry travel trial; not production approval."""
from datetime import datetime
import argparse
import json
from pathlib import Path
import re

EVENTS = (
    'ARM_CONSUMED synthetic_registry_only=1 disk_io=0 no_game_gc=1',
    'REGISTRY_GUARDS_PASS same_class=refused cross_class=refused distinct_scope=allowed disk_io=0',
    'PENDING_TRAVEL from=World /Game/Pal/Maps/Splash/PL_PPSplash.PL_PPSplash scope_one=terminal_101 scope_two=busy_201',
    'REGISTRY_TRAVEL_DRAIN_PASS terminal_and_busy_retained=1 stale_owner_refused=1 disk_io=0',
    'PASS_WORLD_TRANSITION from=World /Game/Pal/Maps/Splash/PL_PPSplash.PL_PPSplash to=World /Game/Pal/Maps/MainWorld_5/PL_MainWorld5.PL_MainWorld5 synthetic_registry_only=1 rooted_objects_retained_until_exit=1 timer_cancelled=true',
)


def validate(log, nonce, before, after, *, version=1):
    def require(ok, reason):
        if not ok:
            raise ValueError(reason)
    require(type(version) is int and version in (1, 2), 'unsupported registry version')
    require(before == after and type(before.get('Id')) is int and before['Id'] > 0,
            'missing or changed process identity')
    started = datetime.fromisoformat(before['StartTime'])
    require(started.tzinfo is not None, 'process start must have timezone')
    require(re.fullmatch(r'[A-Za-z0-9-]{1,64}', nonce), 'invalid nonce')
    prefix = f' PWP registry V{version} ' + nonce + ' '
    rows = []
    for line in log.splitlines():
        if prefix not in line:
            continue
        stamp, event = line.split(prefix, 1)
        require(re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', stamp), 'bad timestamp')
        moment = datetime.fromisoformat(stamp.replace('Z', '+00:00'))
        require(moment >= started, 'log predates process')
        require(not rows or moment >= rows[-1][0], 'reversed timestamps')
        rows.append((moment, event))
    expected = EVENTS if version == 1 else EVENTS[:1] + (
        'REGISTRY_CAPACITY_PASS retained_scopes=32 overflow_refused=1',) + EVENTS[1:]
    require(tuple(event for _, event in rows) == expected, 'missing, reordered, failed or duplicate events')
    require(0 < (rows[-1][0] - rows[0][0]).total_seconds() <= 420, 'invalid travel duration')
    return {'registry_fixture_passed': True, 'registry_version': version, 'production_registry_integrated': False,
            'async_enable_authorized': False, 'pid': before['Id'], 'nonce': nonce}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--version', type=int, choices=(1, 2), default=1)
    args = parser.parse_args()
    try:
        install = json.loads((args.archive / 'installation.json').read_text())
        process = json.loads((args.archive / 'process.json').read_text())
        result = validate((args.archive / 'registry-final.log').read_text(), install['nonce'],
                          process['before'], process['after'], version=args.version)
    except (ValueError, KeyError, OSError, TypeError) as exc:
        print(json.dumps({'registry_fixture_passed': False, 'error': str(exc)}))
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
