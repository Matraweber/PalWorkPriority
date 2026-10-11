"""Upgrade the checked limits trial to a two-stream local trial.
Default is read-only preflight. Preserve the existing journal and retain the old DLL/code as evidence.
Upgrade only the reviewed main/store modules. Stage a versioned dependency tree and replace only launch.lua last.
Never revert to the old launcher after priority journal admission.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import sys
import uuid
import settings_migration_backup as B
import install_limits_startup_trial as L
from install_native_settings_chain_trial import native_sources

ROOT, MOD, STORE = L.ROOT, L.MOD, L.STORE
TRIAL = MOD/'async-trial'
BASELINE = ROOT/'test-results/direct-8750ba17faab4e1fa7e1d02d1bd2ef39'
ENTRY = ROOT/'experiments/settings_live_combined.lua'


def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()


def current_journal():
    B.checked_path(STORE, directory=True)
    return {p.name: sha(B.checked_path(p)) for p in STORE.iterdir()}


def preflight():
    B.require(B.game_closed(), 'game/server must be closed')
    b = json.loads((L.BUILD/'receipt.json').read_text())
    B.require(all(b.get(k) is True for k in L.FLAGS), 'native build gates failed')
    B.require(Path(b['compiled_root']) == STORE and b['sources'] == native_sources(), 'native root/sources changed')
    B.require(sha(L.BUILD/'pwp_draining_bridge.dll') == b['probe_sha256'], 'checked new DLL changed')
    B.require(sha(L.RUNTIME/'UE4SS.dll') == b['staged_runtime_sha256'], 'runtime changed')
    old = json.loads((BASELINE/'install.json').read_text())['production_before']
    protected = {name: digest for name, digest in old.items() if name != 'remote.txt'}
    for name, digest in protected.items():
        B.require(sha(B.checked_path(MOD/name)) == digest, 'installed source changed: '+name)
    B.require("/experiments/settings_live.lua').install" in (TRIAL/'launch.lua').read_text(), 'not the existing limits-only launcher')
    snapshot = B.capture(MOD)
    B.verify(L.BACKUP, snapshot)
    B.require((TRIAL/'receipt.lua').read_bytes() == L.RECEIPT.read_bytes(), 'legacy receipt differs')
    journal = current_journal()
    expected = json.loads((BASELINE/'post-run.json').read_text())['journal_hashes']
    B.require(journal == expected and len(journal) == 2, 'journal changed or missing; preserve and reassess')
    # Only the main role/epoch wiring and prepared Store cutover API may change.
    updates={}
    for source in (ROOT/'Scripts').glob('*.lua'):
        if sha(source) != sha(MOD/'Scripts'/source.name):
            B.require(source.name in ('main.lua','store.lua'), 'unreviewed production Lua difference: '+source.name)
            updates['Scripts/'+source.name]=sha(source)
    paths = L.closure(ENTRY)
    hashes = {p.relative_to(ROOT).as_posix(): sha(p) for p in paths}
    return dict(native=b, legacy=snapshot, journal=journal, protected=protected, sources=hashes,updates=updates)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--install', action='store_true')
    args=parser.parse_args()
    before=preflight()
    if not args.install:
        print(json.dumps(dict(checked=True,installed=False,files=len(before['sources']),existing_limits_journal=True)))
        return
    evidence=ROOT/'test-results'/('combined-startup-install-'+uuid.uuid4().hex[:12])
    evidence.mkdir()
    for command,name in (([sys.executable,'tools/test_lua.py'],'lua.log'),
                         ([sys.executable,'tools/luacheck.py'],'structural.log')):
        r=subprocess.run(command,cwd=ROOT,capture_output=True,timeout=180)
        B.write_new(evidence/name,r.stdout+r.stderr)
        B.require(r.returncode==0,name+' failed')
    B.require(preflight()==before,'sources/state changed during tests')
    sys.path.insert(0,str(ROOT/'.test-deps'))
    from lupa.lua54 import LuaRuntime
    lua=LuaRuntime(unpack_returned_tuples=True)
    compile_chunk=lua.eval('function(s,n)local f,e=load(s,n,"t",{});return f~=nil,e end')
    for rel in set(before['sources']) | set(before['updates']):
        ok,why=compile_chunk((ROOT/rel).read_text(encoding='utf-8-sig'),'@'+rel)
        B.require(ok,'compile: '+str(why))
    nonce='combined-'+uuid.uuid4().hex
    stage=TRIAL/nonce
    B.checked_path(stage,directory=True)
    B.require(not stage.exists(),'preserve existing stage')
    # Durable evidence and both journal generations precede any code activation.
    B.write_new(evidence/'previous-launch.lua',(TRIAL/'launch.lua').read_bytes())
    (evidence/'code-before').mkdir()
    for rel in before['updates']:
        B.write_new(evidence/'code-before'/Path(rel).name,(MOD/rel).read_bytes())
    (evidence/'journal-before').mkdir()
    for name,digest in before['journal'].items():
        raw=(STORE/name).read_bytes()
        B.require(hashlib.sha256(raw).hexdigest()==digest,'journal changed during backup')
        B.write_new(evidence/'journal-before'/name,raw)
    B.write_new(evidence/'prepared.json',json.dumps(before,indent=2).encode())
    stage.mkdir()
    for rel,digest in before['sources'].items():
        target=stage/rel
        target.parent.mkdir(parents=True,exist_ok=True)
        raw=(ROOT/rel).read_bytes()
        B.require(hashlib.sha256(raw).hexdigest()==digest,'source changed while staging')
        B.write_new(target,raw)
    B.write_new(stage/'pwp_draining_bridge.dll',(L.BUILD/'pwp_draining_bridge.dll').read_bytes())
    B.require(sha(stage/'pwp_draining_bridge.dll')==before['native']['probe_sha256'],'new DLL stage differs')
    B.require(preflight()==before,'state changed before launcher activation')
    for rel,digest in before['sources'].items():
        B.require(sha(stage/rel)==digest,'installed dependency mismatch')
    launcher=("return dofile('"+(stage/'experiments/settings_live_combined.lua').as_posix()+"').install{enabled=true,"
        "receipt=dofile('"+(TRIAL/'receipt.lua').as_posix()+"'),storage='"+L.W+"',guild='"+L.G+"',"
        "runtime_guild='"+L.ALIAS+"',nonce='"+nonce+"-'..os.time(),dll='"+
        (stage/'pwp_draining_bridge.dll').as_posix()+"'}\n").encode('ascii')
    ok,why=compile_chunk(launcher.decode('ascii'),'@launch.lua');B.require(ok,str(why))
    pending=TRIAL/(nonce+'-launch.pending')
    # Record exact activation intent before the first replacement. If the
    # process stops after launch replacement, this durable record is sufficient
    # to identify the potentially armed configuration without installed.json.
    intent=dict(before,nonce=nonce,stage=str(stage),potentially_armed=True,
        launcher_sha256=hashlib.sha256(launcher).hexdigest(),launcher=launcher.decode('ascii'),
        rollback_to_legacy_allowed=False)
    B.write_new(evidence/'activation-intent.json',json.dumps(intent,indent=2).encode())
    B.write_new(pending,launcher)
    B.require(B.game_closed() and current_journal()==before['journal'],'process/journal changed before activation')
    B.require((TRIAL/'launch.lua').read_bytes()==(evidence/'previous-launch.lua').read_bytes(),'launcher changed')
    # Game remains closed; each updated module is flushed and atomically replaced.
    # If staging is interrupted the old limits launcher remains valid with these
    # backwards-compatible modules. Journal paths are never changed or removed.
    for rel,digest in before['updates'].items():
        B.require(B.game_closed(),'game launched during code update')
        target=B.checked_path(MOD/rel)
        B.require(sha(target)==before['protected'][str(Path(rel))],'installed module changed')
        raw=(ROOT/rel).read_bytes()
        B.require(hashlib.sha256(raw).hexdigest()==digest,'reviewed module changed')
        temp=target.with_name(target.name+'.'+nonce+'.pending')
        B.write_new(temp,raw)
        os.replace(temp,target)
        B.require(sha(target)==digest,'module update failed')
    # Final complete pre-arm check AFTER module updates, BEFORE launch replacement.
    # Scope deliberately includes old protected files, updated source modules,
    # staged dependencies/DLL, pinned runtime and both receipt copies.
    for name,digest in before['protected'].items():
        rel=Path(name).as_posix()
        B.require(sha(B.checked_path(MOD/name))==before['updates'].get(rel,digest),'final installed fingerprint changed: '+name)
    for rel,digest in before['sources'].items():
        B.require(sha(ROOT/rel)==digest and sha(stage/rel)==digest,'final source/stage differs: '+rel)
    for rel,digest in before['updates'].items():
        B.require(sha(ROOT/rel)==digest and sha(MOD/rel)==digest,'final module differs: '+rel)
    B.require(native_sources()==before['native']['sources'],'native source receipt changed')
    B.require(sha(stage/'pwp_draining_bridge.dll')==before['native']['probe_sha256'],'staged DLL changed')
    B.require(sha(L.RUNTIME/'UE4SS.dll')==before['native']['staged_runtime_sha256'],'runtime changed')
    B.require((TRIAL/'receipt.lua').read_bytes()==L.RECEIPT.read_bytes(),'installed receipt changed')
    B.require((TRIAL/'launch.lua').read_bytes()==(evidence/'previous-launch.lua').read_bytes(),'old launcher changed')
    B.verify(L.BACKUP,B.capture(MOD))
    B.require(B.game_closed() and current_journal()==before['journal'],'state changed before arming')
    B.require(pending.read_bytes()==launcher,'pending launcher changed')
    os.replace(pending,TRIAL/'launch.lua')
    B.require((TRIAL/'launch.lua').read_bytes()==launcher,'launcher verification failed')
    B.require(current_journal()==before['journal'],'journal changed during activation')
    B.verify(L.BACKUP,B.capture(MOD))
    record=dict(before,nonce=nonce,stage=str(stage),armed=True,launcher_sha256=sha(TRIAL/'launch.lua'),
        streams=['limits','priorities'],live_acceptance=False,rollback_to_legacy_allowed=False)
    B.write_new(evidence/'installed.json',json.dumps(record,indent=2).encode())
    print(json.dumps(dict(installed=True,evidence=str(evidence),nonce=nonce,live_acceptance=False)))


if __name__=='__main__': main()
