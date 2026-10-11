"""Checked DLL-only local pending-travel trial. Default is read-only preflight.

Preserves the current combined launcher, Lua, normal DLL and every journal record.
Restoration changes only the launcher, never settings or the legacy writer route.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import uuid
import settings_migration_backup as B

ROOT = Path(__file__).resolve().parents[1]
MOD = Path('D:/Steam/steamapps/common/Palworld/Mods/NativeMods/UE4SS/Mods/PalWorkPriority')
BASE = ROOT/'test-results/combined-startup-install-decd3863212b'
LOCK = ROOT/'test-results/settings-lock-live-20261007'
STORE = ROOT/'test-results/native-limits-live-20261007/store'
LAUNCH = MOD/'async-trial/launch.lua'


def sha(p):
    return hashlib.sha256(B.checked_path(p).read_bytes()).hexdigest()


def load(p):
    return json.loads(B.checked_path(p).read_text(encoding='utf-8-sig'))


def code_state(check_launcher=True):
    B.require(B.game_closed(), 'game/server must be closed')
    original = load(BASE/'installed.json')
    overrides = {str(Path(c['target'])): c['after'] for c in load(LOCK/'installed.json')['changes']}
    stage = B.checked_path(Path(original['stage']), directory=True)
    expected = {}
    for rel, digest in original['protected'].items():
        # Runtime logs and diagnostic output may have grown; installed Lua and
        # user config are the executable surfaces relevant to this DLL-only swap.
        rel = Path(rel)
        if rel.parts[0] != 'Scripts' and rel.name != 'config.lua':
            continue
        p = MOD/rel
        expected[str(p)] = original['updates'].get(rel.as_posix(), digest)
    B.require(set(p.name for p in (MOD/'Scripts').glob('*.lua')) ==
              set(Path(p).name for p in expected if Path(p).parent == MOD/'Scripts'), 'unexpected installed Lua')
    for rel, digest in original['sources'].items():
        expected[str(stage/rel)] = digest
    expected.update(overrides)
    expected[str(stage/'pwp_draining_bridge.dll')] = original['native']['probe_sha256']
    expected[str(MOD.parent.parent/'UE4SS.dll')] = original['native']['staged_runtime_sha256']
    expected[str(MOD/'async-trial/receipt.lua')] = sha(ROOT/'test-results/limits-startup-receipt-20261007.lua')
    for p, digest in expected.items():
        B.require(sha(p) == digest, 'installed code differs: '+p)
    if check_launcher:
        B.require(sha(LAUNCH) == original['launcher_sha256'], 'launcher differs from normal combined trial')
    B.verify(ROOT/'test-results/legacy-backup-20261006', B.capture(MOD))
    return original, expected


def journals():
    B.checked_path(STORE, directory=True)
    return {p.name: sha(p) for p in STORE.iterdir()}


def replace_launcher(raw):
    B.require(B.game_closed(), 'game started before launcher replacement')
    temp = LAUNCH.with_name('launch.'+uuid.uuid4().hex+'.pending')
    B.write_new(temp, raw)
    os.replace(temp, LAUNCH)
    B.require(LAUNCH.read_bytes() == raw, 'launcher replacement verification failed')


def preflight(receipt):
    original, code = code_state()
    native = load(receipt)
    for key in ('test_only', 'tests_passed', 'source_stable'):
        B.require(native.get(key) is True, 'live barrier gate missing: '+key)
    B.require(type(native['bounded_hold_ms']) is int and 0 < native['bounded_hold_ms'] <= 60000, 'unbounded live barrier')
    B.require(Path(native['compiled_root']) == STORE, 'journal root differs')
    B.require(native['staged_runtime_sha256'] == original['native']['staged_runtime_sha256'], 'runtime differs')
    artifact = B.checked_path(native['artifact'])
    B.require(sha(artifact) == native['probe_sha256'], 'barrier DLL differs')
    B.require(native['sources'], 'missing source fingerprint')
    for rel, digest in native['sources'].items():
        B.require(sha(ROOT/rel) == digest, 'barrier source changed: '+rel)
    evidence = B.checked_path(native['evidence_path'])
    B.require(not evidence.exists(), 'preserve earlier native evidence; build a new trial')
    current = journals()
    wanted = {r['file']: r['sha256'] for r in load(BASE/'restored/decoded.json')}
    B.require(current == wanted, 'settings changed since restored baseline')
    return dict(native=native, code=code, journal=current, original=original)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt', type=Path)
    parser.add_argument('--install', action='store_true')
    parser.add_argument('--restore', type=Path, help='installation evidence directory')
    args = parser.parse_args()
    if args.restore:
        B.require(not args.install and not args.receipt, 'restore is a separate operation')
        receipt = args.restore/'installed.json'
        if not receipt.exists():
            receipt = args.restore/'intent.json'  # durable before launcher activation
        record = load(receipt)
        _, code = code_state(check_launcher=False)
        B.require(code == record['code'], 'normal code changed before restoration')
        current = sha(LAUNCH)
        B.require(current in (record['launcher_sha256'], record['original']['launcher_sha256']), 'trial launcher changed')
        raw = B.checked_path(args.restore/'previous-launch.lua').read_bytes()
        B.require(hashlib.sha256(raw).hexdigest() == record['original']['launcher_sha256'], 'backup launcher differs')
        before = journals()
        if current != record['original']['launcher_sha256']:
            replace_launcher(raw)
        code_state()
        B.require(journals() == before, 'journals changed during restoration')
        result = args.restore/'restored-launch.json'
        if not result.exists():
            B.write_new(result, json.dumps(dict(journal=before, restored=True), indent=2).encode())
        print('Normal checked combined DLL restored; current journals preserved')
        return
    B.require(args.receipt is not None, '--receipt required')
    before = preflight(args.receipt)
    if not args.install:
        print(json.dumps(dict(checked=True, installed=False, journals=len(before['journal']))))
        return
    evidence = ROOT/'test-results'/('pending-travel-live-'+uuid.uuid4().hex[:12])
    evidence.mkdir()
    old = LAUNCH.read_bytes()
    B.write_new(evidence/'previous-launch.lua', old)
    (evidence/'journal-before').mkdir()
    for name, digest in before['journal'].items():
        raw = (STORE/name).read_bytes()
        B.require(hashlib.sha256(raw).hexdigest() == digest, 'journal changed during backup')
        B.write_new(evidence/'journal-before'/name, raw)
    stage = MOD/'async-trial'/('pending-'+uuid.uuid4().hex)
    B.checked_path(stage, directory=True); stage.mkdir()
    target = stage/'pwp_draining_bridge.dll'
    B.write_new(target, Path(before['native']['artifact']).read_bytes())
    B.require(sha(target) == before['native']['probe_sha256'], 'staged DLL differs')
    old_dll = (Path(before['original']['stage'])/'pwp_draining_bridge.dll').as_posix().encode()
    B.require(old.count(old_dll) == 1, 'exact DLL reference missing')
    new = old.replace(old_dll, target.as_posix().encode())
    record = dict(before, stage=str(stage), log_offset=(MOD/'priority.log').stat().st_size,
                  launcher_sha256=hashlib.sha256(new).hexdigest(), live_acceptance=False)
    B.write_new(evidence/'intent.json', json.dumps(record, indent=2).encode())
    B.require(preflight(args.receipt) == before, 'state changed before activation')
    B.require(LAUNCH.read_bytes() == old, 'launcher changed during preparation')
    B.require(sha(target) == before['native']['probe_sha256'], 'staged DLL changed before activation')
    replace_launcher(new)
    B.require(journals() == before['journal'], 'journal changed while installing')
    B.write_new(evidence/'installed.json', json.dumps(record, indent=2).encode())
    print(json.dumps(dict(installed=True, evidence=str(evidence), live_acceptance=False)))


if __name__ == '__main__':
    main()
