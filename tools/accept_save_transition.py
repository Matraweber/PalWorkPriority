"""Strict acceptance of archived reverse identity evidence; never authorizes IO.

Unlike capture scripts, exit zero means all observation gates passed. This
validates the archive, not current installation state or production save safety.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import re

GAME = 'World /Game/Pal/Maps/MainWorld_5/PL_MainWorld5.PL_MainWorld5'
TITLE = 'World /Game/Pal/Maps/Title/PL_Title.PL_Title'
GUID = re.compile(r'[0-9a-f]{32}')


def require(value, message):
    if not value:
        raise ValueError(message)


def validate(log, nonce, before, after):
    require(before == after and type(before.get('Id')) is int and before['Id'] > 0
            and before.get('StartTime'), 'process identity missing or changed')
    start = datetime.fromisoformat(before['StartTime'])
    require(start.tzinfo is not None, 'process timestamp must include timezone')
    require(re.fullmatch(r'[A-Za-z0-9-]{1,64}', nonce), 'invalid nonce')
    prefix = ' PWP world reverse ' + nonce + ' '
    rows = []
    for line in log.splitlines():
        if prefix not in line:
            continue
        stamp, message = line.split(prefix, 1)
        require(re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', stamp), 'invalid UTC timestamp')
        moment = datetime.fromisoformat(stamp.replace('Z', '+00:00'))
        require(moment >= start, 'evidence predates process')
        require(not rows or moment >= rows[-1][0], 'timestamps reversed')
        rows.append((moment, message))
    require(rows and rows[0][1].startswith('ARM_CONSUMED '), 'missing arm event')
    phase, sample, sample_at, client, host = 0, None, None, None, None
    for index, (moment, message) in enumerate(rows):
        require('verified=true' not in message, 'probe improperly grants verification')
        require(not message.startswith(('FAIL ', 'TIMEOUT ', 'UNSUPPORTED ', 'SLOW_READ ',
                                        'TIMER_UNAVAILABLE')), 'failed/incomplete trial')
        if message.startswith('ARM_CONSUMED '):
            require(index == 0, 'multiple runs under same nonce')
        elif message.startswith('SAMPLE '):
            sample = dict(part.split('=', 1) for part in message[7:].split(' | '))
            sample_at = moment
            require(sample.get('verified') == 'false', 'missing unverified marker')
        elif message.startswith('CLIENT_OBSERVED '):
            require(phase == 0, 'client phase out of order')
            check_sample(sample, False)
            require((moment - sample_at).total_seconds() >= 10, 'client dwell missing')
            client = sample['directory']
            require(message == f'CLIENT_OBSERVED directory={client} verified=false', 'client mismatch')
            phase = 1
        elif message == 'TITLE_BOUNDARY verified=false':
            require(phase == 1 and sample and sample.get('world') == TITLE
                    and sample.get('instance_world') == TITLE
                    and sample.get('instance_loaded_status') == 'read'
                    and sample.get('instance_loaded_world') == 'false', 'invalid Title boundary')
            phase = 2
        elif message.startswith('HOST_OBSERVED '):
            require(phase == 2, 'host phase out of order')
            check_sample(sample, True)
            require((moment - sample_at).total_seconds() >= 10, 'host dwell missing')
            host = sample['directory']
            require(host != client and sample.get('instance_selected_status') == 'format_valid'
                    and sample.get('instance_selected') == host, 'wrong final identity')
            require(message == f'HOST_OBSERVED directory={host} differs_from_client=true '
                    'selected_matches_host=true verified=false', 'host comparison mismatch')
            phase = 3
        elif message.startswith('TRANSITION_COMPLETE '):
            require(phase == 3 and index == len(rows)-1, 'premature/nonterminal completion')
            match = re.fullmatch(r'TRANSITION_COMPLETE observations only samples=(\d+) timer_cancelled=true', message)
            require(match and 1 <= int(match[1]) <= 600, 'bad completion or uncancelled timer')
            phase = 4
        else:
            raise ValueError('unexpected event: ' + message)
    require(phase == 4, 'no successful completion')
    require((rows[-1][0]-rows[0][0]).total_seconds() <= 600, 'trial exceeded bound')
    return {'observation_passed': True, 'identity_verified': False,
            'async_enable_authorized': False, 'pid': before['Id']}


def check_sample(s, host):
    require(s and s.get('status') == 'observed' and s.get('world') == GAME
            and s.get('instance_world') == GAME and s.get('directory_status') == 'format_valid'
            and GUID.fullmatch(s.get('directory', '')) and s['directory'] != '0'*32
            and s.get('role_status') == 'read' and s.get('dedicated_status') == 'read'
            and s.get('instance_loaded_status') == 'read', 'unreadable gameplay identity')
    require(s.get('role') in (('3',) if host else ('1', '2'))
            and s.get('dedicated') == ('false' if host else 'true')
            and s.get('instance_loaded_world') == ('true' if host else 'false'), 'role/load mismatch')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('archive', type=Path)
    args = p.parse_args()
    def read(name):
        return json.loads((args.archive/name).read_text(encoding='utf-8-sig'))
    try:
        receipt = read('acceptance.json')
        for field in ('production_unchanged', 'source_hashes_match', 'arm_disabled', 'timer_cancelled'):
            require(receipt.get(field) is True, 'unchecked installation gate: '+field)
        result = validate((args.archive/'world-reverse-final.log').read_text(),
                          read('installation.json')['nonce'], read('process-before.json'), read('process-after.json'))
    except (ValueError, OSError, KeyError, TypeError) as exc:
        print('FAIL:', exc)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
