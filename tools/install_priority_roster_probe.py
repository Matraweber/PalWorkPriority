"""Check and optionally install an isolated one-shot READ-ONLY roster diagnostic."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import sys
import uuid
import settings_migration_backup as Backup

ROOT=Path(__file__).resolve().parents[1]
RUNTIME=Path('D:/Steam/steamapps/common/Palworld/Mods/NativeMods/UE4SS')
PRODUCTION=RUNTIME/'Mods/PalWorkPriority'
PROBE=RUNTIME/'Mods/PWPPriorityRosterRead'
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def production():
    return {str(p.relative_to(PRODUCTION)):digest(p) for p in PRODUCTION.rglob('*')
            if p.is_file() and (p.suffix=='.lua' or p.suffix=='.dll' or p.parent==PRODUCTION and p.suffix=='.txt')}
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--install',action='store_true')
    parser.add_argument('--route',choices=('camp','guild','parameter','world','direct'),default='camp')
    args=parser.parse_args()
    probe=RUNTIME/'Mods'/({'camp':'PWPPriorityRosterRead','guild':'PWPPriorityGuildRead','parameter':'PWPPriorityParameterRead','world':'PWPPriorityWorldRead','direct':'PWPPriorityDirectRead'}[args.route])
    assert Backup.game_closed(),'game must be closed'
    assert not probe.exists(),'preserve previous probe'
    assert digest(RUNTIME/'UE4SS.dll')=='21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8','runtime changed'
    manifest=Backup.verify(ROOT/'test-results/legacy-backup-20261006')
    assert Backup.stable_equal(manifest['capture'],Backup.capture(manifest['capture']['source']))
    before=production();assert before
    names=['save_local_authority','save_context_pair_probe','save_headless_identity_probe',
           'save_world_identity_probe','save_identity_probe','settings_priority_roster']
    if args.route!='camp':names.append('settings_priority_guild_roster')
    if args.route in ('parameter','world','direct'):names.append('settings_priority_parameter_roster')
    if args.route in ('world','direct'):names.append('settings_priority_world_lookup')
    if args.route=='direct':names.extend(['settings_priority_live_reader','settings_priority_membership'])
    paths={'main.lua':ROOT/'experiments/priority-roster-live/main.lua'}
    paths.update({'experiments/'+n+'.lua':ROOT/('experiments/'+n+'.lua') for n in names})
    paths.update({n+'.lua':ROOT/('Scripts/'+n+'.lua') for n in ['palapi','log','trace','perf','frame_trace','workdefs']})
    if args.route=='direct':paths.update({n+'.lua':ROOT/('Scripts/'+n+'.lua') for n in ['store','datafile','settings_gate']})
    data={n:p.read_bytes() for n,p in paths.items()}
    sys.path.insert(0,str(ROOT/'.test-deps'))
    from lupa.lua54 import LuaRuntime
    lua=LuaRuntime(unpack_returned_tuples=True)
    compile_chunk=lua.eval('function(s,n)local f,e=load(s,n,"t",{});return f~=nil,e end')
    for n,raw in data.items():
        ok,why=compile_chunk(raw.decode('utf-8'),'@'+n);assert ok,why
    lua.globals().ROOT=ROOT.as_posix()
    lua.globals().files=lua.table_from(Backup.frozen(manifest['capture']))
    keys=lua.execute('''
        package.path=ROOT..'/Scripts/?.lua;'..package.path
        package.loaded.log={warn=function()end,error=function()end}
        local D,S=require('datafile'),require('store')
        D.fs={open=function(n)local raw=files[n];if raw==nil then return nil,'missing',2 end
            return {read=function()return raw end,close=function()return true end}end}
        local p=assert(D.read('priorities.txt',S.decode_snapshot));local keys={}
        for key in pairs(p.data)do keys[#keys+1]=key end;table.sort(keys);return keys
    ''')
    selected=[keys[i] for i in range(1,len(keys)+1)]
    assert selected and all(k.isalnum() or all(c.isalnum() or c=='-' for c in k) for k in selected)
    target="return {storage='31141b9948fe8b9a8b4cc399974dddf1',guild='d2c75eae4e5c0c4c4d24b89b2010b5eb',alias='-758686034-1314655308-1294252187-537966059',keys={"+','.join("'"+k+"'" for k in selected)+"}}\n"
    target=target.replace('return {',"return {route='"+args.route+"',",1)
    data['target.lua']=target.encode('ascii')
    tests=['tests/test_priority_roster.lua','tests/test_priority_roster_live.lua',
           'tests/test_save_local_authority.lua','tests/test_save_context_pair_probe.lua']
    if args.route!='camp':tests.append('tests/test_priority_guild_roster.lua')
    if args.route in ('parameter','world','direct'):tests.append('tests/test_priority_parameter_roster.lua')
    if args.route in ('world','direct'):tests.append('tests/test_priority_world_lookup.lua')
    if args.route=='direct':tests.extend(['tests/test_priority_live_reader.lua','tests/test_priority_direct_reader.lua','tests/test_priority_membership.lua'])
    checked=subprocess.run([sys.executable,'tools/test_lua.py',*tests],
        cwd=ROOT,capture_output=True,timeout=90)
    assert checked.returncode==0,(checked.stdout+checked.stderr).decode(errors='replace')
    assert all(p.read_bytes()==data[n] for n,p in paths.items()),'source changed'
    assert Backup.game_closed() and production()==before,'process/production changed'
    assert Backup.stable_equal(manifest['capture'],Backup.capture(manifest['capture']['source']))
    if not args.install:
        print(json.dumps({'checked':True,'installed':False,'saved_keys':len(selected)}));return
    nonce=({'camp':'roster-','guild':'guild-','parameter':'parameter-','world':'world-','direct':'direct-' }[args.route])+uuid.uuid4().hex
    evidence=ROOT/'test-results'/nonce;evidence.mkdir()
    (evidence/'checks.log').write_bytes(checked.stdout+checked.stderr)
    for n,raw in data.items():
        p=probe/'Scripts'/n;p.parent.mkdir(parents=True,exist_ok=True)
        with p.open('xb') as f:f.write(raw)
        assert p.read_bytes()==raw
    assert Backup.game_closed() and production()==before,'process/production changed; leave probe disarmed'
    assert Backup.stable_equal(manifest['capture'],Backup.capture(manifest['capture']['source']))
    record={'nonce':nonce,'production_before':before,'sources':{n:hashlib.sha256(raw).hexdigest() for n,raw in data.items()},
            'saved_keys':selected,'route':args.route,'read_only':True,'activation_allowed':False,'probe':str(probe)}
    (evidence/'install.json').write_text(json.dumps(record,indent=2)+'\n')
    (probe/'Scripts/run.txt').write_text('PWP_PRIORITY_ROSTER '+nonce+'\n')
    (probe/'enabled.txt').write_text('')
    print(json.dumps({'installed':True,'evidence':str(evidence),'nonce':nonce}))
if __name__=='__main__':main()
