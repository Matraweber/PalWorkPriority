"""Checked opt-in real limits trial, in the production mod's Lua state.

Default is read-only preflight. --install preserves code and legacy settings,
stages a fixed-root native build, and arms ONLY after all fingerprints match.
The launcher must remain installed for journal recovery; do not disable it and
silently return to the stale legacy caps.txt after accepted journal edits.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess
import uuid
import settings_migration_backup as Backup
import settings_startup_receipt as Receipt
from install_native_settings_chain_trial import native_sources

ROOT = Path(__file__).resolve().parents[1]
GAME = Path('D:/Steam/steamapps/common/Palworld')
RUNTIME = GAME/'Mods/NativeMods/UE4SS'
MOD = RUNTIME/'Mods/PalWorkPriority'
BUILD = ROOT/'experiments/native-draining-bridge/build'
STORE = ROOT/'test-results/native-limits-live-20261007/store'
BACKUP = ROOT/'test-results/legacy-backup-20261006'
RECEIPT = ROOT/'test-results/limits-startup-receipt-20261007.lua'
W = '31141b9948fe8b9a8b4cc399974dddf1'
G = 'd2c75eae4e5c0c4c4d24b89b2010b5eb'
ALIAS = '-758686034-1314655308-1294252187-537966059'
FLAGS = ('compiled', 'linked', 'source_stable', 'entry_tests_passed',
         'real_filesystem_tests_passed', 'typed_recovery_validated',
         'legacy_parser_mutant_rejected', 'unrooted_input_mutant_rejected',
         'normal_crt_exit_with_live_worker_passed', 'registry_destructor_guard_passed',
         'lost_reply_ticket_tested', 'post_publication_uncertainty_tested', 'compiled_root_verified')


def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()


def closure(entry):
    pending, found = [entry], set()
    while pending:
        path = pending.pop().resolve()
        Backup.require(path.is_relative_to(ROOT) and path.is_file(), 'invalid dependency ' + str(path))
        if path in found: continue
        found.add(path)
        for name in re.findall(r"dofile\(root\s*\.\.\s*'(/[^']+)'\)", path.read_text(encoding='utf-8')):
            pending.append(path.parent/name[1:])
    return sorted(found)


def preflight():
    Backup.require(Backup.game_closed(), 'game/server must be closed')
    for p in (MOD, BACKUP, BUILD): Backup.checked_path(p, directory=True)
    b = json.loads((BUILD/'receipt.json').read_text())
    Backup.require(all(b.get(k) is True for k in FLAGS), 'native build gates failed')
    Backup.require(Path(b['compiled_root']) == STORE, 'wrong compiled native root')
    Backup.require(b['sources'] == native_sources(), 'native build sources stale')
    Backup.require(sha(BUILD/'pwp_draining_bridge.dll') == b['probe_sha256'], 'native DLL changed')
    Backup.require(sha(RUNTIME/'UE4SS.dll') == b['staged_runtime_sha256'], 'runtime fingerprint changed')
    v = Backup.verify(BACKUP)
    current = Backup.capture(MOD)
    Backup.require(Backup.stable_equal(v['capture'], current), 'legacy settings changed since backup')
    expected = Receipt.render(v['capture'], BACKUP, (BACKUP/'manifest.json').read_bytes())
    Backup.require(RECEIPT.read_bytes() == expected, 'prepared receipt is not the verified backup')
    Backup.require(not (MOD/'async-trial').exists() and not (MOD/'experiments').exists(), 'trial already staged; preserve it')
    Backup.require(not STORE.exists(), 'journal root already exists; preserve it')
    files = set(closure(ROOT/'experiments/settings_live.lua')) | set((ROOT/'Scripts').glob('*.lua'))
    files |= {ROOT/'Info.json', RECEIPT, BUILD/'pwp_draining_bridge.dll'}
    hashes = {str(p.relative_to(ROOT)): sha(p) for p in sorted(files)}
    return b, current, hashes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--install', action='store_true')
    args = parser.parse_args()
    b, current, hashes = preflight()
    if not args.install:
        print(json.dumps(dict(preflight=True, files=len(hashes), production_enabled=False)))
        return
    evidence = ROOT/'test-results'/('limits-startup-install-'+uuid.uuid4().hex[:12])
    evidence.mkdir()
    for command, name in ((['python','tools/test_lua.py'],'lua.log'),
                          (['python','tools/luacheck.py'],'structural.log')):
        p = subprocess.run(command, cwd=ROOT, capture_output=True)
        Backup.write_new(evidence/name, p.stdout+p.stderr)
        Backup.require(p.returncode == 0, name+' failed')
    # Exact checked sources must survive the test run, native receipt included.
    Backup.require(preflight()[2] == hashes, 'sources changed during testing')
    # Compile the non-production dependency closure too; Lua's compiler gate
    # normally compiles only Scripts (behavior tests exercise the experiments).
    import sys
    sys.path.insert(0, str(ROOT/'.test-deps'))
    from lupa.lua54 import LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=True)
    compiler = lua.eval('function(s,n) local f,e=load(s,n,"t",{});return f~=nil,e end')
    for rel in hashes:
        if rel.endswith('.lua'):
            ok, err = compiler((ROOT/rel).read_text(encoding='utf-8-sig'), '@'+rel)
            Backup.require(ok, 'compile failed '+str(err))
    nonce = 'limits-'+uuid.uuid4().hex
    manifest = dict(kind='REAL_LIMITS_TRIAL', nonce=nonce, sources=hashes, native=b,
                    legacy=current, backup=str(BACKUP), store=str(STORE), armed=False)
    Backup.write_new(evidence/'prepared.json', json.dumps(manifest, indent=2).encode())
    Backup.require(Backup.game_closed(), 'game launched during preflight')
    p = subprocess.run(['powershell','-NoProfile','-File','tools/deploy.ps1','-GamePath',str(GAME)],
                       cwd=ROOT, capture_output=True)
    Backup.write_new(evidence/'deploy.log', p.stdout+p.stderr)
    Backup.require(p.returncode == 0, 'checked production code deployment failed; no trial armed')
    trial = MOD/'async-trial'
    trial.mkdir()
    (MOD/'experiments').mkdir()
    STORE.parent.mkdir(exist_ok=False)
    STORE.mkdir()
    for source in closure(ROOT/'experiments/settings_live.lua'):
        if source.parent.name != 'experiments': continue
        Backup.write_new(MOD/'experiments'/source.name, source.read_bytes())
    Backup.write_new(trial/'receipt.lua', RECEIPT.read_bytes())
    Backup.write_new(trial/'pwp_draining_bridge.dll', (BUILD/'pwp_draining_bridge.dll').read_bytes())
    for rel, digest in hashes.items(): Backup.require(sha(ROOT/rel)==digest, 'source changed during staging')
    for path in closure(ROOT/'experiments/settings_live.lua'):
        rel=path.relative_to(ROOT)
        Backup.require(sha(MOD/rel)==hashes[str(rel)], 'installed dependency changed')
    for path in (ROOT/'Scripts').glob('*.lua'):
        Backup.require(sha(MOD/'Scripts'/path.name)==sha(path), 'installed Lua differs')
    Backup.require(sha(trial/'receipt.lua')==sha(RECEIPT), 'receipt copy differs')
    Backup.require(sha(trial/'pwp_draining_bridge.dll')==b['probe_sha256'], 'DLL copy differs')
    Backup.require(Backup.game_closed() and Backup.stable_equal(current,Backup.capture(MOD)),
                   'settings/process changed before arming')
    Backup.verify(BACKUP,current)
    launcher = ("return dofile('"+(MOD/'experiments/settings_live.lua').as_posix()+"').install{enabled=true,"
                "receipt=dofile('"+(trial/'receipt.lua').as_posix()+"'),storage='"+W+"',guild='"+G+"',"
                "runtime_guild='"+ALIAS+"',nonce='"+nonce+"-'..os.time(),dll='"+
                (trial/'pwp_draining_bridge.dll').as_posix()+"'}\n")
    Backup.write_new(trial/'launch.lua', launcher.encode('ascii'))
    manifest.update(armed=True, launcher_sha256=sha(trial/'launch.lua'))
    Backup.write_new(evidence/'installed.json',json.dumps(manifest,indent=2).encode())
    print(json.dumps(dict(installed=True,evidence=str(evidence),nonce=nonce,
                         live_acceptance=False,limits_only=True)))


if __name__ == '__main__': main()
