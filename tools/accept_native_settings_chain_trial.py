"""Independent full-chain trial proof checker. No installation or game controls.

inspect is read-only. CLI writes an evidence copy/receipt only after all checks.
Process identity and exit chronology remain separately observed evidence.
"""
import argparse
import hashlib
import json
import re
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path('D:/Steam/steamapps/common/Palworld/Mods/NativeMods/UE4SS')
STORE = ROOT / 'test-results/native-draining-live-20261004/store'
WRITE_EVIDENCE = ROOT / 'test-results/native-settings-chain-live-20261004'
RECOVERY_EVIDENCE = ROOT / 'test-results/native-settings-chain-recovery-20261004'
W, G = '7' * 32, '8' * 32
STREAMS = ('priorities', 'limits')


def require(ok, why):
    if not ok:
        raise ValueError(why)


def integer(n, minimum=0, maximum=2147483646):
    return type(n) is int and minimum <= n <= maximum


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def record_name(world, guild, stream, slot):
    return f'pwp-record-v1-{world}-{guild}-{stream}-{slot}.record'


def body(stream, revision):
    require(stream in STREAMS and integer(revision, 1, 5), 'fixture identity')
    if stream == 'priorities':
        text = '# Pal Work Priority: palkey|worktype|priority (1 highest, 5 lowest, X disabled)\n# baseline=vanilla\n'
        text += ''.join(f'trial-pal|{i}|{v}\n' for i, v in enumerate([1, 2, 3, 4, 5, 'X', revision], 1))
    else:
        text = '# Production limits. Mining limits stop only the rocks of their item; every other limit switches its whole work type.\n'
        text += '# guild|work|item|limit (OFF hides an inherited limit for this guild)\n'
        text += f'{G}|Mining|Ore|{100 * revision}\n{G}|Mining|Stone|OFF\n'
    return text.encode()


def payload(stream, revision):
    raw = body(stream, revision)
    return f'PWP-SETTINGS-1\n{W}\n{G}\n{stream}\n{len(raw)}\n'.encode() + raw


def prior_names():
    names = {record_name(w * 32, g * 32, s, a)
             for w, g in (('1', '2'), ('5', '6')) for s in STREAMS for a in ('A', 'B')}
    names.update(record_name('3'*32, '4'*32, s, a)
                 for s, a in (('priorities', 'A'), ('priorities', 'B'), ('limits', 'A')))
    return names


def inspect_records(directory, prior_records, write_records=None):
    """Check exact named prior hashes and independently decode/re-encode new records."""
    directory = Path(directory)
    require(type(prior_records) is dict and set(prior_records) == prior_names(), 'exact eleven prior records required')
    require(all(type(h) is str and re.fullmatch('[0-9a-f]{64}', h) for h in prior_records.values()), 'invalid prior digest')
    require(directory.is_dir() and not directory.is_symlink(), 'missing/redirected store')
    for name, expected in prior_records.items():
        p = directory/name
        require(p.is_file() and not p.is_symlink() and digest(p) == expected, 'prior record changed/missing')
    hashes, records = {}, {}
    for stream in STREAMS:
        records[stream] = {}
        scope = f'PWP-SCOPE-1:{W}:{G}:{stream}'.encode()
        for slot in ('A', 'B'):
            name = record_name(W, G, stream, slot);p = directory/name
            require(p.is_file() and not p.is_symlink(), 'missing/redirected new record')
            raw = p.read_bytes()
            require(50 <= len(raw) <= 262450, 'record size')
            magic, sn, gen, pn = struct.unpack_from('<8sHII', raw)
            require(magic == b'PWPJNL1\n' and sn == len(scope) and raw[18:18+sn] == scope, 'record header/scope')
            require(len(raw) == 18+sn+pn+32 and 1 <= gen <= 5, 'record length/generation')
            require(gen % 2 == (slot == 'A'), 'wrong physical slot parity')
            data = raw[18+sn:-32]
            revisions = [r for r in range(1, 6) if data == payload(stream, r)]
            require(len(revisions) == 1, 'wrong exact typed bytes')
            rev = revisions[0]
            envelope = b'PWPJNL1\n'+struct.pack('<HII', len(scope), gen, len(data))+scope+data
            require(raw == envelope+hashlib.sha256(envelope).digest(), 'record SHA/bytes')
            hashes[name] = hashlib.sha256(raw).hexdigest()
            records[stream][slot] = dict(generation=gen, revision=rev, payload=data)
        older, newest = sorted(records[stream].values(), key=lambda r: r['generation'])
        require(newest['generation'] == older['generation']+1 and newest['revision'] == 5
                and 1 <= older['revision'] < 5 and newest['generation'] >= 3, 'invalid final generation pair')
    require({p.name for p in directory.iterdir()} == set(hashes) | prior_names(), 'unexpected store files')
    if write_records is not None:
        require(type(write_records) is dict and write_records == hashes, 'recovery changed write records')
    return hashes, records


def inspect(log, directory, nonce, prior_records, recovery_only=False, write_records=None):
    """Validate native wire evidence, writer claims and final disk independently."""
    require(type(recovery_only) is bool, 'mode must be explicit boolean')
    require(type(nonce) is str and re.fullmatch('[A-Za-z0-9_-]{1,64}', nonce), 'nonce')
    require(not recovery_only or type(write_records) is dict, 'recovery requires write-record hashes')
    hashes, disk = inspect_records(directory, prior_records, write_records if recovery_only else None)
    mode = 'recovery' if recovery_only else 'write'

    def unique(pairs):
        result = {}
        for k, v in pairs:
            require(k not in result, 'duplicate JSON key');result[k] = v
        return result

    rows = [json.loads(line, object_pairs_hook=unique) for line in log.splitlines() if line.strip()]
    require(rows and all(type(r) is dict and r.get('nonce') == nonce for r in rows), 'missing/mixed nonce')
    events = [r['data'] for r in rows]
    require(all(type(e) is dict for e in events), 'invalid event')

    def equal(e, **expected):
        require(all(type(e.get(k)) is type(v) and e[k] == v for k, v in expected.items()), 'event claim mismatch')

    equal(events[0], event='armed', synthetic=True, recovery_only=recovery_only, exit_hook_installed=True)
    require(len(events) >= 4, 'incomplete proof')
    equal(events[1], event='configured')
    game, frequency = events[1]['game'], events[1]['frequency']
    require(integer(game, 1, 4294967295) and integer(frequency, 1, 2**63-1), 'configuration')
    owners, handles, calls = {}, {}, {}
    sequence, last_finish = 0, 0
    ready, quit, passed, stopped = False, False, False, False
    preflight, drain_durations = [], {}

    def decimal(s):
        require(type(s) is str and re.fullmatch('0|[1-9][0-9]*', s) and int(s) <= 2147483646, 'native decimal')
        return int(s)

    def fields(value):
        if value == {}:
            value = []
        require(type(value) is list and all(type(x) is str for x in value), 'wire field array')
        return value

    def check_status(b, f, command):
        require(len(f) == 16 and f[:3] == [b['scope'], b['incarnation'], '1'], 'status identity')
        a, c, g = decimal(f[3]), decimal(f[4]), decimal(f[7])
        require(a == b['accepted'] and b['committed'] <= c <= a and g >= b['generation'], 'native counters')
        require(f[6] == 'none' and f[8] == '0', 'native/cleanup failure')
        require(f[12:] == [str(b['ticket']), str(b['command']), str(b['last_revision']),
                           'accepted' if b['ticket'] else 'none'], 'native ticket receipt')
        if not b['started']:
            require(f[5] == 'dormant' and (a, c, g) == (0, 0, 0) and f[9:12] == ['', '', ''], 'virgin owner required')
        else:
            require(f[5] in ('recovering', 'awaiting_validation', 'ready', 'closing', 'closed'), 'native phase')
            if f[9] == '':
                require(f[5] == 'recovering' and (a, c, g) == (0, 0, 0) and f[10:12] == ['', ''], 'empty terminal')
            else:
                require(f[9] in ('recovered', 'initialized', 'updated') and f[10:12] == ['1', '0'], 'uncertain/unpublished terminal')
            if b['approved']:
                require(f[5] in (('closing', 'closed') if b['close_issued'] else ('ready',)), 'approved owner phase')
            else:
                require(f[5] in ('recovering', 'awaiting_validation') and a == c == 0, 'unapproved owner mutated')
            if recovery_only:
                expected_gen = max(r['generation'] for r in disk[b['stream']].values())
                require(a == c == 0 and (g == expected_gen or f[5] == 'recovering' and g == 0), 'recovery counters')
                require(f[9] in ('', 'recovered'), 'recovery published a mutation')
            else:
                require(g <= c and (c == 0 or g >= (1 if c == 1 else 2)), 'physical/logical bounds')
                if c > 0:
                    require(f[9] in ('initialized', 'updated'), 'commit without publication')
                if f[9] == 'initialized':
                    require(c <= 1 and g <= 1, 'initial snapshot coalesced away')
                if c == b['committed']:
                    require(g == b['generation'], 'physical advance without commit')
                else:
                    require(g > b['generation'], 'commit without physical advance')
            if f[5] == 'closed':
                require(b['close_issued'] and a == c, 'premature close')
        if command == 8:
            require(f[5] == 'closed' and a == c == (0 if recovery_only else 5), 'incomplete drain')
        b['committed'], b['generation'], b['phase'] = c, g, f[5]
        b['last_status'] = sequence

    for e in events[2:]:
        kind = e.get('event')
        require(not stopped and (not passed or kind == 'stopped'), 'events after completion')
        if kind == 'stopped':
            require(passed, 'stopped before completion')
            equal(e, state='passed', phase='complete');stopped = True;continue
        equal(e, mode=mode)
        require(kind in ('call', 'bound', 'initialized', 'recovered', 'submitted', 'saved', 'ready',
                         'quit_preflight', 'closed', 'drained', 'passed'), 'failure/unknown event')
        if kind == 'call':
            sequence += 1
            equal(e, sequence=sequence, count=6, thread=game, frequency=frequency,
                  threw=False, decode_error=False, diagnostic=False)
            require(integer(e['start'], 0, 2**63-1) and integer(e['finish'], e['start'], 2**63-1)
                    and e['start'] >= last_finish, 'call clock reversed')
            last_finish = e['finish']
            cmd, h, ticket = e['command'], e['handle'], e['ticket']
            require(integer(cmd, 1, 9) and integer(h, 1, 128) and integer(ticket), 'command identity')
            require(type(e['status']) is int and (e['status'] == 1 or cmd == 3 and e['status'] == 2), 'native refusal')
            args, out = fields(e['fields']), fields(e['result_fields'])
            stream = e['stream'];require(stream in STREAMS, 'unknown stream')
            if cmd == 1:
                require(not ready and not quit and stream not in owners and len(owners) < 2, 'extra binding')
                require(stream == STREAMS[len(owners)], 'binding order')
                require(h == 1 and ticket == 0 and args == [W, G, stream, nonce+'-'+stream, '1'] and len(out) == 1, 'bind wire')
                handle = decimal(out[0]);require(1 <= handle <= 128 and handle not in handles, 'handle reuse')
                b = dict(stream=stream, handle=handle, scope=f'PWP-SCOPE-1:{W}:{G}:{stream}', incarnation=nonce+'-'+stream,
                         ticket=0, command=0, last_revision=0, accepted=0, committed=0, generation=0,
                         bound=False, started=False, approved=False, recovery_read=False, initialized=False,
                         recovered=False, submitted=[], saved=False, close_issued=False, closed=False,
                         native_drained=False, cleaned=False, drained=False, last_status=None, phase='dormant')
                owners[stream] = b;handles[handle] = b
            else:
                require(h in handles and handles[h]['stream'] == stream, 'wrong operation handle')
                b = handles[h];require(b['bound'] and not b['cleaned'], 'unbound/released owner used')
                require(len(args) == (1 if cmd in (4, 5) else 0), 'unexpected inputs')
                if cmd in (2, 4, 5, 7, 8):
                    require(ticket == b['ticket']+1 and e['status'] == 1, 'replayed/skipped mutation')
                    b['ticket'], b['command'], b['last_revision'] = ticket, cmd, 0
                else:
                    require(ticket == 0, 'read/cleanup ticket')
                if cmd == 2:
                    require(not b['started'] and b['last_status'] is not None and b['phase'] == 'dormant', 'recovery start')
                    b['started'] = True
                elif cmd == 3:
                    require(b['started'] and not b['approved'] and not b['recovery_read'], 'recovery peek order')
                    if e['status'] == 1:
                        require(len(out) == 16 and out[:5] == [b['scope'], b['incarnation'], '1', 'recovered', '1']
                                and out[6] == '0' and out[7] and out[8:10] == ['0', '0'], 'recovery proof')
                        if recovery_only:
                            for offset, slot in ((10, 'A'), (13, 'B')):
                                r = disk[stream][slot]
                                require(out[offset:offset+3] == ['valid', str(r['generation']), r['payload'].decode()], 'recovered slots disagree with disk')
                            require(decimal(out[5]) == max(r['generation'] for r in disk[stream].values()), 'recovered generation')
                        else:
                            require(out[5] == '0' and out[10:] == ['missing', '0', '', 'missing', '0', ''], 'not positive missing')
                        b['recovery_read'] = True
                elif cmd == 4:
                    require(b['recovery_read'] and not b['approved'] and args == ['existing' if recovery_only else 'initialize_missing'], 'approval')
                    b['approved'] = True
                elif cmd == 5:
                    rev = b['accepted']+1
                    require(not recovery_only and b['approved'] and not b['close_issued'] and rev <= 5, 'forbidden submit')
                    require((rev == 1 and not b['initialized']) or (rev in (2, 3) and b['recovered'] and not ready)
                            or (rev in (4, 5) and quit), 'submission phase')
                    require(args == [payload(stream, rev).decode()] and out == [str(rev)], 'submission bytes/revision')
                    equal(e, payload_revision=rev)
                    b['accepted'], b['last_revision'] = rev, rev
                elif cmd == 7:
                    require(not b['close_issued'] and all(x['saved'] for x in owners.values())
                            and len(owners) == 2 and (recovery_only or quit and all(x['submitted'] == [2, 3, 4, 5] for x in owners.values())), 'early/repeated close')
                    b['close_issued'] = True
                elif cmd == 8:
                    require(b['close_issued'] and all(x['closed'] for x in owners.values()) and not b['native_drained'], 'early/repeated drain')
                    b['native_drained'] = True
                    drain_durations[stream] = (e['finish']-e['start'])*1000/frequency
                elif cmd == 9:
                    require(b['native_drained'], 'cleanup before positive drain');b['cleaned'] = True
                if cmd in (6, 8):
                    check_status(b, out, cmd)
                elif cmd not in (3, 5):
                    require(out == [], 'unexpected mutation/cleanup output')
                if e['status'] == 2:
                    require(out == [], 'pending data')
                if ready and not quit:
                    require(cmd == 6 and stream not in preflight, 'unexpected ready operation')
                    require(b['accepted'] == b['committed'] == 3 and b['phase'] == 'ready', 'quit preflight counters')
                    preflight.append(stream)
            calls[sequence] = e
            continue
        if kind in ('ready', 'quit_preflight', 'passed'):
            require(len(owners) == 2, 'both owners required')
            if kind == 'ready':
                require(not recovery_only and not ready and all(b['saved'] for b in owners.values()), 'premature/duplicate ready')
                equal(e, revision=3);ready = True
            elif kind == 'quit_preflight':
                require(not recovery_only and ready and not quit and preflight == list(STREAMS), 'quit before both preflights')
                equal(e, code=4, reason=4, thread=game, game_thread=game);quit = True
            else:
                require(all(b['drained'] for b in owners.values()) and (recovery_only or quit), 'premature passed')
                equal(e, synthetic=True, explicit_drain=True, storage=W, guild=G, boot=nonce, completed=list(STREAMS));passed = True
            continue
        stream = e.get('stream');require(stream in owners, 'claim without owner');b = owners[stream]
        if kind == 'bound':
            require(not b['bound'] and calls[sequence]['command'] == 1, 'unmatched binding')
            equal(e, handle=b['handle'], scope=b['scope'], incarnation=b['incarnation'], session=b['incarnation'], epoch=1, boot=nonce)
            b['bound'] = True
        elif kind == 'initialized':
            require(not recovery_only and not b['initialized'] and b['accepted'] == 1, 'initial admission claim')
            equal(e, revision=1);b['initialized'] = True  # admission only; never a durable claim
        elif kind == 'recovered':
            require(not b['recovered'] and b['approved'] and (recovery_only or b['initialized'] and b['committed'] == 1), 'premature activation')
            r = 5 if recovery_only else 1
            equal(e, revision=0 if recovery_only else 1, body=body(stream, r).decode(), payload=payload(stream, r).decode());b['recovered'] = True
        elif kind == 'submitted':
            r = 2+len(b['submitted'])
            require(not recovery_only and b['recovered'] and r <= 5 and b['accepted'] == r, 'unmatched writer submission')
            equal(e, revision=r, state='pending', body=body(stream, r).decode(), payload=payload(stream, r).decode());b['submitted'].append(r)
        elif kind == 'saved':
            r, fixture = (0, 5) if recovery_only else (3, 3)
            require(b['recovered'] and not b['saved'] and b['accepted'] == b['committed'] == r
                    and b['phase'] == 'ready' and (recovery_only or b['submitted'] == [2, 3]), 'false saved claim')
            equal(e, revision=r, state='saved', accepted=r, committed=r, generation=b['generation'],
                  native_sequence=b['last_status'], body=body(stream, fixture).decode(), payload=payload(stream, fixture).decode())
            require(calls[e['native_sequence']]['command'] == 6, 'saved without status6')
            b['saved'], b['saved_generation'] = True, b['generation']
        elif kind == 'closed':
            require(b['close_issued'] and not b['closed'], 'unmatched close');b['closed'] = True
        elif kind == 'drained':
            require(b['cleaned'] and not b['drained'], 'drain/cleanup incomplete')
            equal(e, accepted=b['accepted'], committed=b['committed'], generation=b['generation'], phase='closed',
                  cleanup_error=0, cleaned=True, native_sequence=b['last_status'])
            require(calls[e['native_sequence']]['command'] == 8, 'drained without native drain receipt')
            b['drained'] = True
    require(passed and stopped and len(owners) == 2, 'incomplete trial')
    for stream, b in owners.items():
        older, latest = sorted(disk[stream].values(), key=lambda r: r['generation'])
        require(b['generation'] == latest['generation'], 'native/disk generation mismatch')
        if not recovery_only:
            base = b['saved_generation'];delta = latest['generation']-base
            require(base in (2, 3) and delta in (1, 2) and older['revision'] == (3 if delta == 1 else 4), 'disk contradicts durable pre-Quit revision3')
    return dict(passed=True, mode=mode, synthetic=True, explicit_drain=True, records=hashes,
                prior_records=dict(prior_records), prior_records_unchanged=True, drain_ms=drain_durations,
                recovery_no_writes=recovery_only, process_exit_independently_verified=False,
                production_activation=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--recover', '--recovery', dest='recovery', action='store_true')
    args = parser.parse_args()
    evidence = RECOVERY_EVIDENCE if args.recovery else WRITE_EVIDENCE
    probe = RUNTIME / ('Mods/PWPSettingsChainRecovery' if args.recovery else 'Mods/PWPSettingsChainTrial')
    manifest = json.loads((evidence/'install.json').read_text())
    require(manifest.get('recovery_only') is args.recovery, 'manifest mode mismatch')
    prior_records = manifest['prior_records']
    write_records = None
    if args.recovery:
        previous = json.loads((WRITE_EVIDENCE/'receipt.json').read_text())
        require(previous.get('passed') is True and previous.get('mode') == 'write', 'successful write receipt required')
        require({**previous['prior_records'], **previous['records']} == manifest['prior_records'], 'full recovery baseline changed')
        prior_records = previous['prior_records']
        write_records = previous['records']
    log = (probe/'Scripts/settings-chain-trial.jsonl').read_bytes()
    receipt = inspect(log.decode(), STORE, manifest['nonce'], prior_records,
                      recovery_only=args.recovery, write_records=write_records)
    require(manifest['installed'] and {n: digest(probe/'Scripts'/n) for n in manifest['installed']}
            == manifest['installed'], 'installed files changed')
    production = RUNTIME/'Mods/PalWorkPriority'
    after = {str(p.relative_to(production)): digest(p) for p in production.rglob('*')
             if p.is_file() and (p.suffix == '.lua' or p.parent == production and p.suffix == '.txt')}
    require(after and after == manifest['production_before'], 'production/settings changed')
    require((probe/'Scripts/run.txt').read_text().strip() == 'DISABLED', 'marker not disarmed')
    receipt.update(nonce=manifest['nonce'], production_unchanged=True)
    (evidence/'settings-chain-trial.jsonl').write_bytes(log)
    (evidence/'receipt.json').write_text(json.dumps(receipt, indent=2))
    print(json.dumps(receipt))


if __name__ == '__main__':
    main()
