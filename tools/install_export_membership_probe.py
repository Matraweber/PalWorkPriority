"""Checked one-shot export-membership diagnostic. No production settings writes."""
from pathlib import Path
import argparse
import base64
import hashlib
import json
import subprocess
import sys
import uuid
import settings_export_coverage as Coverage
import settings_migration_backup as B
import settings_journal_export as J

ROOT=Path(__file__).resolve().parents[1]
RUNTIME=Path('D:/Steam/steamapps/common/Palworld/Mods/NativeMods/UE4SS')
PRODUCTION=RUNTIME/'Mods/PalWorkPriority'
PROBE=RUNTIME/'Mods/PWPExportMembershipRead'
RUNTIME_HASH='21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8'

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def fingerprint(root):
    B.checked_path(root,directory=True)
    result={}
    for p in root.rglob('*'):
        B.checked_path(p,directory=p.is_dir())
        if p.is_file() and p.name!='priority.log':result[p.relative_to(root).as_posix()]=digest(p)
    return result

def prepare(bundle,install=False):
    B.require(B.game_closed(),'game/server must be closed')
    report=Coverage.audit(bundle);m=Coverage.Bundle.verify(bundle)
    B.require(digest(Path(bundle)/'proposal.json')==report['manifest_sha256'],'report manifest changed')
    B.require(Path(m['source']['source']).resolve()==PRODUCTION.resolve(),'wrong production root')
    keys=report['lookup_union']
    import re
    B.require(0<len(keys)<=256 and all(re.fullmatch('[0-9A-F]{64}',k) and k[32:]!='0'*32 for k in keys),'native key union required')
    B.checked_path(PROBE,directory=True);B.require(not PROBE.exists(),'preserve previous diagnostic')
    B.require(digest(RUNTIME/'UE4SS.dll')==RUNTIME_HASH,'runtime changed')
    before=fingerprint(PRODUCTION)
    def unchanged():
        B.require(B.game_closed(),'process started')
        B.require(digest(RUNTIME/'UE4SS.dll')==RUNTIME_HASH,'runtime changed')
        B.require(fingerprint(PRODUCTION)==before,'production files changed')
        B.require(B.stable_equal(m['source'],B.capture(PRODUCTION)),'legacy changed')
        B.require(J.capture(m['journal_root'],report['storage'],report['guild'])==m['journal_entries'],'journals changed')
        B.require({n:B.read_exact(PRODUCTION/n) for n in m['trial_entries']}==m['trial_entries'],'trial changed')
        B.require(Coverage.Bundle.verify(bundle)==m,'bundle changed')
    unchanged()
    names=['save_local_authority','save_context_pair_probe','save_headless_identity_probe',
           'save_world_identity_probe','save_identity_probe','settings_priority_guild_roster',
           'settings_priority_parameter_roster','settings_priority_world_lookup',
           'settings_priority_live_reader','settings_priority_membership','settings_export_membership_observer']
    paths={'main.lua':ROOT/'experiments/export-membership-live/main.lua'}
    paths.update({'experiments/'+n+'.lua':ROOT/('experiments/'+n+'.lua') for n in names})
    paths.update({n+'.lua':ROOT/('Scripts/'+n+'.lua') for n in ['palapi','log','trace','perf','frame_trace','workdefs','store','datafile','settings_gate']})
    data={n:p.read_bytes() for n,p in paths.items()}
    config={k:report[k] for k in ('manifest_sha256','storage','guild')}
    config['alias']=m['plan']['legacy_guild'];config['keys']=keys
    # All string values are already bounded ASCII GUIDs, hash, validated alias or native keys.
    data['target.lua']=('return {'+','.join(k+'='+json.dumps(v) for k,v in config.items() if k!='keys')+',keys={'+','.join(json.dumps(k) for k in keys)+'}}\n').encode('ascii')
    sys.path.insert(0,str(ROOT/'.test-deps'))
    from lupa.lua54 import LuaRuntime
    lua=LuaRuntime(unpack_returned_tuples=True)
    compile=lua.eval('function(s,n)local f,e=load(s,n,"t",{});return f~=nil,e end')
    for name,raw in data.items():
        ok,why=compile(raw.decode('utf-8'),'@'+name);B.require(ok,why)
    tests=['tests/test_export_membership_live.lua','tests/test_settings_export_membership_observer.lua',
           'tests/test_priority_direct_reader.lua','tests/test_priority_membership.lua']
    test=subprocess.run([sys.executable,'tools/test_lua.py',*tests],cwd=ROOT,capture_output=True,timeout=90)
    B.require(test.returncode==0,'diagnostic regressions failed: '+test.stdout.decode(errors='replace'))
    B.require(all(p.read_bytes()==data[n] for n,p in paths.items()),'source changed')
    unchanged()
    if not install:return {'checked':True,'installed':False,'keys':len(keys)}
    nonce=uuid.uuid4().hex;evidence=ROOT/'test-results'/('export-membership-'+nonce)
    evidence.mkdir();B.write_new(evidence/'checks.log',test.stdout+test.stderr)
    receipt={'nonce':nonce,'probe':str(PROBE),'production_before':before,'config':config,
             'bundle':str(Path(bundle).resolve()),'runtime_sha256':RUNTIME_HASH,
             'sources':{n:hashlib.sha256(raw).hexdigest() for n,raw in data.items()},
             'read_only':True,'activation_allowed':False,'replacement_allowed':False}
    B.write_new(evidence/'install.json',(json.dumps(receipt,indent=2)+'\n').encode())
    for name,raw in data.items():
        unchanged();p=PROBE/'Scripts'/name;p.parent.mkdir(parents=True,exist_ok=True);B.write_new(p,raw)
    unchanged()
    B.require(all((PROBE/'Scripts'/n).read_bytes()==raw for n,raw in data.items()),'staged bytes differ')
    arm=('PWP_EXPORT_MEMBERSHIP '+nonce+'\n').encode()
    try:
        B.write_new(PROBE/'Scripts/run.txt',arm)
        unchanged();B.write_new(PROBE/'enabled.txt',b'')
    except BaseException:
        # Both names were absent before our exclusive writes. Remove enable first;
        # never remove a different/foreign value if a competing writer changed it.
        for path,wanted in ((PROBE/'enabled.txt',b''),(PROBE/'Scripts/run.txt',arm)):
            entry=B.read_exact(path)
            if entry['state']=='present':
                raw=base64.b64decode(entry['bytes'],validate=True)
                B.require(raw==wanted,'arm cleanup refused: unexpected bytes; inspect diagnostic')
                B.checked_path(path).unlink()
        raise
    return {'installed':True,'evidence':str(evidence),'nonce':nonce,'keys':len(keys)}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('bundle',type=Path);p.add_argument('--install',action='store_true')
    args=p.parse_args();print(json.dumps(prepare(args.bundle,args.install)))
