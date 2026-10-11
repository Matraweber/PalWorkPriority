"""Independent full-byte validation of disposable explicit native drain trial."""
import hashlib
import json
import struct
from pathlib import Path
from accept_native_settings_trial import payload, require, W, G
from install_native_draining_trial import RUNTIME, PROBE, EVIDENCE, digest


def inspect(log, directory, nonce):
    rows = [json.loads(line) for line in log.splitlines() if line.strip()]
    require(rows and all(r['nonce'] == nonce for r in rows), 'wrong/missing nonce')
    events = [r['data'] for r in rows if r['data']['event'] != 'exit-observation']
    require(events[0]['event'] == 'armed' and events[0]['synthetic'] is True, 'missing arm')
    require(events[-1]['event'] == 'stopped' and events[-1]['state'] == 'passed', 'not completed')
    require(not any(e['event'] in ('failed', 'bootstrap-failed') for e in events), 'trial failed')
    passed = [e for e in events if e['event'] == 'passed']
    require(len(passed) == 1 and passed[0]['completed'] == ['priorities', 'limits']
            and passed[0]['shutdown_route_verified'] is False, 'wrong completion')
    config = [e for e in events if e['event'] == 'configured']
    require(len(config) == 1 and config[0]['game'] > 0 and config[0]['frequency'] > 0, 'configuration')
    calls = [e for e in events if e['event'] == 'call']
    for e in calls:
        require(e['thread'] == config[0]['game'] and e['frequency'] == config[0]['frequency']
                and 0 <= e['start'] <= e['finish'] and e['status'] in (1, 2), 'call route/timing/refusal')
    require([e['command'] for e in calls if e['command'] != 3] ==
            [1, 2, 4, 5, 5, 5, 8, 9, 1, 2, 8, 9] * 2, 'unexpected mutations')
    active, awaiting_bind, next_ticket, last_command = None, False, 0, None
    for e in events:
        if e['event'] == 'call':
            command = e['command']
            if command == 1:
                require(active is None and not awaiting_bind and e['handle'] == 1
                        and e['ticket'] == 0 and e['status'] == 1, 'bad root binding call')
                awaiting_bind = True
            else:
                require(active is not None and not awaiting_bind and e['handle'] == active, 'wrong operation handle')
                if command in (2, 4, 5, 8):
                    next_ticket += 1
                    require(e['ticket'] == next_ticket and e['status'] == 1, 'failed/replayed/skipped mutation')
                else:
                    require(command in (3, 9) and e['ticket'] == 0, 'invalid read/cleanup ticket')
                    require(command == 3 or e['status'] == 1, 'cleanup not completed')
            last_command = command
        elif e['event'] == 'bound':
            require(awaiting_bind and active is None and last_command == 1, 'unmatched binding')
            active, awaiting_bind, next_ticket = e['handle'], False, 0
        elif e['event'] == 'released':
            require(active == e['handle'] and last_command == 9, 'unmatched release')
            active = None
    require(active is None and not awaiting_bind, 'owner left unresolved')
    bound = [e for e in events if e['event'] == 'bound']
    require([(e['stream'], e['reopening']) for e in bound] ==
            [('priorities', False), ('priorities', True), ('limits', False), ('limits', True)], 'binding order')
    require(len({e['handle'] for e in bound}) == 4, 'reused handle')
    require([(e['stream'], e['handle']) for e in events if e['event'] == 'released'] ==
            [(e['stream'], e['handle']) for e in bound], 'missing releases')
    drained = [e for e in events if e['event'] == 'drained']
    require([e['stream'] for e in drained] == ['priorities', 'limits'], 'both drains required')
    expected, hashes = set(), {}
    for e in drained:
        stream, gen = e['stream'], e['generation']
        require(e['accepted'] == e['committed'] == 3 and gen in (2, 3) and e['cleanup_error'] == '0', 'drain incomplete')
        slots = [('A', 1, 1), ('B', 2, 3)] if gen == 2 else [('A', 3, 3), ('B', 2, 2)]
        scope = f'PWP-SCOPE-1:{W}:{G}:{stream}'.encode()
        reports = [s for s in events if s['event'] == 'slot' and s['stream'] == stream]
        require(len(reports) == 2, 'missing recovered slots')
        for slot, generation, revision in slots:
            name = f'pwp-record-v1-{W}-{G}-{stream}-{slot}.record';expected.add(name)
            body = payload(stream, revision)
            envelope = b'PWPJNL1\n' + struct.pack('<HII', len(scope), generation, len(body)) + scope + body
            record = Path(directory) / name
            require(record.is_file() and not record.is_symlink(), 'missing/redirected record')
            actual = record.read_bytes()
            require(actual == envelope + hashlib.sha256(envelope).digest(), 'wrong complete record bytes')
            require(sum(s['slot'] == slot and s['generation'] == generation and s['payload'].encode() == body
                        for s in reports) == 1, 'recovered slot disagrees')
            hashes[name] = hashlib.sha256(actual).hexdigest()
    require({p.name for p in Path(directory).iterdir()} == expected, 'unexpected files')
    return dict(passed=True, synthetic=True, explicit_drain=True, records=hashes,
                shutdown_route_verified=False, worker_thread_independently_observed=False)


def main():
    manifest = json.loads((EVIDENCE / 'install.json').read_text())
    log = (PROBE / 'Scripts/drain-trial.jsonl').read_bytes()
    receipt = inspect(log.decode(), EVIDENCE / 'store', manifest['nonce'])
    require({n: digest(PROBE / 'Scripts' / n) for n in manifest['installed']} == manifest['installed'], 'installed files changed')
    production = RUNTIME / 'Mods/PalWorkPriority'
    after = {str(p.relative_to(production)): digest(p) for p in production.rglob('*')
             if p.is_file() and (p.suffix == '.lua' or (p.parent == production and p.suffix == '.txt'))}
    require(after == manifest['production_before'], 'production/settings changed')
    require((PROBE / 'Scripts/run.txt').read_text().strip() == 'DISABLED', 'marker not disarmed')
    receipt.update(nonce=manifest['nonce'], production_unchanged=True)
    (EVIDENCE / 'drain-trial.jsonl').write_bytes(log)
    (EVIDENCE / 'receipt.json').write_text(json.dumps(receipt, indent=2))
    (PROBE / 'enabled.txt').rename(PROBE / 'enabled.txt.disabled')
    print(json.dumps(receipt))


if __name__ == '__main__':
    main()
