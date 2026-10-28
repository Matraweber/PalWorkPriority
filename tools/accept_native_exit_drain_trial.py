"""Independent acceptance of the disposable Quit-callback drain trial.

inspect is read-only. main saves evidence only after every check passes; it never
installs, arms, disables, or controls the game. Process-exit chronology is separate.
"""
import hashlib
import json
import re
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path('D:/Steam/steamapps/common/Palworld/Mods/NativeMods/UE4SS')
PROBE = RUNTIME / 'Mods/PWPExitDrainTrial2'
EVIDENCE = ROOT / 'test-results/native-exit-drain-live-20261004-v2'
STORE = ROOT / 'test-results/native-draining-live-20261004/store'
W, G = '3' * 32, '4' * 32
STREAMS = ('priorities', 'limits')


def require(ok, why):
    if not ok:
        raise ValueError(why)


def integer(value, minimum=0):
    return type(value) is int and minimum <= value < 2**63


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fixture_identity(fixture_version):
    require(type(fixture_version) is int and fixture_version in (1, 2), 'unsupported fixture version')
    return (W, G) if fixture_version == 1 else ('5' * 32, '6' * 32)


def payload(stream, revision, fixture_version=1):
    # Independent expected bytes, not the Lua serializer or the trial's report.
    world, guild = fixture_identity(fixture_version)
    require(stream in STREAMS and revision in (1, 2, 3), 'fixture identity')
    if stream == 'priorities':
        body = '# Pal Work Priority: palkey|worktype|priority (1 highest, 5 lowest, X disabled)\n# baseline=vanilla\n'
        body += ''.join(f'trial-pal|{i}|{v}\n' for i, v in enumerate([1, 2, 3, 4, 5, 'X', revision], 1))
    else:
        body = '# Production limits. Mining limits stop only the rocks of their item; every other limit switches its whole work type.\n'
        body += '# guild|work|item|limit (OFF hides an inherited limit for this guild)\n'
        body += f'{guild}|Mining|Ore|{100 * revision}\n{guild}|Mining|Stone|OFF\n'
    raw = body.encode()
    return f'PWP-SETTINGS-1\n{world}\n{guild}\n{stream}\n{len(raw)}\n'.encode() + raw


def record_name(world, guild, stream, slot):
    return f'pwp-record-v1-{world}-{guild}-{stream}-{slot}.record'


def inspect_records(directory, generations, prior_records, fixture_version=1):
    world, guild = fixture_identity(fixture_version)
    directory = Path(directory)
    prior_names = {record_name('1'*32, '2'*32, s, a) for s in STREAMS for a in ('A', 'B')}
    if fixture_version == 2:
        prior_names.update(record_name('3'*32, '4'*32, s, a)
                           for s, a in (('priorities', 'A'), ('priorities', 'B'), ('limits', 'A')))
    require(type(prior_records) is dict and set(prior_records) == prior_names, 'exact prior record manifest required')
    require(all(type(h) is str and re.fullmatch('[0-9a-f]{64}', h) for h in prior_records.values()), 'invalid prior digest')
    require(directory.is_dir() and not directory.is_symlink(), 'missing/redirected store')
    hashes = {}
    for name, expected in prior_records.items():
        p = directory / name
        require(p.is_file() and not p.is_symlink() and digest(p) == expected, 'prior record changed/missing')
    for stream in STREAMS:
        generation = generations[stream]
        require(type(generation) is int and generation in (2, 3), 'physical generation')
        slots = [('A', 1, 1), ('B', 2, 3)] if generation == 2 else [('A', 3, 3), ('B', 2, 2)]
        scope = f'PWP-SCOPE-1:{world}:{guild}:{stream}'.encode()
        for slot, gen, rev in slots:
            name = record_name(world, guild, stream, slot)
            body = payload(stream, rev, fixture_version)
            envelope = b'PWPJNL1\n' + struct.pack('<HII', len(scope), gen, len(body)) + scope + body
            p = directory / name
            require(p.is_file() and not p.is_symlink(), 'missing/redirected new record')
            actual = p.read_bytes()
            require(actual == envelope + hashlib.sha256(envelope).digest(), 'wrong complete record bytes')
            hashes[name] = hashlib.sha256(actual).hexdigest()
    require({p.name for p in directory.iterdir()} == set(hashes) | prior_names, 'unexpected store files')
    return hashes


def inspect(log, directory, nonce, prior_records, fixture_version=1):
    """Validate one complete ordered run and independent disk bytes, or raise.

    call.fields is the decoded native response (16 strings for status/recovery,
    one for bind/submit, [] or Lua JSON {} for an empty response).
    """
    world, guild = fixture_identity(fixture_version)

    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'duplicate JSON key')
            result[key] = value
        return result

    require(type(nonce) is str and re.fullmatch(r'[A-Za-z0-9_-]{1,64}', nonce), 'invalid nonce')
    rows = [json.loads(line, object_pairs_hook=unique) for line in log.splitlines() if line.strip()]
    require(rows and all(type(r) is dict and r.get('nonce') == nonce for r in rows), 'wrong/missing nonce')
    events = [r['data'] for r in rows]
    require(all(type(e) is dict for e in events), 'non-object event')
    cursor, last_finish = 0, 0
    owners, handles, generations, pending = {}, set(), {}, {}

    def take(kind, **expected):
        nonlocal cursor
        require(cursor < len(events), 'incomplete proof: ' + kind)
        e = events[cursor];cursor += 1
        require(e.get('event') == kind, 'expected event: ' + kind)
        require(all(type(e.get(k)) is type(v) and e[k] == v for k, v in expected.items()), 'event fields: ' + kind)
        return e

    armed = take('armed', synthetic=True, exit_hook_installed=True)
    if 'fixture_version' in armed:
        require(type(armed['fixture_version']) is int and armed['fixture_version'] == fixture_version, 'wrong armed fixture version')
    config = take('configured')
    game, frequency = config['game'], config['frequency']
    require(integer(game, 1) and integer(frequency, 1), 'invalid configuration')

    def scoped(kind, stream, **expected):
        b = owners[stream]
        return take(kind, stream=stream, scope=b['scope'], incarnation=b['incarnation'], handle=b['handle'], **expected)

    def call(command, stream):
        nonlocal last_finish
        b = owners[stream]
        mutation = command in (2, 4, 5, 8)
        if mutation:
            b['ticket'] += 1
            b['command'] = command
            b['revision'] = b['revision'] + 1 if command == 5 else 0
        e = scoped('call', stream, command=command, ticket=b['ticket'] if mutation else 0,
                   thread=game, frequency=frequency)
        require(integer(e['start']) and integer(e['finish']) and last_finish <= e['start'] <= e['finish'], 'call timing reversed')
        last_finish = e['finish']
        require(type(e['status']) is int and (e['status'] == 1 or command == 3 and e['status'] == 2), 'refused/unknown call')
        fields = e['fields']
        if fields == {}:
            fields = []  # Lua empty table is serialized as an object.
        count = 0 if e['status'] == 2 else (16 if command in (3, 6, 8) else 1 if command in (1, 5) else 0)
        require(type(fields) is list and len(fields) == count and all(type(v) is str for v in fields), 'native response fields')
        if command == 5:
            require(fields == [str(b['revision'])], 'wrong admitted logical revision')
        return e['status'], fields

    def decimal(s):
        require(type(s) is str and re.fullmatch(r'0|[1-9][0-9]*', s) and int(s) < 2147483647, 'invalid native decimal')
        return int(s)

    def status(stream, command=6):
        _, f = call(command, stream)
        b = owners[stream]
        require(f[:3] == [b['scope'], b['incarnation'], '1'], 'wrong status owner')
        a, c, g = decimal(f[3]), decimal(f[4]), decimal(f[7])
        require(0 <= c <= a and f[6] == 'none' and f[8] == '0', 'status error/counters/cleanup')
        require(f[12:] == [str(b['ticket']), str(b['command']), str(b['revision']), 'accepted'], 'stale operation receipt')
        require(f[10:12] == ['1', '0'], 'uncertain native terminal')
        return f, a, c, g

    for stream in STREAMS:
        b = owners[stream] = dict(scope=f'PWP-SCOPE-1:{world}:{guild}:{stream}', incarnation=nonce+'-exit-'+stream,
                                 handle=1, ticket=0, command=0, revision=0)
        _, f = call(1, stream)
        handle = decimal(f[0])
        require(1 <= handle <= 128 and handle not in handles, 'invalid/reused owner')
        handles.add(handle);b['handle'] = handle
        scoped('bound', stream, synthetic=True)
        call(2, stream)
        while True:
            code, f = call(3, stream)
            if code == 1:
                break
        require(f[:7] == [b['scope'], b['incarnation'], '1', 'recovered', '1', '0', '0']
                and f[7] and f[8:] == ['0', '0', 'missing', '0', '', 'missing', '0', ''], 'not positive missing recovery')
        call(4, stream)
        call(5, stream)
        while True:
            f, a, c, g = status(stream)
            require(a == 1 and f[5] == 'ready', 'initialization owner not ready')
            if c == 1:
                require(g == 1 and f[9] == 'initialized', 'invalid initial commit')
                break
            require(c == 0 and g == 0 and f[9] in ('recovered', 'initialized'), 'invalid pending initialization')
        scoped('initialized', stream, accepted=1, committed=1, generation=1, cleanup_error='0')

    take('ready', synthetic=True, storage=world, guild=guild, owners_retained=2)
    for stream in STREAMS:
        f, a, c, g = status(stream)
        require((a, c, g) == (1, 1, 1) and f[5] == 'ready' and f[9] == 'initialized', 'changed ready owner')
    take('quit-observed', reason=4, game_thread=game, synthetic=True, scope_verified=False)
    for stream in STREAMS:
        call(5, stream);call(5, stream)
        f, a, c, g = status(stream)
        require(a == 3 and 1 <= c <= 3 and f[5] == 'ready', 'invalid tail observation')
        # Native publication terminal may become visible just before committed
        # advances. Do not mistake that legitimate observation for a durable ACK.
        require(f[9] in ('initialized', 'updated') and
                ((c == 1 and g == 1) or (c == 2 and g == 2) or (c == 3 and g in (2, 3))),
                'tail generation/terminal mismatch')
        require(c == 1 or f[9] == 'updated', 'tail committed without update terminal')
        scoped('pending-observation', stream, accepted=a, committed=c, generation=g, pending_observed=c < a)
        pending[stream] = (c, g)
    for stream in STREAMS:
        f, a, c, g = status(stream, 8)
        require(a == c == 3 and g in (2, 3) and f[5] == 'closed' and f[9] == 'updated', 'incomplete drain')
        require(g >= pending[stream][1] and (pending[stream][0] != 3 or g == pending[stream][1]), 'drain generation regressed')
        scoped('drained', stream, accepted=3, committed=3, generation=g, cleanup_error='0')
        generations[stream] = g
    for stream in STREAMS:
        call(9, stream)
        scoped('released', stream)
    take('passed', synthetic=True, explicit_drain=True, quit_reason=4, storage=world, guild=guild,
         completed=list(STREAMS), shutdown_route_verified=False, worker_thread_independently_observed=False)
    take('stopped', state='passed', phase='complete')
    require(cursor == len(events), 'unexpected events after completion')
    hashes = inspect_records(directory, generations, prior_records, fixture_version)
    return dict(passed=True, synthetic=True, explicit_drain=True, quit_callback_completed=True,
                fixture_version=fixture_version, records=hashes, prior_records=dict(prior_records), prior_records_unchanged=True,
                pending_observed={s: c < 3 for s, (c, _) in pending.items()}, shutdown_route_verified=False,
                process_exit_independently_verified=False, worker_thread_independently_observed=False)


def main():
    manifest = json.loads((EVIDENCE / 'install.json').read_text())
    require(type(manifest.get('fixture_version')) is int and manifest['fixture_version'] == 2, 'v2 manifest required')
    log = (PROBE / 'Scripts/exit-drain-trial.jsonl').read_bytes()
    receipt = inspect(log.decode(), STORE, manifest['nonce'], manifest['prior_records'], fixture_version=2)
    require(manifest['installed'] and {n: digest(PROBE / 'Scripts' / n) for n in manifest['installed']}
            == manifest['installed'], 'installed files changed')
    production = RUNTIME / 'Mods/PalWorkPriority'
    after = {str(p.relative_to(production)): digest(p) for p in production.rglob('*')
             if p.is_file() and (p.suffix == '.lua' or (p.parent == production and p.suffix == '.txt'))}
    require(after and after == manifest['production_before'], 'production/settings changed')
    require((PROBE / 'Scripts/run.txt').read_text().strip() == 'DISABLED', 'marker not disarmed')
    receipt.update(nonce=manifest['nonce'], production_unchanged=True)
    (EVIDENCE / 'exit-drain-trial.jsonl').write_bytes(log)
    (EVIDENCE / 'receipt.json').write_text(json.dumps(receipt, indent=2))
    print(json.dumps(receipt))


if __name__ == '__main__':
    main()
