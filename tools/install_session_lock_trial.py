"""Checked local schema-3 update. Default: read-only preflight; --install is explicit.

Preserve the original combined stage/DLL, journal and all eight legacy paths.
Incomplete installs keep their durable intent/backups; never auto-rollback to legacy.
Process checks are sampled, not an exclusive lock against launching the game.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import uuid
import settings_migration_backup as B
from install_limits_startup_trial import FLAGS

ROOT = Path(__file__).resolve().parents[1]
MOD = Path('D:/Steam/steamapps/common/Palworld/Mods/NativeMods/UE4SS/Mods/PalWorkPriority')
BASE = ROOT/'test-results/combined-startup-install-decd3863212b'
LOCK = ROOT/'test-results/settings-lock-live-20261007'
NORMAL = ROOT/'test-results/pending-travel-live-5f54e7a161b1'
RESTORED = BASE/'pending-travel-restored-20261007'
STORE = ROOT/'test-results/native-limits-live-20261007/store'
BACKUP = ROOT/'test-results/legacy-backup-20261006'
RECEIPT = ROOT/'test-results/limits-startup-receipt-20261007.lua'
ALLOW = frozenset('caps main scheduler ui panel_status net protocol'.split())
ENTRY = 'experiments/settings_live_combined.lua'


def sha(path):
    return hashlib.sha256(B.checked_path(path).read_bytes()).hexdigest()


def load(path):
    return json.loads(B.checked_path(path).read_text(encoding='utf-8-sig'))


def relative(text):
    p = Path(text)
    B.require(not p.drive and not p.root and '..' not in p.parts and p.parts, 'unsafe receipt path')
    return p


def tree(path):
    B.checked_path(path, directory=True)
    found = {}
    for p in path.iterdir():
        if p.is_dir():
            found.update({p.name+'/'+k: v for k, v in tree(p).items()})
        else:
            found[p.name] = sha(p)
    return found


def closure():
    pending, found = [ROOT/ENTRY], {}
    while pending:
        p = pending.pop()
        B.require(p.is_relative_to(ROOT), 'dependency outside repository')
        rel = p.relative_to(ROOT).as_posix()
        if rel in found:
            continue
        found[rel] = sha(p)
        for name in re.findall(r"dofile\(root\s*\.\.\s*'(/[^']+)'\)", p.read_text(encoding='utf-8')):
            pending.append(Path(os.path.abspath(p.parent/name[1:])))
    B.require(len(found) == 36, 'review closure change: expected 36 files')
    return found


def preflight():
    B.require(B.game_closed(), 'game/server must be closed')
    evidence = [BASE/'installed.json', LOCK/'installed.json', RESTORED/'decoded.json',
                NORMAL/'acceptance.json', NORMAL/'typed-restoration.json', NORMAL/'restored-launch.json',
                RECEIPT, BACKUP/'manifest.json']
    evidence_hashes = {str(p): sha(p) for p in evidence}
    original, lock = load(evidence[0]), load(evidence[1])
    native = original['native']
    B.require(all(native.get(k) is True for k in FLAGS), 'normal native build gates failed')
    B.require(Path(native['compiled_root']) == STORE, 'normal native root differs')
    stage = B.checked_path(original['stage'], directory=True)
    B.require(stage.parent == MOD/'async-trial', 'unexpected original stage')
    code = {}
    for rel, digest in original['protected'].items():
        p = relative(rel)
        if p.parts[0] == 'Scripts' or p.name == 'config.lua':
            code[str(MOD/p)] = original['updates'].get(p.as_posix(), digest)
    staged = {relative(k).as_posix(): v for k, v in original['sources'].items()}
    code.update({str(stage/rel): digest for rel, digest in staged.items()})
    allowed_overrides = {MOD/'Scripts/settings_gate.lua', MOD/'Scripts/ui.lua',
                         stage/'experiments/settings_startup_gate_group.lua'}
    seen = set()
    for change in lock['changes']:
        p = Path(change['target'])
        B.require(p in allowed_overrides and p not in seen, 'unknown/duplicate lock override')
        B.require(code.get(str(p)) == change['before'], 'lock receipt chain differs')
        code[str(p)] = change['after']; seen.add(p)
        if p.is_relative_to(stage):
            staged[p.relative_to(stage).as_posix()] = change['after']
    B.require(seen == allowed_overrides, 'incomplete lock receipt')
    staged['pwp_draining_bridge.dll'] = native['probe_sha256']
    B.require(tree(stage) == staged, 'original stage changed')
    code[str(stage/'pwp_draining_bridge.dll')] = native['probe_sha256']
    code[str(MOD.parent.parent/'UE4SS.dll')] = native['staged_runtime_sha256']
    code[str(MOD/'async-trial/receipt.lua')] = sha(RECEIPT)
    code[str(MOD/'async-trial/launch.lua')] = original['launcher_sha256']
    installed_scripts = {Path(p).name for p in code if Path(p).parent == MOD/'Scripts'}
    B.require(set(tree(MOD/'Scripts')) == installed_scripts, 'unexpected installed Scripts inventory')
    for p, digest in code.items():
        B.require(sha(p) == digest, 'installed code differs: '+p)
    B.verify(BACKUP, B.capture(MOD))
    accepted, typed, restored = (load(p) for p in evidence[3:6])
    for flag in ('normal_restart_verified', 'normal_launcher_restored', 'all_settings_equal_original',
                 'legacy_paths_unchanged', 'durable_recovery_verified'):
        B.require(accepted.get(flag) is True, 'normal acceptance missing: '+flag)
    B.require(typed.get('exact_original_typed_state') is True and restored.get('restored') is True,
              'normal restoration unverified')
    rows = load(evidence[2]); wanted = {}; generations = {}
    scope = re.search(r"storage='([0-9a-f]{32})',guild='([0-9a-f]{32})'",
                      (MOD/'async-trial/launch.lua').read_text())
    B.require(scope is not None, 'normal launcher scope missing')
    for row in rows:
        name, stream = row['file'], row['stream']
        B.require(stream in ('limits', 'priorities') and name not in wanted and
                  name in {f'pwp-record-v1-{scope[1]}-{scope[2]}-{stream}-{slot}.record' for slot in 'AB'},
                  'unexpected/duplicate journal receipt entry')
        B.require(type(row['generation']) is int and row['generation'] > 0 and type(row['decoded']) is dict,
                  'invalid decoded journal evidence')
        wanted[name] = row['sha256']
        B.require(sha(RESTORED/name) == row['sha256'], 'restored journal archive differs')
        generations[stream] = max(generations.get(stream, 0), row['generation'])
    B.require(len(wanted) == 4 and generations == typed['generations'], 'journal generations differ')
    B.require(tree(STORE) == wanted == restored['journal'], 'current journal differs from normal restoration')
    candidate_closure = closure()
    sources = dict(candidate_closure)
    scripts = tree(ROOT/'Scripts')
    B.require(set(scripts) == installed_scripts, 'repository Scripts inventory changed')
    updates = {}
    for name, digest in scripts.items():
        if code[str(MOD/'Scripts'/name)] != digest:
            B.require(Path(name).stem in ALLOW and Path(name).suffix == '.lua', 'unreviewed Lua difference: '+name)
            updates['Scripts/'+name] = digest
    B.require(re.search(r'\bSCHEMA\s*=\s*3\b', (ROOT/'Scripts/protocol.lua').read_text()), 'candidate is not schema 3')
    sources.update({'Scripts/'+name: digest for name, digest in scripts.items()})
    B.require(all(sha(p) == digest for p, digest in evidence_hashes.items()), 'receipt changed during preflight')
    compile_lua(sources)
    tool_root = Path(__file__).resolve().parents[1]
    tooling = {str(p): sha(p) for p in (Path(__file__).resolve(), Path(B.__file__).resolve(),
               tool_root/'tools/install_limits_startup_trial.py',
               tool_root/'tests/test_install_session_lock_trial.py')}
    B.require(closure() == candidate_closure and all(sha(ROOT/rel) == digest for rel, digest in sources.items()),
              'candidate changed during preflight')
    return dict(code=code, sources=sources, updates=updates, closure=candidate_closure, journal=wanted,
                generations=generations, evidence=evidence_hashes, original_stage=str(stage),
                original_tree=staged, native=native, legacy=B.capture(MOD), tooling=tooling)


def compile_lua(sources):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'.test-deps'))
    from lupa.lua54 import LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=True)
    check = lua.eval('function(s,n)local f,e=load(s,n,"t",{});return f~=nil,e end')
    for rel in sources:
        ok, error = check((ROOT/rel).read_text(encoding='utf-8-sig'), '@'+rel)
        B.require(ok, 'candidate Lua compile failed: '+str(error))


def verify(before, stage=None, launcher=None, updated=False):
    B.require(B.game_closed(), 'game/server started')
    for p, digest in before['tooling'].items():
        B.require(sha(p) == digest, 'updater tooling changed')
    B.require(closure() == before['closure'], 'closure changed')
    B.require(tree(Path(before['original_stage'])) == before['original_tree'], 'original stage changed')
    B.require(tree(ROOT/'Scripts') == {Path(k).name: v for k, v in before['sources'].items()
                                      if Path(k).parent == Path('Scripts')}, 'source inventory changed')
    for p, digest in before['evidence'].items():
        B.require(sha(p) == digest, 'receipt changed')
    for rel, digest in before['sources'].items():
        B.require(sha(ROOT/relative(rel)) == digest, 'candidate source changed: '+rel)
    expected = dict(before['code'])
    if updated:
        expected.update({str(MOD/rel): digest for rel, digest in before['updates'].items()})
    if launcher is not None:
        expected[str(MOD/'async-trial/launch.lua')] = hashlib.sha256(launcher).hexdigest()
    for p, digest in expected.items():
        B.require(sha(p) == digest, 'post/pre-arm code mismatch: '+p)
    B.require(set(tree(MOD/'Scripts')) == {Path(p).name for p in expected if Path(p).parent == MOD/'Scripts'},
              'Scripts inventory changed')
    B.require(tree(STORE) == before['journal'], 'journal changed')
    B.verify(BACKUP, B.capture(MOD))
    if stage is not None:
        B.require(tree(stage) == before['closure'], 'candidate stage differs')


def install(before, evidence, test_logs):
    """Only called by explicit --install after offline tests; no journal writes."""
    verify(before)
    B.require(set(test_logs) == {'lua.log', 'structural.log', 'installer.log'} and
              all(type(raw) is bytes and raw for raw in test_logs.values()), 'test evidence missing')
    B.checked_path(evidence, directory=True); evidence.mkdir()
    for name, raw in test_logs.items():
        B.write_new(evidence/name, raw)
    old = (MOD/'async-trial/launch.lua').read_bytes()
    B.write_new(evidence/'previous-launch.lua', old)
    (evidence/'code-before').mkdir()
    for rel in before['updates']:
        B.write_new(evidence/'code-before'/Path(rel).name, (MOD/rel).read_bytes())
    stage = MOD/'async-trial'/('session-lock-'+uuid.uuid4().hex)
    B.checked_path(stage, directory=True); stage.mkdir()
    for rel, digest in before['closure'].items():
        target = stage/relative(rel)
        target.parent.mkdir(parents=True, exist_ok=True)
        B.checked_path(target.parent, directory=True)
        raw = (ROOT/rel).read_bytes()
        B.require(hashlib.sha256(raw).hexdigest() == digest, 'source changed during stage')
        B.write_new(target, raw)
    old_entry = (Path(before['original_stage'])/ENTRY).as_posix().encode('ascii')
    B.require(old.count(old_entry) == 1, 'normal launcher entry not unique')
    launcher = old.replace(old_entry, (stage/ENTRY).as_posix().encode('ascii'))
    # The DLL, scope, nonce expression and receipt remain byte-identical.
    intent = dict(before, stage=str(stage), launcher=launcher.decode('ascii'),
                  launcher_sha256=hashlib.sha256(launcher).hexdigest(),
                  tests_passed=True, test_logs={name: hashlib.sha256(raw).hexdigest()
                                               for name, raw in test_logs.items()},
                  potentially_armed=True, rollback_to_legacy_allowed=False, live_acceptance=False)
    B.write_new(evidence/'intent.json', json.dumps(intent, indent=2).encode())
    verify(before, stage)
    for rel, digest in before['updates'].items():
        B.require(B.game_closed(), 'game started during update')
        target = B.checked_path(MOD/rel)
        B.require(sha(target) == before['code'][str(target)], 'target changed before replacement')
        raw = (ROOT/rel).read_bytes()
        B.require(hashlib.sha256(raw).hexdigest() == digest, 'source changed before replacement')
        pending = target.with_name(target.name+'.'+uuid.uuid4().hex+'.pending')
        B.write_new(pending, raw); os.replace(pending, target)
    verify(before, stage, updated=True)
    pending = MOD/'async-trial'/('launch.'+uuid.uuid4().hex+'.pending')
    B.write_new(pending, launcher)
    verify(before, stage, updated=True)
    B.require(pending.read_bytes() == launcher, 'pending launcher changed')
    B.require(B.game_closed(), 'game started before activation')
    os.replace(pending, MOD/'async-trial/launch.lua')
    verify(before, stage, launcher, updated=True)
    B.write_new(evidence/'installed.json', json.dumps(dict(intent, installed=True), indent=2).encode())
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--install', action='store_true')
    args = parser.parse_args()
    before = preflight()
    if not args.install:
        print(json.dumps(dict(checked=True, installed=False, closure_files=len(before['closure']),
                              updates=sorted(before['updates']), generations=before['generations'])))
        return
    # Freeze candidate inputs across the full Lua and structural checks.
    logs = {}
    for command, name in (([sys.executable, 'tools/test_lua.py'], 'lua.log'),
                          ([sys.executable, 'tools/luacheck.py'], 'structural.log'),
                          ([sys.executable, 'tests/test_install_session_lock_trial.py'], 'installer.log')):
        run = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=240)
        B.require(run.returncode == 0, name+' failed: '+run.stdout.decode(errors='replace')[-2000:])
        logs[name] = run.stdout+run.stderr
    B.require(preflight() == before, 'candidate changed during tests')
    destination = ROOT/'test-results'/('session-lock-install-'+uuid.uuid4().hex[:12])
    result = install(before, destination, logs)
    print(json.dumps(dict(installed=True, evidence=str(result), live_acceptance=False)))


if __name__ == '__main__':
    main()
